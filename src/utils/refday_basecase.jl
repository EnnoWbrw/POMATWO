# ============================================================================
# D2CF-style reference-day shift and FBMC basecase construction
# ----------------------------------------------------------------------------
# Stage 2 of the reference-day basecase methodology: given a matched reference
# day and a target day (both timesteps in one results set — the "forecast"
# run), build a NODAL net-injection basecase for the target day that keeps the
# reference day's nodal texture but aligns renewable infeed and the zonal net
# position with the target forecast, mimicking the CWE D2CF process.
#
# Method: the per-zone net-position gap D(z) = NP_target(z) - NP_current(z) is
# apportioned among the PHYSICAL components {RES, conv, load, storage} by user
# shares β; each component's zonal amount is spread to nodes by a redistribution
# key, clipped to physical headroom. There is no phantom exchange slack: a gap
# no physical lever can absorb is left relaxed toward the reference (recorded as
# `np_relax`). A final pass then forces the whole basecase to be globally
# BALANCED (Σ_n injection = 0, production = consumption) by adjusting conventional
# generation (load as a last resort), so the net-injection basecase is physically
# consistent for the PTDF/FBMC flow computation.
#
# SIGN CONVENTION: the whole shift pipeline (baseline P, shares, bounds,
# REFDAY_SHIFT trace deltas) works EXPORT-positive (feed-in: positive =
# gen − load − charge). The persisted NETINPUT/ACINJECTION tables are
# IMPORT-positive (model convention, = load + charge − gen), so the baseline
# is negated on entry (`_ac_injection_baseline`) and the assembled basecase is
# negated back on exit (`build_refday_basecase`) before `calc_ram` /
# `build_gsk_timeseries` consume it.
#
# The nodal injection baseline is the (negated) AC-only ACINJECTION column of
# the NETINPUT result table (DC contributions excluded); legacy result sets
# reconstruct it from the LINEFLOW table.
# ============================================================================

# ---------------------------------------------------------------------------
# Shift method + redistribution keys
# ---------------------------------------------------------------------------

"""
    ShiftMethod

Abstract supertype for strategies that shift a reference day's nodal injection
toward a target day. Concrete: [`ShareShift`](@ref).
"""
abstract type ShiftMethod end

"""
    RedistKey

Abstract supertype for the key that spreads a zonal correction across the
zone's nodes. Concrete: [`GSKRedist`](@ref), [`RefPropRedist`](@ref),
[`LoadPropRedist`](@ref).
"""
abstract type RedistKey end

"Spread a zonal correction to nodes using an existing [`GSKStrategy`](@ref)."
struct GSKRedist <: RedistKey
    strategy::GSKStrategy
end
GSKRedist() = GSKRedist(FlatGSK())

"Spread proportional to each node's net-injection magnitude (preserves the spatial pattern)."
struct RefPropRedist <: RedistKey end

"Spread proportional to nodal load share."
struct LoadPropRedist <: RedistKey end

"""
Spread by random positive weights, reproducible for a fixed `seed`.

Weights are drawn per (zone, time) from an RNG seeded by `seed` combined with
the zone's nodes and the timestep, so a run is deterministic and independent of
node iteration order.
"""
struct RandomRedist <: RedistKey
    seed::UInt64
end
RandomRedist(seed::Integer = 0) = RandomRedist(UInt64(seed))

"""
    ShareShift <: ShiftMethod

Apportion the net-position gap among components by user shares.

# Fields
- `β_RES, β_conv, β_load`: apportionment shares of the gap (should sum to ≤ 1).
  There is no phantom net-position slack: the gap is closed only by the *physical*
  levers RES/conv/load/storage. The leftover fraction `1 - β_RES - β_conv - β_load`
  (plus any saturation remainder) is deliberately left relaxed toward the reference
  day (recorded as `"np_relax"`), not an exchange slack that manufactures injection.
- `resolution`: `:zonal` (gap per zone, spread by `redist`) or `:nodal` (gap per
  node; the output nodal net injection then equals the target's nodal injection
  where physically reachable).
- `res_prestep`: if `true`, hard-set RES to the target first (nodal direct, or
  zonal-scaled preserving reference intra-zone shares), then apportion the rest.
- `redist`: nodal redistribution key for zonal corrections.
- `fallback_order`: cascade order for remainders when a component saturates
  (physical levers only). A zone's gap that no physical lever can absorb is left
  relaxed toward reference and recorded as `"np_relax"`.
- `enforce_balance`: if `true` (default), a final pass forces the whole basecase to
  be globally balanced (`Σ_n injection = 0`, i.e. production = consumption) by
  adjusting conventional generation (load as a last resort). See
  [`_enforce_global_balance!`](@ref).
"""
Base.@kwdef struct ShareShift <: ShiftMethod
    β_RES::Float64  = 0.0
    β_conv::Float64 = 0.5
    β_load::Float64 = 0.5
    resolution::Symbol = :zonal
    res_prestep::Bool  = false
    redist::RedistKey  = GSKRedist()
    fallback_order::Vector{Symbol} = [:conv, :sto, :load]
    enforce_balance::Bool = true
end

"Error on invalid share sum or resolution; warn on double-moved RES."
function validate_shares(m::ShareShift)
    s = m.β_RES + m.β_conv + m.β_load
    s <= 1.0 + 1e-6 || error("Shift shares sum to $s, must be ≤ 1.0 (leftover fraction is np_relax)")
    (m.res_prestep && m.β_RES > 0) && @warn "res_prestep=true with β_RES>0: RES moved twice (hard-set, then balancer)"
    m.resolution in (:zonal, :nodal) || error("resolution must be :zonal or :nodal, got :$(m.resolution)")
    return nothing
end

# ---------------------------------------------------------------------------
# Configuration structs (complete the BasecaseMethod family from
# market_definitions.jl — defined here because they need MatchScope,
# ShiftMethod and DataFiles)
# ---------------------------------------------------------------------------

"""
    MatchingConfig(; kwargs...)

Options for the reference-day matching stage of [`ReferenceDayBasecase`](@ref).

# Keyword fields
- `cluster_size::Int = 24`: timesteps per cluster (a "day").
- `start_date::Date = Date(2013,1,1)`: calendar anchor of `Time = 1` (weekday/weekend classification).
- `lookback::Int = 14`: candidate window (clusters before the target, cyclic).
- `exact_weekend::Bool = true`: match weekend↔weekend / workday↔workday, with
  automatic relaxation when no same-type candidate exists (never drops timesteps).
- `keycols::Vector{Symbol} = [:plant_type, :node]`: profile grouping keys.
- `value_methods::Vector{Function} = [median, maximum]`: per-cluster statistics.
- `weights::Dict = Dict{Tuple{Symbol,String},Float64}()`: distance weights
  (per value/statistic column, optionally refined per plant type).
- `res_tags::Vector{String} = ["solar", "wind"]`: plant-type substrings that
  define the renewable set (matching signal and RES shift lever).
- `scope::MatchScope = GlobalMatchScope()`: per-TSO matching scope
  ([`GlobalMatchScope`](@ref) / [`ZonalMatchScope`](@ref) / [`AreaMatchScope`](@ref)).
"""
Base.@kwdef struct MatchingConfig
    cluster_size::Int = 24
    start_date::Date = Date(2013, 1, 1)
    lookback::Int = 14
    exact_weekend::Bool = true
    keycols::Vector{Symbol} = [:plant_type, :node]
    value_methods::Vector{Function} = [median, maximum]
    weights::Dict = Dict{Tuple{Symbol,String},Float64}()
    res_tags::Vector{String} = ["solar", "wind"]
    scope::MatchScope = GlobalMatchScope()
end

"""
    ReferenceDayBasecase(; source, source_type = "", matching = MatchingConfig(), shift = ShareShift())

Reference-day (D2CF-style) basecase methodology for flow-based market runs:
instead of solving the `TwoDayAhead` optimization, the FBMC basecase is built
by matching every target day to a similar reference day of a previous
("forecast") model run and shifting its nodal injection pattern to the target
day's renewable infeed and zonal net positions.

# Keyword fields
- `source::Union{String,DataFiles}`: results directory of the forecast run, or
  a preloaded [`DataFiles`](@ref).
- `source_type::String = ""`: which MarketState of the source run provides
  BOTH the matching data and the injection baseline (never mixed):
  `""`/`"DA"` = day-ahead results (for zonal DA markets the nodal injections
  are computed from plant-level `GEN`/`CHARGE` and `nodal_load`, since zonal
  stages persist no nodal tables); `"2DA"` = TwoDayAhead basecase tables;
  `"REDISP"` = redispatch results. See `_source_state`.
- `matching::MatchingConfig`: reference-day matching options.
- `shift::ShiftMethod`: how the reference day is shifted toward the target day.

# Example
```julia
setup = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 168, split = 8760),
    MarketType = ZonalMarket(FlowBased(
        GSKStrategy = DispOnlyGSK(),
        basecase = ReferenceDayBasecase(
            source = "results/forecast_run",
            matching = MatchingConfig(lookback = 4, scope = ZonalMatchScope()),
            shift = ShareShift(β_conv = 0.5, β_load = 0.5, res_prestep = true),
        ),
    )),
)
```
"""
Base.@kwdef struct ReferenceDayBasecase <: BasecaseMethod
    source::Union{String,DataFiles}
    source_type::String = ""
    matching::MatchingConfig = MatchingConfig()
    shift::ShiftMethod = ShareShift()
end

# ---------------------------------------------------------------------------
# Nodal data extraction
# ---------------------------------------------------------------------------

"Nodal load at (n, t); 0.0 for nodes without a load series or `missing` values."
function _nodal_load_at(params::Parameters, n, t)
    haskey(params.nodal_load, n) || return 0.0
    v = params.nodal_load[n][t]
    return ismissing(v) ? 0.0 : Float64(v)
end

function _classify_plant(p, params::Parameters, res_tags)
    p in params.sets.S && return :sto
    pt = get(params.plant_type, p, "")
    any(tag -> occursin(tag, pt), res_tags) && return :res
    return :conv
end

# ---------------------------------------------------------------------------
# Source MarketState selection
#
# `ReferenceDayBasecase.source_type` picks WHICH MarketState of the source run
# provides BOTH the matching data (generation) and the injection baseline —
# they must never come from different states. The string maps to a dispatch
# type so future states (e.g. an intraday stage) only need a new subtype plus
# `_source_gen` / `_source_charge` / `_ac_injection_baseline` methods.
# ---------------------------------------------------------------------------

"Source MarketState of a [`ReferenceDayBasecase`](@ref); see `_source_state`."
abstract type RefdaySourceState end
struct TwoDayAheadSource <: RefdaySourceState end
struct DayAheadSource    <: RefdaySourceState end
struct RedispatchSource  <: RefdaySourceState end

"""
    _source_state(source_type::AbstractString) -> RefdaySourceState

Map the `source_type` config string to its dispatch type:
`"2DA"` → `TwoDayAheadSource` (2DA-prefixed result tables),
`""`/`"DA"` → `DayAheadSource` (plain day-ahead tables; nodal
injections are computed from plant-level results when the DA market was
zonal), `"REDISP"` → `RedispatchSource` (redispatch results).
"""
_source_state(source_type::AbstractString) =
    source_type == "2DA"           ? TwoDayAheadSource() :
    source_type in ("", "DA")      ? DayAheadSource() :
    source_type == "REDISP"        ? RedispatchSource() :
    error("ReferenceDayBasecase: unknown source_type = \"$source_type\". " *
          "Supported: \"\"/\"DA\" (day-ahead), \"2DA\" (TwoDayAhead), \"REDISP\" (redispatch).")

"Table prefix `DataFiles` needs for this source state."
_datafiles_type(::RefdaySourceState)  = ""
_datafiles_type(::TwoDayAheadSource)  = "2DA"

"Generation table (columns `index`, `Time`, `GEN`) of the source state."
_source_gen(::RefdaySourceState, ref::DataFiles) = ref.GEN
function _source_gen(::RedispatchSource, ref::DataFiles)
    isempty(ref.REDISP) && error(
        "ReferenceDayBasecase: source_type = \"REDISP\" but the source run has no " *
        "redispatch results (empty REDISP table).")
    df = select(ref.REDISP, :index, :Time, :GEN_REDISP => :GEN)
    df.GEN = Float64.(coalesce.(df.GEN, 0.0))
    return df
end

"Storage-charging table (columns `index`, `Time`, `CHARGE`) of the source state."
_source_charge(::RefdaySourceState, ref::DataFiles) = ref.CHARGE
function _source_charge(::RedispatchSource, ref::DataFiles)
    isempty(ref.REDISP) && return DataFrame(index = String[], Time = Int[], CHARGE = Float64[])
    df = select(ref.REDISP, :index, :Time, :CHARGE_REDISP => :CHARGE)
    df.CHARGE = Float64.(coalesce.(df.CHARGE, 0.0))
    return df
end

"""
    _ac_injection_baseline(state::RefdaySourceState, ref::DataFiles)
        -> Dict{(node,Time) => Float64}

AC-only nodal net injection per (node, time), **export-positive** (feed-in
convention: positive = the node injects into the AC grid, `gen − load − charge`).

- `TwoDayAheadSource` / `RedispatchSource` (nodal DCLF stages): read from the
  persisted `NETINPUT` table. Its `ACINJECTION` column follows the model's
  *import-positive* convention (`= load + charge − gen`, see the nodal balance
  in energy_balances.jl and the NP negation in `calc_ram`), so it is negated
  here. Legacy result sets reconstruct it from `LINEFLOW` via the incidence
  convention (line_start = +1, line_end = -1); errors when neither an
  `ACINJECTION` column nor `LINEFLOW` data is available.
- `DayAheadSource`: a *zonal* day-ahead stage persists no nodal tables, so the
  injection is computed from plant-level results — every plant has a node:
  `P[n,t] = Σ GEN(plants at n) − nodal_load[n][t] − Σ CHARGE(storages at n)`.
  DC-line flows, prosumer net input, and the `CU`/`LL` infeasibility slacks of
  the DA balance are not nodally attributable and are omitted (approximation;
  exact for AC-only networks whose DA stage used no slack).

The shift pipeline works entirely in this export-positive space;
[`build_refday_basecase`](@ref) negates back to the model's import-positive
convention when assembling `:netinput_ac`.
"""
function _ac_injection_baseline(::Union{TwoDayAheadSource,RedispatchSource}, ref::DataFiles)
    ni = ref.NETINPUT
    if "ACINJECTION" in names(ni)
        return Dict{Tuple{String,Int},Float64}(
            (String(r.index), Int(r.Time)) => -Float64(r.ACINJECTION) for r in eachrow(ni))
    end
    isempty(ref.LINEFLOW) && error(
        "ReferenceDayBasecase: NETINPUT of the source results has no ACINJECTION column " *
        "(legacy result set) and LINEFLOW is empty — the AC injection baseline cannot be " *
        "reconstructed. Re-run the forecast scenario with the current package.")
    params = ref.params
    P = Dict{Tuple{String,Int},Float64}()
    for r in eachrow(ref.LINEFLOW)
        f = Float64(r.LINEFLOW)
        t = Int(r.Time)
        ns = params.line_start[r.index]; ne = params.line_end[r.index]
        P[(ns, t)] = get(P, (ns, t), 0.0) + f
        P[(ne, t)] = get(P, (ne, t), 0.0) - f
    end
    return P
end

function _ac_injection_baseline(state::DayAheadSource, ref::DataFiles)
    params = ref.params
    gen    = _source_gen(state, ref)
    charge = _source_charge(state, ref)
    times  = sort(unique(Int.(gen.Time)))

    P = Dict{Tuple{String,Int},Float64}()
    for n in params.sets.N, t in times
        P[(n, t)] = -_nodal_load_at(params, n, t)
    end
    for r in eachrow(gen)
        n = get(params.plant2node, r.index, "")
        n == "" && continue
        key = (n, Int(r.Time))
        P[key] = get(P, key, 0.0) + Float64(coalesce(r.GEN, 0.0))
    end
    for r in eachrow(charge)
        n = get(params.plant2node, r.index, "")
        n == "" && continue
        key = (n, Int(r.Time))
        P[key] = get(P, key, 0.0) - Float64(coalesce(r.CHARGE, 0.0))
    end
    return P
end

"""
    precompute_nodal(results::DataFiles, state::RefdaySourceState = TwoDayAheadSource();
                     res_tags) -> NamedTuple

Precompute the per-(node, time) lookups used by the shift: RES and conventional
generation, nodal load, AC net-injection baseline (`P`, **export-positive** —
see `_ac_injection_baseline`), per-(node, time) availability-weighted conv/RES
generation caps (`gmax_conv`/`gmax_res`, via `calc_gmax`), per-node storage
discharge/charge power caps (`gmax_sto_dis`/`gmax_sto_chg`), and zone maps. All
state-dependent data (generation and injection baseline) come from the SAME
source MarketState selected by `state`. Storage dispatch is also folded into the
net-injection baseline; the storage power caps additionally make storage a
bidirectional shift lever (installed power assumed available every timestep — a
rough approximation ignoring state-of-charge).
"""
function precompute_nodal(results::DataFiles, state::RefdaySourceState = TwoDayAheadSource();
                          res_tags = ["solar", "wind"])
    params = results.params
    nodes  = sort(collect(params.sets.N))

    gen = copy(_source_gen(state, results))
    times = sort(unique(Int.(gen.Time)))
    transform!(gen, :index => ByRow(x -> get(params.plant2node, x, "")) => :node)
    transform!(gen, :index => ByRow(x -> _classify_plant(x, params, res_tags)) => :cls)
    filter!(:node => !=(""), gen)

    RES  = Dict{Tuple{String,Int},Float64}()
    CONV = Dict{Tuple{String,Int},Float64}()
    for row in eachrow(gen)
        key = (row.node, row.Time)
        if row.cls == :res
            RES[key]  = get(RES,  key, 0.0) + Float64(row.GEN)
        elseif row.cls == :conv
            CONV[key] = get(CONV, key, 0.0) + Float64(row.GEN)
        end
    end

    # Per-(node, time) generation caps, availability-weighted (calc_gmax =
    # avail[p][t] * gmax[p]) so a node's conv/RES shifting headroom reflects the
    # target hour's derating/outages, not just nameplate. Storage caps are
    # per-node installed power assumed available at every timestep (a rough
    # approximation: state-of-charge / energy limits are ignored), split by
    # direction — discharge (gmax) up, charge (gmax_storage) down.
    gmax_conv = Dict{Tuple{String,Int},Float64}((n, t) => 0.0 for n in nodes, t in times)
    gmax_res  = Dict{Tuple{String,Int},Float64}((n, t) => 0.0 for n in nodes, t in times)
    gmax_sto_dis = Dict(n => 0.0 for n in nodes)
    gmax_sto_chg = Dict(n => 0.0 for n in nodes)
    for (p, n) in params.plant2node
        haskey(gmax_sto_dis, n) || continue
        cls = _classify_plant(p, params, res_tags)
        if cls == :conv
            for t in times; gmax_conv[(n, t)] += calc_gmax(params, p, t); end
        elseif cls == :res
            for t in times; gmax_res[(n, t)]  += calc_gmax(params, p, t); end
        elseif cls == :sto
            gmax_sto_dis[n] += Float64(get(params.gmax,         p, 0.0))
            gmax_sto_chg[n] += Float64(get(params.gmax_storage, p, 0.0))
        end
    end

    # AC-only nodal injection baseline (DC excluded), export-positive —
    # the negation of calc_ram's import-positive :netinput_ac convention
    P = _ac_injection_baseline(state, results)

    LOAD = Dict{Tuple{String,Int},Float64}()
    for n in nodes, t in times
        LOAD[(n, t)] = _nodal_load_at(params, n, t)
    end

    nodes_in_zone = Dict(z => sort(collect(v)) for (z, v) in params.nodes_in_zone)

    return (; nodes, times, RES, CONV, gmax_conv, gmax_res, gmax_sto_dis, gmax_sto_chg, P, LOAD, nodes_in_zone)
end

# ---------------------------------------------------------------------------
# Redistribution, bounded waterfilling, component bounds
# ---------------------------------------------------------------------------

# Per-key nodal weight rule (dispatched on RedistKey). Add a new key by
# defining another `_key_weights` method — no edit to `_redist_weights` needed.
_key_weights(::LoadPropRedist, nd, params, znodes, t; gsk = nothing) =
    Dict(n => get(nd.LOAD, (n, t), 0.0) for n in znodes)

_key_weights(::RefPropRedist, nd, params, znodes, t; gsk = nothing) =
    Dict(n => abs(get(nd.P, (n, t), 0.0)) for n in znodes)

function _key_weights(key::GSKRedist, nd, params, znodes, t; gsk = nothing)
    if is_time_dependent(key.strategy)
        # Time-dependent strategies (e.g. GenLoadGSK): build the GLSK weight
        # |gen| + |load| at t from the forecast run's nodal data. nd.P is the
        # EXPORT-positive net-injection baseline (see _ac_injection_baseline),
        # so gen = P + load (storage charge absorbed into gen, harmless under
        # abs) — the same weight as build_gsk_timeseries, which recovers
        # gen = load − netinput_ac from the import-positive persisted table.
        return Dict(n => begin
            load = get(nd.LOAD, (n, t), 0.0)
            gen = get(nd.P, (n, t), 0.0) + load
            abs(gen) + abs(load)
        end for n in znodes)
    end
    G = gsk === nothing ? build_gsk(params, key.strategy; normalize_empty = :flat) : gsk
    z = params.node2zone[first(znodes)]
    return Dict(n => G[n, z] for n in znodes)
end

function _key_weights(key::RandomRedist, nd, params, znodes, t; gsk = nothing)
    # per-(zone, time) seed so weights are reproducible and order-independent
    rng = Random.Xoshiro(hash((key.seed, sort(znodes), t)))
    return Dict(n => rand(rng) for n in sort(znodes))
end

"Nodal redistribution weights within a zone for the chosen key (flat fallback)."
function _redist_weights(key::RedistKey, nd, params, znodes, t; gsk = nothing)
    w = _key_weights(key, nd, params, znodes, t; gsk = gsk)
    sum(values(w)) <= 0 && (w = Dict(n => 1.0 for n in znodes))
    return w
end

"""
    _waterfill(A, znodes, w, lo, hi) -> (applied::Dict, remainder)

Distribute amount `A` over `znodes` proportional to weights `w`, clipped to
per-node bounds `[lo, hi]` (bounds may be ±Inf). Redistributes the clipped
remainder among nodes that still have room. Returns the applied per-node deltas
and any unabsorbable remainder.
"""
function _waterfill(A, znodes, w, lo, hi; iters = 50)
    applied = Dict(n => 0.0 for n in znodes)
    remaining = A
    for _ in 1:iters
        abs(remaining) < 1e-9 && break
        act = [n for n in znodes if (remaining > 0 ? hi[n] - applied[n] > 1e-12
                                                   : applied[n] - lo[n] > 1e-12)]
        isempty(act) && break
        wsum = sum(w[n] for n in act)
        wsum <= 0 && break
        moved = 0.0
        for n in act
            want = remaining * w[n] / wsum
            if remaining > 0
                δ = min(want, hi[n] - applied[n])
            else
                δ = max(want, lo[n] - applied[n])
            end
            applied[n] += δ
            moved += δ
        end
        remaining -= moved
    end
    return applied, remaining
end

"Per-node signed bounds (Δ injection) available from `comp` at node `n`, time `t`."
function _comp_bounds(comp, n, t, nd, res_w, conv_w, load_w)
    if comp == :conv
        return (-conv_w[n], get(nd.gmax_conv, (n, t), 0.0) - conv_w[n])
    elseif comp == :load          # cut load → raise injection (≤ current load); add load unbounded
        return (-Inf, load_w[n])
    elseif comp == :RES
        return (-res_w[n], get(nd.gmax_res, (n, t), 0.0) - res_w[n])
    elseif comp == :sto           # storage: discharge up, charge down; installed power, every t
        return (-nd.gmax_sto_chg[n], nd.gmax_sto_dis[n])
    else
        error("_comp_bounds: unknown shift component :$comp (physical levers only: :RES, :conv, :load, :sto)")
    end
end

"Below this the basecase is treated as globally balanced (production ≈ consumption)."
const BALANCE_TOL = 1e-6

"""
    _enforce_global_balance!(p_new, nd, t, conv_w, load_w, trace)

Force the basecase to represent a globally **balanced** system: drive the total
net injection `R = Σ_n p_new` (export-positive) to zero so that
`Σ gen = Σ load + Σ charge` (production = consumption). The correction `-R` is
applied as physical **conventional generation** adjustments, bounded per node by
the availability-weighted headroom `[-conv_w[n], gmax_conv[(n,t)] - conv_w[n]]`
and spread by remaining room. If conventional generation saturates, **load**
absorbs the residual (add load to shed a surplus, cut load to cover a deficit) —
which guarantees balance — with a warning. All applied deltas are traced as
`"balance"`. Because only physical quantities move, every `p_new[n]` remains
`gen − load − charge`, so each zone's net position stays physically backed.
"""
function _enforce_global_balance!(p_new, nd, t, conv_w, load_w, trace)
    nodes = nd.nodes
    R = sum(values(p_new))              # export-positive global net injection; want 0
    abs(R) <= BALANCE_TOL && return p_new
    A = -R                              # injection change to apply so Σ becomes 0

    # --- primary lever: conventional generation ---
    lo = Dict(n => -conv_w[n] for n in nodes)
    hi = Dict(n => get(nd.gmax_conv, (n, t), 0.0) - conv_w[n] for n in nodes)
    w  = A > 0 ? Dict(n => max(hi[n], 0.0) for n in nodes) :
                 Dict(n => max(-lo[n], 0.0) for n in nodes)
    applied, rem = _waterfill(A, nodes, w, lo, hi)
    for n in nodes
        _record!(trace, t, n, "balance", applied[n])
        p_new[n]  += applied[n]
        conv_w[n] += applied[n]
    end

    # --- last resort: load (guarantees balance when conv headroom is exhausted) ---
    if abs(rem) > BALANCE_TOL
        @warn "refday balance at t=$t: conventional headroom insufficient (residual $(round(rem; digits=3)) MW); adjusting load."
        loL = Dict(n => -Inf for n in nodes)        # add load ⇒ injection down (unbounded)
        hiL = Dict(n => load_w[n] for n in nodes)   # cut load ⇒ injection up (≤ current load)
        wL  = rem > 0 ? Dict(n => max(hiL[n], 0.0) for n in nodes) :
                        Dict(n => 1.0 for n in nodes)
        appliedL, rem2 = _waterfill(rem, nodes, wL, loL, hiL)
        for n in nodes
            _record!(trace, t, n, "balance", appliedL[n])
            p_new[n]  += appliedL[n]
            load_w[n] -= appliedL[n]                # +injection ⇒ load down
        end
        abs(rem2) > BALANCE_TOL &&
            @warn "refday balance at t=$t: could not fully balance (residual $(round(rem2; digits=3)) MW remains)."
    end
    return p_new
end

# ---------------------------------------------------------------------------
# Shift trace
# ---------------------------------------------------------------------------

"Deltas below this are numerical noise (matches `_waterfill`'s outer tolerance) and are not traced."
const SHIFT_TRACE_TOL = 1e-9

"""
    ShiftTraceCollector()

Collects the per-node injection deltas applied by `shift_single` as
four parallel vectors (`Time`, `node`, `component`, `delta`); convert with
`shift_trace_df`. `delta` is the change in nodal net injection in the
**export-positive** (feed-in) convention — positive = more generation / less
load; note the persisted NETINPUT/ACINJECTION result tables use the opposite
(import-positive) convention. For the `"load"` component the actual load
change is `-delta`.

Components: `"RES_prestep"`, `"RES"`, `"conv"`, `"load"`, `"sto"` (physical
per-node levers), `"balance"` (per-node conventional-gen/load deltas from the
global balance pass, [`_enforce_global_balance!`](@ref)), and `"np_relax"` — a
per-zone row (zone label in the `node` column) recording how far the zone's net
position was left relaxed toward the reference (target NP minus reachable NP).
`"np_relax"` is an annotation, not a nodal injection delta, so it is excluded
from the `netinput_ac = ACINJECTION_src − Σ deltas` reconstruction.
"""
struct ShiftTraceCollector
    Time::Vector{Int}
    node::Vector{String}
    component::Vector{String}
    delta::Vector{Float64}
end
ShiftTraceCollector() = ShiftTraceCollector(Int[], String[], String[], Float64[])

@inline _record!(::Nothing, t, n, comp, d) = nothing
@inline function _record!(tr::ShiftTraceCollector, t, n, comp, d)
    abs(d) > SHIFT_TRACE_TOL || return nothing
    push!(tr.Time, t); push!(tr.node, n); push!(tr.component, comp); push!(tr.delta, d)
    return nothing
end

"Collector contents as a `DataFrame` (`Time, node, component, delta`)."
shift_trace_df(tr::ShiftTraceCollector) =
    DataFrame(Time = tr.Time, node = tr.node, component = tr.component, delta = tr.delta)

# ---------------------------------------------------------------------------
# The shift
# ---------------------------------------------------------------------------

"""
    shift_single(nd, params, t_tgt, t_ref, method; trace = nothing) -> Dict(node => net_injection)

Build the target-day nodal net injection from reference day `t_ref` and target
day `t_tgt` under `method`. `t_ref` is either a single time step (global
reference day) or a per-node map `node => reference_time` (scoped / per-TSO
matching, where each group borrows its own reference day).

The gap is closed by physical levers only (RES/conv/load/storage); a zone's
unreachable remainder is left relaxed toward reference (traced `"np_relax"`).
When `method.enforce_balance` (default), a final pass forces the whole result to
be globally balanced (`Σ_n net_injection = 0`) via conventional generation
(traced `"balance"`); see [`_enforce_global_balance!`](@ref).

Pass a `ShiftTraceCollector` as `trace` to record every applied per-node
injection delta (components `"RES_prestep"`, `"RES"`, `"conv"`, `"load"`,
`"sto"`, `"balance"`, plus the per-zone `"np_relax"`).
"""
shift_single(nd, params, t_tgt, t_ref::Integer, method::ShareShift; gsk = nothing, trace = nothing) =
    shift_single(nd, params, t_tgt, Dict(n => Int(t_ref) for n in nd.nodes), method; gsk = gsk, trace = trace)

function shift_single(nd, params, t_tgt, ref_of_node::AbstractDict, method::ShareShift;
                      gsk = nothing, trace = nothing)
    nodes  = nd.nodes
    p_new  = Dict(n => get(nd.P,    (n, ref_of_node[n]), 0.0) for n in nodes)
    res_w  = Dict(n => get(nd.RES,  (n, ref_of_node[n]), 0.0) for n in nodes)
    conv_w = Dict(n => get(nd.CONV, (n, ref_of_node[n]), 0.0) for n in nodes)
    load_w = Dict(n => get(nd.LOAD, (n, ref_of_node[n]), 0.0) for n in nodes)

    # ---- optional hard RES pre-step: align RES to target ----
    if method.res_prestep
        if method.resolution == :nodal
            for n in nodes
                tgt = get(nd.RES, (n, t_tgt), 0.0)
                _record!(trace, t_tgt, n, "RES_prestep", tgt - res_w[n])
                p_new[n] += tgt - res_w[n]
                res_w[n]  = tgt
            end
        else
            for (z, znodes) in nd.nodes_in_zone
                ref_sum = sum(res_w[n] for n in znodes)
                tgt_sum = sum(get(nd.RES, (n, t_tgt), 0.0) for n in znodes)
                Δ = tgt_sum - ref_sum
                # keep reference intra-zone RES shares; fall back to redist key if zone had no RES
                w = ref_sum > 0 ? Dict(n => res_w[n] for n in znodes) :
                    _redist_weights(method.redist, nd, params, znodes, t_tgt; gsk = gsk)
                ws = sum(values(w)); ws <= 0 && (ws = length(znodes); w = Dict(n => 1.0 for n in znodes))
                for n in znodes
                    d = Δ * w[n] / ws
                    _record!(trace, t_tgt, n, "RES_prestep", d)
                    p_new[n] += d
                    res_w[n] += d
                end
            end
        end
    end

    # ---- net-position gap apportionment ----
    zones = method.resolution == :nodal ? [(n, [n]) for n in nodes] :
                                          collect(nd.nodes_in_zone)
    order = unique([:RES, method.fallback_order...])   # physical levers only (no phantom :NP)
    share = Dict(:RES => method.β_RES, :conv => method.β_conv,
                 :load => method.β_load)

    for (z, znodes) in zones
        NP_tgt = sum(get(nd.P, (n, t_tgt), 0.0) for n in znodes)
        NP_cur = sum(p_new[n] for n in znodes)
        D = NP_tgt - NP_cur

        carried = 0.0
        for comp in order
            amount = get(share, comp, 0.0) * D + carried
            if abs(amount) < 1e-12
                carried = 0.0
                continue
            end
            w  = _redist_weights(method.redist, nd, params, znodes, t_tgt; gsk = gsk)
            lo = Dict{String,Float64}(); hi = Dict{String,Float64}()
            for n in znodes
                lo[n], hi[n] = _comp_bounds(comp, n, t_tgt, nd, res_w, conv_w, load_w)
            end
            applied, rem = _waterfill(amount, znodes, w, lo, hi)
            for n in znodes
                _record!(trace, t_tgt, n, string(comp), applied[n])
                p_new[n] += applied[n]
                comp == :conv && (conv_w[n] += applied[n])
                comp == :RES  && (res_w[n]  += applied[n])
                comp == :load && (load_w[n] -= applied[n])   # +injection ⇒ load down
            end
            carried = rem
        end
        # gap the physical levers left open = this zone's NP relaxed toward reference
        # (the deliberately unshifted 1-β_RES-β_conv-β_load fraction plus any saturation remainder)
        _record!(trace, t_tgt, string(z), "np_relax", NP_tgt - sum(p_new[n] for n in znodes))
    end

    # global balance: force Σ_n p_new = 0 (production = consumption) via conventional gen
    method.enforce_balance &&
        _enforce_global_balance!(p_new, nd, t_tgt, conv_w, load_w, trace)
    return p_new
end

# ---------------------------------------------------------------------------
# Basecase assembly
# ---------------------------------------------------------------------------

"""
    _refday_match_trace(groupmap, matches, fallback_matches) -> DataFrame

Attach the cluster metadata (`target_cluster`, `matched_cluster`,
`cluster_distance`) of the match tables to a group-level resolution from
`resolve_group_times`. Fallback rows join against `fallback_matches`;
metadata columns may be `missing` where a join finds no counterpart.
"""
function _refday_match_trace(groupmap::DataFrame, matches, fallback_matches)
    metacols = [:target_cluster, :matched_cluster, :cluster_distance]
    m = copy(matches)
    ("group" in names(m)) || (m[!, :group] .= "ALL")
    own = leftjoin(groupmap[.!groupmap.fallback, :],
                   unique(m[:, [:group, :target_time, metacols...]]);
                   on = [:group, :target_time])
    fbrows = groupmap[groupmap.fallback, :]
    if fallback_matches !== nothing && !isempty(fbrows)
        fbrows = leftjoin(fbrows, unique(fallback_matches[:, [:target_time, metacols...]]);
                          on = :target_time)
    end
    out = vcat(own, fbrows; cols = :union)
    sort!(out, [:target_time, :group])
    return out
end

"""
    build_refday_basecase(results, matches, method;
                          res_tags, scope, fallback_matches, collect_trace = false) -> Dict

Assemble a TwoDayAhead-style FBMC basecase from a target→reference time mapping
(`matches` with columns `target_time`, `matched_time` — and `group` when
produced by [`match_by_scope`](@ref)). Returns a Dict with the keys `calc_ram`
/ `calc_fbmc_params` consume:

- `:netinput_ac` => DenseAxisArray (node × target_time) nodal net injection
  (import-positive, the model's ACINJECTION convention)
- `:lineflows`   => DenseAxisArray (line × target_time) = PTDFn · netinput

so the reference-day construction is a drop-in replacement for the
`TwoDayAhead` optimization. With the shift's `enforce_balance` (default), each
target column is globally balanced (`Σ_n netinput_ac[n, tt] = 0`, production =
consumption), keeping the PTDF flow computation physically consistent.

# Scoped (per-TSO) matching
Pass `scope` (e.g. `ZonalMatchScope()`) together with a `matches` table from
[`match_by_scope`](@ref) to let every node group borrow its own reference day.
Groups without a match for an hour fall back to `fallback_matches` (a global
match table); hours unresolved in any group are skipped with a warning.

# Traceability
With `collect_trace = true` the returned Dict carries an extra `:trace` entry,
a `Dict{Symbol,DataFrame}` with:

- `:REFDAY_MATCH`  — per (group, target_time): matched reference time, cluster
  metadata, and whether the global fallback was used;
- `:REFDAY_GROUPS` — group → node membership (join key for `:REFDAY_MATCH`);
- `:REFDAY_SHIFT`  — sparse per-(Time, node, component) injection deltas from
  `shift_single` (physical `RES`/`conv`/`load`/`sto` levers plus `balance`), and
  per-(Time, zone) `np_relax` rows (zone label in the `node` column) recording
  how far each zone's net position was left relaxed toward the reference.

Together they reconstruct the construction exactly. Trace deltas are
export-positive (feed-in) while the persisted `ACINJECTION` (and the returned
`:netinput_ac`) are import-positive, hence (summing only the per-node injection
components — `np_relax` is a zone-level annotation, excluded):
`netinput_ac[n, tt] = ACINJECTION_source(n, ref(n, tt)) − Σ deltas(n, tt)`.
"""
function build_refday_basecase(results::DataFiles, matches, method::ShiftMethod;
                               res_tags = ["solar", "wind"],
                               scope::MatchScope = GlobalMatchScope(),
                               fallback_matches = nothing,
                               collect_trace::Bool = false,
                               source_state::RefdaySourceState = DayAheadSource())
    validate_shares(method)
    params = results.params
    nd = precompute_nodal(results, source_state; res_tags = res_tags)

    tgt_times = sort(unique(matches.target_time))
    groups = node_groups(scope, params)
    groupmap, skipped = resolve_group_times(matches, scope, params, tgt_times;
                                            fallback_matches = fallback_matches)
    refmap = _expand_group_times(groupmap, groups)
    build_times = [tt for tt in tgt_times if !(tt in Set(skipped))]
    isempty(build_times) && error("build_refday_basecase: no target hour is fully resolved — check matches/scope/fallback_matches.")

    # Precompute a static GSK for the redistribution key; time-dependent
    # strategies bypass it in _key_weights (per-timestep load weights instead).
    gsk = (method isa ShareShift && method.redist isa GSKRedist &&
           !is_time_dependent(method.redist.strategy)) ?
          build_gsk(params, method.redist.strategy; normalize_empty = :flat) : nothing

    collector = collect_trace ? ShiftTraceCollector() : nothing

    nodes = nd.nodes
    nidx  = Dict(n => i for (i, n) in enumerate(nodes))
    Pmat  = zeros(length(nodes), length(build_times))
    for (j, tt) in enumerate(build_times)
        ref_of_node = Dict(n => refmap[(n, tt)] for n in nodes)
        p_new = shift_single(nd, params, tt, ref_of_node, method; gsk = gsk, trace = collector)
        for n in nodes
            # shift_single works export-positive (feed-in); :netinput_ac must be
            # in the model's import-positive ACINJECTION convention (what
            # calc_ram / build_gsk_timeseries consume), so negate back here.
            Pmat[nidx[n], j] = -p_new[n]
        end
    end

    netinput_ac = Containers.DenseAxisArray(Pmat, nodes, collect(build_times))

    PTDFn = dict_to_matrix(params.ptdf)                  # l×n DenseAxisArray
    ptdf_nodes = collect(axes(PTDFn, 2))
    lines = collect(axes(PTDFn, 1))
    Preordered = Pmat[[nidx[n] for n in ptdf_nodes], :]  # align rows to PTDF node order
    LF = PTDFn.data * Preordered
    lineflows = Containers.DenseAxisArray(LF, lines, collect(build_times))

    out = Dict{Symbol,Any}(:netinput_ac => netinput_ac, :lineflows => lineflows)
    if collect_trace
        groups_df = DataFrame(group = String[], node = String[])
        for g in sort(collect(keys(groups))), n in sort(collect(groups[g]))
            push!(groups_df, (g, n))
        end
        out[:trace] = Dict{Symbol,DataFrame}(
            :REFDAY_MATCH  => _refday_match_trace(groupmap, matches, fallback_matches),
            :REFDAY_GROUPS => groups_df,
            :REFDAY_SHIFT  => shift_trace_df(collector),
        )
    end
    return out
end

# ---------------------------------------------------------------------------
# Config-driven entry point (used by the solving pipeline)
# ---------------------------------------------------------------------------

"""
    _load_refday_source(bc::ReferenceDayBasecase) -> (ref::DataFiles, state::RefdaySourceState)

Resolve `bc.source_type` to its `RefdaySourceState` and load the source
results with the matching table prefix. When `bc.source` is already a
`DataFiles`, it is used as-is (the caller is responsible for having loaded it
with the right prefix).
"""
function _load_refday_source(bc::ReferenceDayBasecase)
    state = _source_state(bc.source_type)
    ref = bc.source isa DataFiles ? bc.source :
          DataFiles(bc.source; type = _datafiles_type(state))
    return ref, state
end

"State-specific source validation — fail loudly on unusable sources."
function _validate_refday_source(::TwoDayAheadSource, ref::DataFiles, source_type)
    isempty(ref.NETINPUT) && isempty(ref.LINEFLOW) && error(
        "ReferenceDayBasecase: source results contain no nodal NETINPUT/LINEFLOW data " *
        "for source_type = \"$source_type\". Choose a source/result set whose selected " *
        "MarketState produced nodal network data.")
    return nothing
end
function _validate_refday_source(::RedispatchSource, ref::DataFiles, source_type)
    isempty(ref.REDISP) && error(
        "ReferenceDayBasecase: source_type = \"REDISP\" but the source run has no " *
        "redispatch results (empty REDISP table).")
    isempty(ref.NETINPUT) && isempty(ref.LINEFLOW) && error(
        "ReferenceDayBasecase: redispatch source has no nodal NETINPUT/LINEFLOW data.")
    return nothing
end
function _validate_refday_source(::DayAheadSource, ref::DataFiles, source_type)
    isempty(ref.GEN) && error(
        "ReferenceDayBasecase: source results contain no day-ahead GEN data " *
        "(source_type = \"$source_type\").")
    return nothing
end

"""
    build_refday_basecase(bc::ReferenceDayBasecase, params::Parameters;
                          collect_trace = true) -> Dict

Config-driven entry point: load the forecast run's results, run the (scoped)
reference-day matching per `bc.matching`, shift per `bc.shift`, and return the
whole-horizon basecase dict (`:netinput_ac`, `:lineflows` — plus `:trace` by
default, see the `collect_trace` section of the assembly method).

`bc.source_type` selects the source MarketState (see `_source_state`);
matching data and injection baseline always come from that one state.

Validates that the source results are usable (non-empty parameters, identical
node set, state-specific data present) before building.
"""
function build_refday_basecase(bc::ReferenceDayBasecase, params::Parameters;
                               collect_trace::Bool = true)
    ref, state = _load_refday_source(bc)
    cfg = bc.matching

    # --- validation: fail loudly on unusable sources ---
    isempty(ref.params.sets.N) && error(
        "ReferenceDayBasecase: source results have empty Parameters (stale params.jld2 " *
        "from an older POMATWO version?). Re-run the forecast scenario with the current package.")
    Set(ref.params.sets.N) == Set(params.sets.N) || error(
        "ReferenceDayBasecase: node set of the source results does not match the current model.")
    _validate_refday_source(state, ref, bc.source_type)

    # --- renewable frame + matching (from the same MarketState as the shift) ---
    gen_df = copy(_source_gen(state, ref))
    add_planttype!(gen_df, ref.params)
    filter_powerplants!(gen_df; type_in_planttype = cfg.res_tags)
    isempty(gen_df) && error("ReferenceDayBasecase: no plants match res_tags = $(cfg.res_tags).")
    add_nodecol!(gen_df, ref.params)
    add_time_cluster!(gen_df, cfg.cluster_size)
    add_weekday!(gen_df, cfg.start_date)

    kw = (lookback = cfg.lookback, keycols = cfg.keycols, valuecols = [:GEN],
          value_methods = cfg.value_methods, weights = cfg.weights,
          exact_weekend = cfg.exact_weekend)

    if cfg.scope isa GlobalMatchScope
        matches = match_by_cluster(gen_df; kw...)
        fallback = nothing
    else
        matches = match_by_scope(gen_df, cfg.scope, ref.params; kw...)
        fallback = match_by_cluster(gen_df; kw...)   # global fallback for unmatched groups
    end

    return build_refday_basecase(ref, matches, bc.shift;
                                 res_tags = cfg.res_tags, scope = cfg.scope,
                                 fallback_matches = fallback,
                                 collect_trace = collect_trace,
                                 source_state = state)
end
