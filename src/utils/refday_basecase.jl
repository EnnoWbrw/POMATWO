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
# `np_relax`). OPTIONALLY (`enforce_balance`, off by default) a final pass then
# forces the whole basecase to be globally BALANCED (Σ_n injection = 0,
# production = consumption) by adjusting conventional generation (load as a last
# resort); without it the assembled basecase need not satisfy Σ_n injection = 0.
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

"""
Spread a zonal correction to nodes using an existing [`GSKStrategy`](@ref).

Static strategies are time-independent — the plain GSK column. A *time-dependent*
strategy is a reference-day-texture key: the weight comes from its own
`timedep_node_weight` method and is evaluated per node at that node's REFERENCE hour,
not at the target hour. [`GenLoadGSK`](@ref), for example, returns `|gen| + |load|`
there.
"""
struct GSKRedist <: RedistKey
    strategy::GSKStrategy
end
GSKRedist() = GSKRedist(FlatGSK())

"""
Spread each lever proportional to the reference day's own texture of THAT component,
evaluated at the node's REFERENCE hour (the pattern being preserved is the reference
day's, which is the whole point of the key). Unlike the other keys this one is
lever-dependent — the gap cascade rebuilds it per component:

| lever | weight of node `n` at its reference hour `r` |
|---|---|
| `:RES` | reference-day renewable generation `RES(n, r)` |
| `:conv` | reference-day conventional generation `CONV(n, r)` |
| `:load` | reference-day load `LOAD(n, r)` |
| `:sto` | *installed* storage power `gmax_sto_dis(n) + gmax_sto_chg(n)` |

Storage is the exception because the reference day's storage dispatch is frequently zero
at every node of a zone, which would degenerate to the flat fallback exactly when the
`:sto` lever is reached; installed power is the only always-present measure of which
node can actually move storage. A zone whose weights sum to zero (no load anywhere at
the reference hour, no renewables at night) still falls back to a flat split.
"""
struct RefPropRedist <: RedistKey end

"""
Spread proportional to nodal load share.

Evaluated at the TARGET hour: nodal load is a target-day forecast quantity, known
for the delivery day, so this key deliberately does not read the reference day.
"""
struct LoadPropRedist <: RedistKey end

"""
Spread by random positive weights, reproducible for a fixed `seed`.

Weights are drawn per (zone, target time) from an RNG seeded by `seed` combined
with the zone's nodes and the TARGET timestep, so a run is deterministic and
independent of node iteration order.
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
- `prestep`: which components are hard-set to the target hour's nodal value
  *before* the gap is apportioned — `:res`, `:load`, both as `[:res, :load]`, or
  the default `Symbol[]` for no pre-step. At BOTH resolutions a pre-step is the
  per-node hard-set: afterwards the intra-zone distribution of that component *is*
  the target day's (with the target day's zonal total), mirroring the D2CF step of
  inserting the delivery-day forecast into the reference snapshot.
  A pre-stepped component is then **frozen** for the rest of the construction
  (`prestep_levers`): its lever is skipped in the gap cascade and in the balance
  pass, so the target day's nodal texture is what the basecase ends up carrying.
  Giving a pre-stepped component a β share is therefore a configuration error
  (`validate_shares`), not a warning — that share could never be spent. Both
  per-zone hard-set totals are reported in `REFDAY_DIAG` alongside the levers.
- `redist`: nodal redistribution key for zonal corrections.
- `fallback_order`: cascade order for remainders when a component saturates
  (physical levers only). A frozen lever counts as saturated: it absorbs nothing
  and passes the remainder on. A zone's gap that no physical lever can absorb is
  left relaxed toward reference and recorded as `"np_relax"`.
- `enforce_balance`: **opt-in** (default `false`). When `true`, a final pass forces
  the whole basecase to be globally balanced (`Σ_n injection = 0`, i.e.
  production = consumption) by adjusting conventional generation (load as a last
  resort). Left off, the assembled basecase carries whatever imbalance the
  reference day and the relaxed gaps leave behind. See `_enforce_global_balance!`.
- `load_shift_share::Float64 = 0.2`: γ, the cap on the load lever. The load
  deviation of a node accumulated over the whole construction (cascade *and*
  balance pass) stays within `[-γ·load_max, min(γ·load_min, load_ref)]`, with
  `load_max`/`load_min` the node's extreme loads over the forecast horizon —
  load can neither grow without limit nor be cut to zero. See `_load_bounds`.
"""
Base.@kwdef struct ShareShift <: ShiftMethod
    β_RES::Float64  = 0.0
    β_conv::Float64 = 0.5
    β_load::Float64 = 0.5
    resolution::Symbol = :zonal
    prestep::Union{Symbol,Vector{Symbol}} = Symbol[]
    redist::RedistKey  = GSKRedist()
    fallback_order::Vector{Symbol} = [:conv, :sto, :load]
    enforce_balance::Bool = false
    load_shift_share::Float64 = 0.2
end

"The components hard-set by the pre-step, normalized to a deduplicated vector."
prestep_components(m::ShareShift) =
    m.prestep isa Symbol ? [m.prestep] : unique(m.prestep)

"""
Pre-step components that exist, each with the β field that must be zero for it and the
gap-cascade lever it freezes (see `prestep_levers`).
"""
const PRESTEP_COMPONENTS = (:res => (:β_RES, :RES), :load => (:β_load, :load))

"""
    prestep_levers(m::ShareShift) -> Set{Symbol}

The gap-cascade levers frozen by `m`'s pre-steps (`:res` → `:RES`, `:load` → `:load`).
A frozen lever is skipped in `shift_single`'s cascade and in the global balance pass, so
the hard-set target-day nodal texture of that component survives the whole construction.
"""
prestep_levers(m::ShareShift) =
    Set(lever for (comp, (_, lever)) in PRESTEP_COMPONENTS if comp in prestep_components(m))

"Error on invalid share sum, resolution, load-lever share, pre-step component, or a β share given to a pre-stepped (hence frozen) component."
function validate_shares(m::ShareShift)
    s = m.β_RES + m.β_conv + m.β_load
    s <= 1.0 + 1e-6 || error("Shift shares sum to $s, must be ≤ 1.0 (leftover fraction is np_relax)")
    pre = prestep_components(m)
    bad = setdiff(pre, first.(PRESTEP_COMPONENTS))
    isempty(bad) ||
        error("unsupported prestep component(s) $bad (allowed: :res, :load)")
    for (comp, (βname, _)) in PRESTEP_COMPONENTS
        (comp in pre && getfield(m, βname) > 0) && error(
            "prestep includes :$comp but $βname = $(getfield(m, βname)) — a pre-stepped " *
            "component is hard-set to the target day's nodal value and frozen afterwards, " *
            "so its β share can never be spent. Set $βname = 0.0 (give the share to " *
            "another lever) or drop :$comp from prestep.")
    end
    m.resolution in (:zonal, :nodal) || error("resolution must be :zonal or :nodal, got :$(m.resolution)")
    m.load_shift_share >= 0.0 ||
        error("load_shift_share must be ≥ 0 (got $(m.load_shift_share))")
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
- `keycols::Vector{Symbol} = [:plant_type, :node]`: profile grouping keys. A
  `:zone` column is always available (put it in `keycols` to match zonal LOAD/NP
  under `GlobalMatchScope`).
- `match_valuecols::Vector{Symbol} = [:GEN]`: which quantities the reference-day
  distance compares — a subset of `{:GEN, :LOAD, :NP}` (renewable generation,
  load, zonal net position). The default `[:GEN]` reproduces the original
  renewable-only matching. `:LOAD` is nodal when `:node ∈ keycols`, otherwise
  zonal; `:NP` is always zonal (derived from the source state's nodal injection
  baseline). `value_methods` and `weights` apply to every requested quantity.
  NOTE: LOAD/NP are typically ~GW and dominate the raw L1 distance unless
  down-weighted, e.g. `weights = Dict(:LOAD_median => 1e-3, :NP_median => 1e-3)`.
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
    match_valuecols::Vector{Symbol} = [:GEN]
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
  `""`/`"DA"` = day-ahead results (zonal day-ahead stages report their nodal
  injections too, see `report_nodal_flows!`); `"2DA"` = TwoDayAhead basecase tables;
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
            # both pre-steps hard-set RES and load to the target hour and freeze
            # them, so neither may carry a β share as well (`validate_shares`
            # errors); conventional generation closes the remaining gap, and what
            # it cannot absorb passes down `fallback_order` to storage — the frozen
            # load lever hands it straight on, so it ends up as np_relax.
            shift = ShareShift(β_conv = 1.0, β_load = 0.0, prestep = [:res, :load]),
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

Map the `source_type` config string to its dispatch type. The short strings are the
legacy aliases of the market states (see `market_state_type`), kept because they are part
of the public `ReferenceDayBasecase` API:
`"2DA"` → `TwoDayAheadSource` (`TwoDayAhead_*` result tables),
`""`/`"DA"` → `DayAheadSource` (plain day-ahead tables — nodal as well as
plant-level, for zonal and nodal DA markets alike),
`"REDISP"` → `RedispatchSource` (redispatch results).
"""
_source_state(source_type::AbstractString) =
    isempty(source_type) ? DayAheadSource() :
    _source_state(market_state_type(source_type))

_source_state(::Type{TwoDayAhead}) = TwoDayAheadSource()
_source_state(::Type{DayAhead})    = DayAheadSource()
_source_state(::Type{Redispatch})  = RedispatchSource()
_source_state(::Type{MS}) where {MS<:MarketState} = error(
    "ReferenceDayBasecase: market state $(nameof(MS)) cannot serve as a basecase source. " *
    "Supported: \"\"/\"DA\" (day-ahead), \"2DA\" (TwoDayAhead), \"REDISP\" (redispatch).")

"The `MarketState` whose result tables this source state reads."
_source_market_state(::TwoDayAheadSource) = TwoDayAhead
_source_market_state(::DayAheadSource)    = DayAhead
_source_market_state(::RedispatchSource)  = Redispatch

"Table prefix `DataFiles` needs for this source state."
_datafiles_type(s::RefdaySourceState) = result_prefix(_source_market_state(s))

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

Read from the persisted `NETINPUT` table of the selected source state — every
stage writes it, including a *zonal* day-ahead (see `report_nodal_flows!` in
energy_balances.jl). Its `ACINJECTION` column follows the model's
*import-positive* convention (`= load + charge − gen`, see the nodal balance in
energy_balances.jl and the NP negation in `calc_ram`), so it is negated here.
Legacy result sets reconstruct it from `LINEFLOW` via the incidence convention
(line_start = +1, line_end = -1); errors when neither an `ACINJECTION` column
nor `LINEFLOW` data is available.

The shift pipeline works entirely in this export-positive space;
[`build_refday_basecase`](@ref) negates back to the model's import-positive
convention when assembling `:netinput_ac`.
"""
function _ac_injection_baseline(::RefdaySourceState, ref::DataFiles)
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

"""
    precompute_nodal(results::DataFiles, state::RefdaySourceState = TwoDayAheadSource();
                     res_tags) -> NamedTuple

Precompute the per-(node, time) lookups used by the shift. All state-dependent
data come from the SAME source MarketState selected by `state`:

- `RES`, `CONV`, `STO` — nodal generation by class from the state's generation
  table (`_source_gen`: `GEN` for the day-ahead / TwoDayAhead states,
  `GEN_REDISP` for redispatch); `STO` is the reference day's **net storage
  injection** (discharge − charge), the charging half read from the state's
  charging table (`_source_charge`: `CHARGE`, resp. `CHARGE_REDISP`).
- `LOAD` — nodal load of the source results' `Parameters` (`_nodal_load_at`), plus
  its per-node extremes `load_max` / `load_min` over that forecast horizon (the
  load lever's cap, see `_load_bounds`).
- `P` — AC net-injection baseline, **export-positive** (see
  `_ac_injection_baseline`), read from the state's `NETINPUT` table. Reference-day
  storage dispatch is part of it, which is why the storage LEVER is incremental to
  `STO` (see `_comp_bounds`).
- `gmax_conv` / `gmax_res` — per-(node, time) availability-weighted generation
  caps (via `calc_gmax`); `gmax_sto_dis` / `gmax_sto_chg` — per-node installed
  storage power, assumed available at every timestep (a rough approximation
  ignoring state-of-charge), which makes storage a bidirectional shift lever.
- `nodes`, `times`, `nodes_in_zone` — index sets and the zone map.
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
    STO  = Dict{Tuple{String,Int},Float64}()
    for row in eachrow(gen)
        key = (row.node, Int(row.Time))
        if row.cls == :res
            RES[key]  = get(RES,  key, 0.0) + Float64(row.GEN)
        elseif row.cls == :conv
            CONV[key] = get(CONV, key, 0.0) + Float64(row.GEN)
        elseif row.cls == :sto
            STO[key]  = get(STO,  key, 0.0) + Float64(row.GEN)      # discharge
        end
    end

    # Charging half of the reference day's net storage injection. The table is
    # storage-only (only `add_storage` writes CHARGE / CHARGE_REDISP), so every row
    # with a known node belongs in STO.
    chg = _source_charge(state, results)
    if !isempty(chg)
        for row in eachrow(chg)
            n = get(params.plant2node, row.index, "")
            isempty(n) && continue
            key = (n, Int(row.Time))
            STO[key] = get(STO, key, 0.0) - Float64(coalesce(row.CHARGE, 0.0))
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
    # per-node load envelope over the whole horizon — the load lever's cap (F4)
    load_max = Dict(n => isempty(times) ? 0.0 : maximum(LOAD[(n, t)] for t in times) for n in nodes)
    load_min = Dict(n => isempty(times) ? 0.0 : minimum(LOAD[(n, t)] for t in times) for n in nodes)

    nodes_in_zone = Dict(z => sort(collect(v)) for (z, v) in params.nodes_in_zone)

    return (; nodes, times, RES, CONV, STO, gmax_conv, gmax_res, gmax_sto_dis, gmax_sto_chg,
              P, LOAD, load_max, load_min, nodes_in_zone)
end

# ---------------------------------------------------------------------------
# Redistribution, bounded waterfilling, component bounds
# ---------------------------------------------------------------------------

# Per-key nodal weight rule (dispatched on RedistKey). Add a new key by
# defining another `_key_weights` method — no edit to `_redist_weights` needed.
#
# Every method receives BOTH the target hour `t_tgt` and `ref_of_node`, the
# per-node reference hour of this target hour, and must read the one the key's
# meaning calls for: a key that describes the REFERENCE day's texture (RefProp,
# time-dependent GSK) evaluates at `ref_of_node[n]`, a key that describes the
# TARGET day (LoadProp — the delivery day's nodal load forecast) at `t_tgt`.
#
# `comp` is the physical lever the weights are about to spread (`:RES`, `:conv`,
# `:load`, `:sto`), or `nothing` outside the gap cascade. Only RefProp uses it —
# every other key is lever-blind and must accept and ignore it, since
# `shift_single` passes it unconditionally.
"Reference hour of node `n`, falling back to the target hour when unmapped."
@inline _ref_hour(ref_of_node, n, t_tgt) = get(ref_of_node, n, t_tgt)

_key_weights(::LoadPropRedist, nd, params, znodes, t_tgt, ref_of_node;
             gsk = nothing, comp = nothing) =
    Dict(n => get(nd.LOAD, (n, t_tgt), 0.0) for n in znodes)   # target-day key

function _key_weights(::RefPropRedist, nd, params, znodes, t_tgt, ref_of_node;
                      gsk = nothing, comp = nothing)
    # Per-lever reference-day texture, read at each node's own REFERENCE hour.
    # :sto is the exception — reference-day storage dispatch is zero across whole
    # zones often enough that a ref-day quantity would collapse into the flat
    # fallback precisely when the :sto lever is reached, so installed power
    # (time-independent) says which node can move storage at all.
    comp === :sto && return Dict(n => nd.gmax_sto_dis[n] + nd.gmax_sto_chg[n] for n in znodes)
    src = comp === :RES  ? nd.RES  :
          comp === :conv ? nd.CONV :
          comp === :load ? nd.LOAD :
          error("RefPropRedist has no weight for shift component :$comp — it is a " *
                "per-component key and needs one of :RES, :conv, :load, :sto " *
                "(comp === nothing means it was called outside the gap cascade).")
    return Dict(n => get(src, (n, _ref_hour(ref_of_node, n, t_tgt)), 0.0) for n in znodes)
end

function _key_weights(key::GSKRedist, nd, params, znodes, t_tgt, ref_of_node;
                      gsk = nothing, comp = nothing)
    if is_time_dependent(key.strategy)
        # Time-dependent strategies (e.g. GenLoadGSK): let the strategy build its
        # own weight from the forecast run's nodal data at the node's REFERENCE
        # hour (this is reference-day texture, like RefPropRedist). nd.P is the
        # EXPORT-positive net-injection baseline (see _ac_injection_baseline), so
        # gen = P + load — build_gsk_timeseries feeds the same primitive
        # gen = load − netinput_ac from the import-positive persisted table.
        return Dict(n => begin
            r = _ref_hour(ref_of_node, n, t_tgt)
            load = get(nd.LOAD, (n, r), 0.0)
            gen = get(nd.P, (n, r), 0.0) + load
            timedep_node_weight(key.strategy, params, n; gen = gen, load = load)
        end for n in znodes)
    end
    G = gsk === nothing ? build_gsk(params, key.strategy; normalize_empty = :flat) : gsk
    z = params.node2zone[first(znodes)]
    return Dict(n => G[n, z] for n in znodes)   # static strategy: time-independent
end

function _key_weights(key::RandomRedist, nd, params, znodes, t_tgt, ref_of_node;
                      gsk = nothing, comp = nothing)
    # per-(zone, target time) seed so weights are reproducible and order-independent
    # across levers as well
    rng = Random.Xoshiro(hash((key.seed, sort(znodes), t_tgt)))
    return Dict(n => rand(rng) for n in sort(znodes))
end

"""
Nodal redistribution weights within a zone for the chosen key (flat fallback when
they sum to zero).

`comp` names the physical lever being spread (`:RES`, `:conv`, `:load`, `:sto`); pass it
whenever one is known, as [`RefPropRedist`](@ref) has no lever-blind weight and errors
without it. The other keys ignore it.
"""
function _redist_weights(key::RedistKey, nd, params, znodes, t_tgt, ref_of_node;
                         gsk = nothing, comp = nothing)
    w = _key_weights(key, nd, params, znodes, t_tgt, ref_of_node; gsk = gsk, comp = comp)
    sum(values(w)) <= 0 && (w = Dict(n => 1.0 for n in znodes))
    return w
end

"""
    _waterfill(A, znodes, w, lo, hi) -> (applied::Dict, remainder, reallocated)

Distribute amount `A` over `znodes` proportional to weights `w`, clipped to
per-node bounds `[lo, hi]` (bounds may be ±Inf). Redistributes the clipped
remainder among nodes that still have room. Returns the applied per-node deltas,
any unabsorbable remainder, and `reallocated` — how much of the FIRST pass's
unclipped, purely key-proportional allocation `A·w[n]/Σw` had to be re-spread
because it hit a bound (`Σ_n max(0, |want_n| − |applied_n|)`). A positive
`reallocated` means the realized spatial split departs from the redistribution
key; it is reported per zone and lever in the `REFDAY_DIAG` trace table.
"""
function _waterfill(A, znodes, w, lo, hi; iters = 50)
    applied = Dict(n => 0.0 for n in znodes)
    remaining = A
    reallocated = 0.0
    for it in 1:iters
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
            it == 1 && (reallocated += max(0.0, abs(want) - abs(δ)))
            applied[n] += δ
            moved += δ
        end
        remaining -= moved
    end
    return applied, remaining, reallocated
end

"""
    ShiftLevers(nd, ref_of_node, load_shift_share)

Working state of the physical levers at one target hour: what each node's RES
generation, conventional generation, load and NET storage injection currently
are in the basecase under construction, seeded from that node's reference hour.
`shift_single` mutates it as deltas are applied, so every lever's remaining room
(`_comp_bounds`) is always relative to the state reached so far.

`load0` holds the load the γ budget is measured against, which is what lets the load
lever's cap apply to the CUMULATIVE deviation — the gap cascade and the global balance
pass share one budget (`_load_bounds`). It is the reference hour's load and nothing
writes it afterwards — a `:load` pre-step needs no re-anchoring, because it freezes the
load lever outright (`prestep_levers`), leaving neither the cascade nor the balance pass
a way to spend the budget at all.
"""
struct ShiftLevers
    res::Dict{String,Float64}
    conv::Dict{String,Float64}
    load::Dict{String,Float64}
    sto::Dict{String,Float64}
    load0::Dict{String,Float64}
    load_shift_share::Float64
end

function ShiftLevers(nd, ref_of_node::AbstractDict, load_shift_share::Real)
    at(d, n) = get(d, (n, ref_of_node[n]), 0.0)
    load = Dict(n => at(nd.LOAD, n) for n in nd.nodes)
    return ShiftLevers(
        Dict(n => at(nd.RES,  n) for n in nd.nodes),
        Dict(n => at(nd.CONV, n) for n in nd.nodes),
        load,
        Dict(n => at(nd.STO,  n) for n in nd.nodes),
        copy(load),
        Float64(load_shift_share),
    )
end

"""
    _load_bounds(lev, nd, n) -> (lo, hi)

Room left in the load lever at node `n`. The TOTAL load deviation `δ` of a node
(export-positive: `δ > 0` = load cut) accumulated over the gap cascade AND the
global balance pass is confined to

    δ ∈ [ −γ·load_max[n] ,  min(γ·load_min[n], load0[n]) ]

with γ = `ShareShift.load_shift_share`, `load_max`/`load_min` the node's extreme
loads over the forecast horizon and `load0[n]` the reference hour's load, the anchor
the budget is measured from (so load can never be driven negative). The part already
spent is `load0[n] - load[n]`, which is why this returns the *remaining* room rather
than the total bound. Never reached when `:load` is pre-stepped — the lever is frozen.
"""
function _load_bounds(lev::ShiftLevers, nd, n)
    γ = lev.load_shift_share
    spent = lev.load0[n] - lev.load[n]
    return (-γ * nd.load_max[n] - spent,
            min(γ * nd.load_min[n], lev.load0[n]) - spent)
end

"""
    _comp_bounds(comp, n, t, nd, lev) -> (lo, hi)

Per-node signed bounds (Δ injection, export-positive) still available from lever
`comp` at node `n` and target time `t`, given the levers' current state `lev`.

`:conv` / `:RES` are capped by the availability-weighted generation cap at `t`
minus what the node already produces. `:sto` is **incremental** to the reference
day's net storage injection `nd.STO` — that dispatch is already inside the
injection baseline `P`, so a node discharging at full power in the reference hour
has no headroom up left. `:load` is capped by γ, see `_load_bounds`.
"""
function _comp_bounds(comp, n, t, nd, lev::ShiftLevers)
    if comp == :conv
        return (-lev.conv[n], get(nd.gmax_conv, (n, t), 0.0) - lev.conv[n])
    elseif comp == :load          # cut load → raise injection; add load → lower it
        return _load_bounds(lev, nd, n)
    elseif comp == :RES
        return (-lev.res[n], get(nd.gmax_res, (n, t), 0.0) - lev.res[n])
    elseif comp == :sto           # storage: discharge up, charge down; installed power, every t
        return (-nd.gmax_sto_chg[n] - lev.sto[n], nd.gmax_sto_dis[n] - lev.sto[n])
    else
        error("_comp_bounds: unknown shift component :$comp (physical levers only: :RES, :conv, :load, :sto)")
    end
end

"Below this the basecase is treated as globally balanced (production ≈ consumption)."
const BALANCE_TOL = 1e-6

"""
    _enforce_global_balance!(p_new, nd, t, lev, trace; frozen = Set{Symbol}())

Force the basecase to represent a globally **balanced** system: drive the total
net injection `R = Σ_n p_new` (export-positive) to zero so that
`Σ gen = Σ load + Σ charge` (production = consumption). The correction `-R` is
applied as physical **conventional generation** adjustments, bounded per node by
the availability-weighted headroom `[-conv[n], gmax_conv[(n,t)] - conv[n]]` and
spread by remaining room. If conventional generation saturates, **load** absorbs
the residual (add load to shed a surplus, cut load to cover a deficit), also with
a warning. All applied deltas are traced as `"balance"`. Because only physical
quantities move, every `p_new[n]` remains `gen − load − charge`, so each zone's
net position stays physically backed.

`frozen` names the levers a pre-step hard-set (`prestep_levers`); `:load` among them
takes the load fallback off the table, since undoing the target day's nodal load here
is exactly what the pre-step exists to prevent. Conventional generation is never
pre-stepped, so the primary lever is unaffected.

Balance is *not* guaranteed: the load lever shares one cumulative budget with the
gap cascade and is capped by `ShareShift.load_shift_share` (see `_load_bounds`),
so with a small γ and exhausted conventional headroom a residual can survive —
that case warns a second time and leaves `Σ_n p_new ≠ 0`. A frozen load lever
leaves the residual outright, with a warning naming the pre-step.
"""
function _enforce_global_balance!(p_new, nd, t, lev::ShiftLevers, trace;
                                  frozen = Set{Symbol}())
    nodes = nd.nodes
    R = sum(values(p_new))              # export-positive global net injection; want 0
    abs(R) <= BALANCE_TOL && return p_new
    A = -R                              # injection change to apply so Σ becomes 0

    # --- primary lever: conventional generation ---
    lo = Dict{String,Float64}(); hi = Dict{String,Float64}()
    for n in nodes
        lo[n], hi[n] = _comp_bounds(:conv, n, t, nd, lev)
    end
    w  = A > 0 ? Dict(n => max(hi[n], 0.0) for n in nodes) :
                 Dict(n => max(-lo[n], 0.0) for n in nodes)
    applied, rem, _ = _waterfill(A, nodes, w, lo, hi)
    for n in nodes
        _record!(trace, t, n, "balance", applied[n])
        p_new[n]    += applied[n]
        lev.conv[n] += applied[n]
    end

    # --- last resort: load, within what the cascade left of its γ budget ---
    if abs(rem) > BALANCE_TOL && :load in frozen
        @warn "refday balance at t=$t: conventional headroom insufficient (residual " *
              "$(round(rem; digits=3)) MW) and the load lever is frozen by the :load " *
              "pre-step — left unbalanced rather than undoing the target day's load."
    elseif abs(rem) > BALANCE_TOL
        @warn "refday balance at t=$t: conventional headroom insufficient (residual $(round(rem; digits=3)) MW); adjusting load."
        loL = Dict{String,Float64}(); hiL = Dict{String,Float64}()
        for n in nodes
            loL[n], hiL[n] = _comp_bounds(:load, n, t, nd, lev)
        end
        wL  = rem > 0 ? Dict(n => max(hiL[n], 0.0) for n in nodes) :
                        Dict(n => max(-loL[n], 0.0) for n in nodes)
        appliedL, rem2, _ = _waterfill(rem, nodes, wL, loL, hiL)
        for n in nodes
            _record!(trace, t, n, "balance", appliedL[n])
            p_new[n]    += appliedL[n]
            lev.load[n] -= appliedL[n]              # +injection ⇒ load down
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

Components: `"RES_prestep"` / `"load_prestep"` (the hard pre-steps), `"RES"`,
`"conv"`, `"load"`, `"sto"` (physical per-node levers), `"balance"` (per-node conventional-gen/load deltas from the
global balance pass, `_enforce_global_balance!`), and `"np_relax"` — a
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

"""
    ShiftDiagCollector()

Collects the apportionment diagnostics of `shift_single` — one row per (target hour,
zone, lever) of the gap cascade, preceded per zone by one row per active pre-step
(`"RES_prestep"` / `"load_prestep"`, in the order they ran), independent of the
per-node `REFDAY_SHIFT` trace
(different schema, different granularity). Convert with `shift_diag_df`;
persisted as the `REFDAY_DIAG` trace table. Under `resolution = :nodal` each
"zone" is a single node and the `zone` column carries the node id (the same
convention as the `np_relax` rows of `REFDAY_SHIFT`).

Per row:
- `want` — the amount handed to the waterfill, `β_comp · D` plus the remainder
  carried over from the previous lever of the cascade;
- `applied` — what the lever actually absorbed, `Σ_n` applied deltas;
- `reallocated` — how much of the first waterfill pass's key-proportional
  allocation was clipped and re-spread over other nodes (see `_waterfill`);
  positive means the realized spatial split departs from the redistribution key;
- `beta_configured` — the configured share of this lever, `0.0` for levers that
  only ever receive cascaded remainders (e.g. `:sto`);
- `beta_realised` — `Σ_n |applied_n| / |D|`, i.e. the share of the zone's gap this
  lever really moved; `0.0` when the gap `D` vanishes. It differs from
  `beta_configured` whenever the cascade interferes: it *exceeds* the configured
  share when the lever absorbs a remainder carried over from an earlier saturated
  lever, and *falls short* when the lever itself saturates.

A **pre-step row** reads the same columns differently, because a hard-set is not an
apportionment: `want == applied` (the zone's summed hard-set delta — nothing is asked
for and refused), `reallocated == 0` (no redistribution key is involved) and
`beta_configured == 0` (a pre-step spends no share of the gap; `validate_shares`
forbids one). `beta_realised` uses the same `|D|` as the levers below it, so it reads
as the multiple of the *remaining* gap that the pre-step moved — a value well above 1
is normal and is the point of reporting it. The per-node deltas behind the row are the
`"RES_prestep"` / `"load_prestep"` rows of `REFDAY_SHIFT`.

A **frozen lever** (its component pre-stepped, see `prestep_levers`) reports the
remainder it was handed as `want` with `applied == 0`: it absorbs nothing and passes
the whole amount on, exactly like a lever with no headroom left.
"""
struct ShiftDiagCollector
    Time::Vector{Int}
    zone::Vector{String}
    component::Vector{String}
    want::Vector{Float64}
    applied::Vector{Float64}
    reallocated::Vector{Float64}
    beta_configured::Vector{Float64}
    beta_realised::Vector{Float64}
end
ShiftDiagCollector() = ShiftDiagCollector(Int[], String[], String[], Float64[], Float64[],
                                          Float64[], Float64[], Float64[])

@inline _record_diag!(::Nothing, args...) = nothing
@inline function _record_diag!(d::ShiftDiagCollector, t, z, comp, want, applied,
                               reallocated, beta_configured, beta_realised)
    push!(d.Time, t); push!(d.zone, z); push!(d.component, comp)
    push!(d.want, want); push!(d.applied, applied); push!(d.reallocated, reallocated)
    push!(d.beta_configured, beta_configured); push!(d.beta_realised, beta_realised)
    return nothing
end

"Collector contents as a `DataFrame` (see [`ShiftDiagCollector`](@ref) for the columns)."
shift_diag_df(d::ShiftDiagCollector) = DataFrame(
    Time = d.Time, zone = d.zone, component = d.component,
    want = d.want, applied = d.applied, reallocated = d.reallocated,
    beta_configured = d.beta_configured, beta_realised = d.beta_realised)

# ---------------------------------------------------------------------------
# The shift
# ---------------------------------------------------------------------------

"""
    shift_single(nd, params, t_tgt, t_ref, method; trace = nothing, diag = nothing)
        -> Dict(node => net_injection)

Build the target-day nodal net injection from reference day `t_ref` and target
day `t_tgt` under `method`. `t_ref` is either a single time step (global
reference day) or a per-node map `node => reference_time` (scoped / per-TSO
matching, where each group borrows its own reference day). The reference map is
also what the reference-day-texture redistribution keys are evaluated at, see
`_key_weights`.

`method.prestep` runs first, hard-setting RES and/or load to the target hour's nodal
value, and whatever it sets is **frozen** afterwards: that lever is skipped by the gap
cascade and by the balance pass, so the target day's nodal texture is what the result
carries. A frozen lever behaves like one with no headroom — it passes any remainder
handed to it straight on down `fallback_order`.

The gap is closed by physical levers only (RES/conv/load/storage); a zone's
unreachable remainder is left relaxed toward reference (traced `"np_relax"`).
With `method.enforce_balance = true` (opt-in, off by default) a final pass forces
the whole result to be globally balanced (`Σ_n net_injection = 0`) via
conventional generation (traced `"balance"`); see `_enforce_global_balance!`.

Pass a `ShiftTraceCollector` as `trace` to record every applied per-node
injection delta (components `"RES_prestep"`, `"load_prestep"`, `"RES"`, `"conv"`,
`"load"`, `"sto"`, `"balance"`, plus the per-zone `"np_relax"`), and a
[`ShiftDiagCollector`](@ref) as `diag` for the per-zone diagnostics: what each
pre-step hard-set, how much of each lever's share was really absorbed, and how much of
its key-proportional split was clipped away.
"""
shift_single(nd, params, t_tgt, t_ref::Integer, method::ShareShift;
             gsk = nothing, trace = nothing, diag = nothing) =
    shift_single(nd, params, t_tgt, Dict(n => Int(t_ref) for n in nd.nodes), method;
                 gsk = gsk, trace = trace, diag = diag)

function shift_single(nd, params, t_tgt, ref_of_node::AbstractDict, method::ShareShift;
                      gsk = nothing, trace = nothing, diag = nothing)
    nodes = nd.nodes
    p_new = Dict(n => get(nd.P, (n, ref_of_node[n]), 0.0) for n in nodes)
    lev   = ShiftLevers(nd, ref_of_node, method.load_shift_share)

    # ---- optional hard pre-steps: pin a component to its target-hour nodal value ----
    # Per node at BOTH resolutions: the point of a pre-step is that the basecase carries
    # the delivery day's forecast, so afterwards that component's intra-zone distribution
    # is the target day's, not the reference day's. Whatever is hard-set here is FROZEN
    # for the rest of the construction — see `frozen` below.
    pre      = prestep_components(method)
    frozen   = prestep_levers(method)
    presteps = Pair{String,Dict{String,Float64}}[]   # trace label => per-node delta
    if :res in pre
        δres = Dict{String,Float64}()
        for n in nodes
            tgt = get(nd.RES, (n, t_tgt), 0.0)
            δres[n] = tgt - lev.res[n]
            _record!(trace, t_tgt, n, "RES_prestep", δres[n])
            p_new[n] += δres[n]
            lev.res[n] = tgt
        end
        push!(presteps, "RES_prestep" => δres)
    end
    if :load in pre
        δload = Dict{String,Float64}()
        for n in nodes
            tgt = get(nd.LOAD, (n, t_tgt), 0.0)
            δload[n] = lev.load[n] - tgt   # export-positive: load down ⇒ injection up
            _record!(trace, t_tgt, n, "load_prestep", δload[n])
            p_new[n] += δload[n]
            lev.load[n] = tgt
        end
        push!(presteps, "load_prestep" => δload)
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

        # The pre-steps ran before the gap was measured, so they head this zone's diag
        # rows: `want == applied` (a hard-set is unconditional), no key and hence no
        # reallocation, no configured share, and `beta_realised` against the same |D| as
        # the levers below — it reads as the multiple of the remaining gap the pre-step
        # moved. The per-node detail is in REFDAY_SHIFT.
        for (label, δ) in presteps
            tot = sum(δ[n] for n in znodes; init = 0.0)
            absmoved = sum(abs(δ[n]) for n in znodes; init = 0.0)
            _record_diag!(diag, t_tgt, string(z), label, tot, tot, 0.0, 0.0,
                          abs(D) < 1e-12 ? 0.0 : absmoved / abs(D))
        end

        carried = 0.0
        for comp in order
            β = get(share, comp, 0.0)
            amount = β * D + carried
            if abs(amount) < 1e-12
                _record_diag!(diag, t_tgt, string(z), string(comp), amount, 0.0, 0.0, β, 0.0)
                carried = 0.0
                continue
            end
            if comp in frozen
                # Frozen by its pre-step: it behaves exactly like a lever with no
                # headroom — absorbs nothing, passes the whole amount on. `validate_shares`
                # rules out a configured β here, so `amount` is always a remainder carried
                # down `fallback_order`; recorded so the trace shows the lever was asked.
                _record_diag!(diag, t_tgt, string(z), string(comp), amount, 0.0, 0.0, β, 0.0)
                carried = amount
                continue
            end
            # keys MAY depend on the lever (RefPropRedist weights each one by the
            # reference day's own texture of that component), so the weights are
            # rebuilt per lever rather than once per zone
            w = _redist_weights(method.redist, nd, params, znodes, t_tgt, ref_of_node;
                                gsk = gsk, comp = comp)
            lo = Dict{String,Float64}(); hi = Dict{String,Float64}()
            for n in znodes
                lo[n], hi[n] = _comp_bounds(comp, n, t_tgt, nd, lev)
            end
            applied, rem, reallocated = _waterfill(amount, znodes, w, lo, hi)
            tot = 0.0; absmoved = 0.0
            for n in znodes
                _record!(trace, t_tgt, n, string(comp), applied[n])
                p_new[n] += applied[n]
                tot += applied[n]; absmoved += abs(applied[n])
                comp == :conv && (lev.conv[n] += applied[n])
                comp == :RES  && (lev.res[n]  += applied[n])
                comp == :sto  && (lev.sto[n]  += applied[n])
                comp == :load && (lev.load[n] -= applied[n])   # +injection ⇒ load down
            end
            _record_diag!(diag, t_tgt, string(z), string(comp), amount, tot, reallocated,
                          β, abs(D) < 1e-12 ? 0.0 : absmoved / abs(D))
            carried = rem
        end
        # gap the physical levers left open = this zone's NP relaxed toward reference
        # (the deliberately unshifted 1-β_RES-β_conv-β_load fraction plus any saturation remainder)
        _record!(trace, t_tgt, string(z), "np_relax", NP_tgt - sum(p_new[n] for n in znodes))
    end

    # global balance: force Σ_n p_new = 0 (production = consumption) via conventional gen
    method.enforce_balance &&
        _enforce_global_balance!(p_new, nd, t_tgt, lev, trace; frozen = frozen)
    return p_new
end

# ---------------------------------------------------------------------------
# Basecase assembly
# ---------------------------------------------------------------------------

"""
    _basecase_nodal_df(nodes, times, Prefmat, Pmat) -> DataFrame

The assembled basecase's nodal injection as a long table (`REFDAY_NETINPUT`): one row per
(`Time`, `index` = node) with

- `ACINJECTION_REF` — the unshifted seed, i.e. the source state's AC injection at that
  node's own matched reference hour;
- `ACINJECTION` — what the shift made of it, the exact value handed to `calc_fbmc_params`.

Both are **import-positive** (`load + charge − gen`), like every persisted
`NETINPUT`/`ACINJECTION` column and unlike the export-positive `REFDAY_SHIFT` deltas.
That flip is what puts the minus in the reconstruction identity

    ACINJECTION = ACINJECTION_REF − Σ deltas(n, t)

(the sum over the nodal components of `REFDAY_SHIFT`, `np_relax` excluded).
"""
function _basecase_nodal_df(nodes, times, Prefmat::AbstractMatrix, Pmat::AbstractMatrix)
    n_n, n_t = length(nodes), length(times)
    T   = Vector{Int}(undef, n_n * n_t)
    idx = Vector{String}(undef, n_n * n_t)
    ref = Vector{Float64}(undef, n_n * n_t)
    val = Vector{Float64}(undef, n_n * n_t)
    k = 0
    for (j, t) in enumerate(times), (i, n) in enumerate(nodes)
        k += 1
        T[k] = Int(t); idx[k] = String(n)
        ref[k] = Prefmat[i, j]; val[k] = Pmat[i, j]
    end
    return DataFrame(Time = T, index = idx, ACINJECTION_REF = ref, ACINJECTION = val)
end

"""
    _basecase_line_df(lines, times, LF) -> DataFrame

The assembled basecase's line flows as a long table (`REFDAY_LINEFLOW`): one row per
(`Time`, `index` = AC line) carrying `LINEFLOW = params.ptdf · ACINJECTION` over every AC
line, not just the CNEs. Import-positive like the injection it is derived from, so it is
the negative of the physical feed-in flow — the same convention as the persisted
`LINEFLOW` result tables, and the one `_basecase_f0` negates once when forming `F0`.
"""
function _basecase_line_df(lines, times, LF::AbstractMatrix)
    n_l, n_t = length(lines), length(times)
    T   = Vector{Int}(undef, n_l * n_t)
    idx = Vector{String}(undef, n_l * n_t)
    val = Vector{Float64}(undef, n_l * n_t)
    k = 0
    for (j, t) in enumerate(times), (i, l) in enumerate(lines)
        k += 1
        T[k] = Int(t); idx[k] = String(l); val[k] = LF[i, j]
    end
    return DataFrame(Time = T, index = idx, LINEFLOW = val)
end

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
`TwoDayAhead` optimization. With the shift's `enforce_balance = true` (opt-in),
each target column is additionally globally balanced (`Σ_n netinput_ac[n, tt] = 0`,
production = consumption), which is what keeps the PTDF flow computation
physically consistent; by default no such pass runs.

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
  how far each zone's net position was left relaxed toward the reference;
- `:REFDAY_DIAG`   — per-(Time, zone, component) diagnostics: one row per active
  pre-step, carrying the zone's summed hard-set, followed by one per lever of the
  gap cascade — how much each was asked for (`want`) and absorbed (`applied`), how
  much of its key-proportional split was clipped and re-spread (`reallocated`), and
  configured vs realised share of the gap (`beta_configured` / `beta_realised`). See
  `ShiftDiagCollector`;
- `:REFDAY_NETINPUT` — the assembled basecase itself, per (Time, node): the unshifted
  seed `ACINJECTION_REF` and the shifted `ACINJECTION`, both import-positive. See
  `_basecase_nodal_df`;
- `:REFDAY_LINEFLOW` — its `LINEFLOW` per (Time, AC line), the same numbers `calc_ram`
  turns into `F0`. See `_basecase_line_df`.

The last two are `:netinput_ac` / `:lineflows` in long form: the persisted basecase is
the one the flow-based parameters were built from, not a recomputation of it.

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
    diagnostics = collect_trace ? ShiftDiagCollector() : nothing

    nodes = nd.nodes
    nidx  = Dict(n => i for (i, n) in enumerate(nodes))
    Pmat  = zeros(length(nodes), length(build_times))
    # the unshifted seed, kept in the same import-positive convention as `Pmat` so the
    # persisted basecase can state its own starting point (`REFDAY_NETINPUT`)
    Prefmat = zeros(length(nodes), length(build_times))
    for (j, tt) in enumerate(build_times)
        ref_of_node = Dict(n => refmap[(n, tt)] for n in nodes)
        p_new = shift_single(nd, params, tt, ref_of_node, method;
                             gsk = gsk, trace = collector, diag = diagnostics)
        for n in nodes
            # shift_single works export-positive (feed-in); :netinput_ac must be
            # in the model's import-positive ACINJECTION convention (what
            # calc_ram / build_gsk_timeseries consume), so negate back here.
            Pmat[nidx[n], j] = -p_new[n]
            Prefmat[nidx[n], j] = -get(nd.P, (n, ref_of_node[n]), 0.0)
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
            :REFDAY_MATCH    => _refday_match_trace(groupmap, matches, fallback_matches),
            :REFDAY_GROUPS   => groups_df,
            :REFDAY_SHIFT    => shift_trace_df(collector),
            :REFDAY_DIAG     => shift_diag_df(diagnostics),
            :REFDAY_NETINPUT => _basecase_nodal_df(nodes, build_times, Prefmat, Pmat),
            :REFDAY_LINEFLOW => _basecase_line_df(lines, build_times, LF),
        )
    end
    return out
end

# ---------------------------------------------------------------------------
# Extra matching signals (load, net position)
#
# The reference-day distance can compare LOAD and NP alongside GEN
# (MatchingConfig.match_valuecols). They are stacked as extra rows on the match
# frame, discriminated by a sentinel :plant_type, with the non-applicable value
# columns zero-filled — so build_cluster_profiles / profile_distance / refday_weights
# handle them unchanged (a GEN row has LOAD = NP = 0 on both sides of the join, so
# it contributes nothing to the LOAD/NP distance, and vice-versa).
# ---------------------------------------------------------------------------

"Sentinel :plant_type / :index tags marking stacked LOAD and NP match rows."
const _LOAD_MATCH_TAG = "__LOAD__"
const _NP_MATCH_TAG   = "__NP__"

"Unified column schema every part of the stacked match frame carries."
const _MATCH_FRAME_COLS = [:index, :Time, :plant_type, :node, :zone, :GEN, :LOAD, :NP]

"Representative (min-id) node of zone `z`, used to keep zonal LOAD/NP rows in the right `match_by_scope` group."
_zone_repr_node(params::Parameters, z) = first(sort(collect(params.nodes_in_zone[z])))

"""
    _load_match_rows(params, times; nodal) -> DataFrame

Stacked LOAD rows (tagged `__LOAD__`) over `times`. `nodal = true` emits one row
per node (`LOAD = _nodal_load_at`); `nodal = false` aggregates load to the zone
(`node` set to the zone's representative node so scoped matching keeps it).
"""
function _load_match_rows(params::Parameters, times; nodal::Bool)
    idx  = String[]; T = Int[]; nd = String[]; zn = String[]; val = Float64[]
    if nodal
        for n in sort(collect(params.sets.N)), t in times
            push!(idx, _LOAD_MATCH_TAG); push!(T, t)
            push!(nd, n); push!(zn, params.node2zone[n])
            push!(val, _nodal_load_at(params, n, t))
        end
    else
        for z in sort(collect(params.sets.Z)), t in times
            push!(idx, _LOAD_MATCH_TAG); push!(T, t)
            push!(nd, _zone_repr_node(params, z)); push!(zn, z)
            push!(val, sum(_nodal_load_at(params, n, t) for n in params.nodes_in_zone[z]; init = 0.0))
        end
    end
    return DataFrame(index = idx, Time = T, plant_type = fill(_LOAD_MATCH_TAG, length(T)),
                     node = nd, zone = zn, GEN = zeros(length(T)), LOAD = val, NP = zeros(length(T)))
end

"""
    _np_match_rows(params, P, times) -> DataFrame

Stacked zonal net-position rows (tagged `__NP__`) over `times`.
`NP[z,t] = Σ_{n∈z} P[n,t]` from the source state's nodal injection baseline
`P` (`_ac_injection_baseline`, export-positive). `node` is the zone's representative node.
"""
function _np_match_rows(params::Parameters, P::AbstractDict, times)
    idx = String[]; T = Int[]; nd = String[]; zn = String[]; val = Float64[]
    for z in sort(collect(params.sets.Z)), t in times
        push!(idx, _NP_MATCH_TAG); push!(T, t)
        push!(nd, _zone_repr_node(params, z)); push!(zn, z)
        push!(val, sum(get(P, (n, t), 0.0) for n in params.nodes_in_zone[z]; init = 0.0))
    end
    return DataFrame(index = idx, Time = T, plant_type = fill(_NP_MATCH_TAG, length(T)),
                     node = nd, zone = zn, GEN = zeros(length(T)), LOAD = zeros(length(T)), NP = val)
end

"Normalize a match-frame part to `_MATCH_FRAME_COLS` (zero-filling any missing value column)."
function _normalize_match_part(df)
    df = copy(df)
    for c in (:GEN, :LOAD, :NP)
        c in propertynames(df) || (df[!, c] = zeros(nrow(df)))
    end
    return df[:, _MATCH_FRAME_COLS]
end

"""
    _assemble_match_frame(ref, state, cfg, gen_df) -> DataFrame

Build the combined reference-day match frame for `cfg.match_valuecols`: the RES
`gen_df` (when `:GEN` requested) plus stacked LOAD / NP rows, all sharing
`_MATCH_FRAME_COLS`, with `:Cluster` / `:Weekday` / `:IsWeekend` added once. LOAD
resolution is nodal iff `:node ∈ cfg.keycols`, else zonal.
"""
function _assemble_match_frame(ref::DataFiles, state::RefdaySourceState,
                               cfg::MatchingConfig, gen_df)
    params = ref.params
    times = sort(unique(Int.(_source_gen(state, ref).Time)))
    parts = DataFrame[]
    if :GEN in cfg.match_valuecols
        gd = add_zonecol(gen_df, params)
        push!(parts, _normalize_match_part(gd))
    end
    if :LOAD in cfg.match_valuecols
        push!(parts, _load_match_rows(params, times; nodal = :node in cfg.keycols))
    end
    if :NP in cfg.match_valuecols
        push!(parts, _np_match_rows(params, _ac_injection_baseline(state, ref), times))
    end
    frame = vcat(parts...)
    add_time_cluster!(frame, cfg.cluster_size)
    add_weekday!(frame, cfg.start_date)
    return frame
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
    isempty(ref.NETINPUT) && isempty(ref.LINEFLOW) && error(
        "ReferenceDayBasecase: day-ahead source has no nodal NETINPUT/LINEFLOW data. " *
        "Result sets written before nodal reporting was added to the zonal day-ahead " *
        "must be re-run with the current package.")
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

    # --- matching signals (from the same MarketState as the shift) ---
    isempty(cfg.match_valuecols) &&
        error("ReferenceDayBasecase: match_valuecols is empty; request at least one of :GEN, :LOAD, :NP.")
    bad = setdiff(cfg.match_valuecols, [:GEN, :LOAD, :NP])
    isempty(bad) ||
        error("ReferenceDayBasecase: unsupported match_valuecols $bad (allowed: :GEN, :LOAD, :NP).")

    gen_df = nothing
    if :GEN in cfg.match_valuecols
        gen_df = copy(_source_gen(state, ref))
        add_planttype!(gen_df, ref.params)
        filter_powerplants!(gen_df; type_in_planttype = cfg.res_tags)
        isempty(gen_df) && error("ReferenceDayBasecase: no plants match res_tags = $(cfg.res_tags).")
        add_nodecol!(gen_df, ref.params)
    end

    match_df = _assemble_match_frame(ref, state, cfg, gen_df)

    kw = (lookback = cfg.lookback, keycols = cfg.keycols, valuecols = cfg.match_valuecols,
          value_methods = cfg.value_methods, weights = cfg.weights,
          exact_weekend = cfg.exact_weekend)

    if cfg.scope isa GlobalMatchScope
        matches = match_by_cluster(match_df; kw...)
        fallback = nothing
    else
        matches = match_by_scope(match_df, cfg.scope, ref.params; kw...)
        fallback = match_by_cluster(match_df; kw...)   # global fallback for unmatched groups
    end

    return build_refday_basecase(ref, matches, bc.shift;
                                 res_tags = cfg.res_tags, scope = cfg.scope,
                                 fallback_matches = fallback,
                                 collect_trace = collect_trace,
                                 source_state = state)
end

# ---------------------------------------------------------------------------
# Reading a persisted reference-day basecase back
# ---------------------------------------------------------------------------

"""
    refday_basecase_artifacts(results) -> Dict{Symbol,Any}

The assembled reference-day basecase of a finished run, read back from its
`REFDAY_NETINPUT` / `REFDAY_LINEFLOW` tables into the same shape
[`build_refday_basecase`](@ref) returns:

- `:netinput_ac` — `DenseAxisArray` (node × time), the `ACINJECTION` column,
- `:lineflows`   — `DenseAxisArray` (AC line × time), the `LINEFLOW` column,
- `:times`       — the sorted timesteps both tables cover.

Both stay **import-positive**, exactly as persisted (see the NETINPUT/ACINJECTION note in
`CLAUDE.md`), so the dict can be handed straight to [`calc_fbmc_params`](@ref) or
[`refday_f0`](@ref) without a sign change anywhere in between.

Errors when either table is empty — that means the run had no
[`ReferenceDayBasecase`](@ref), or ran it with `collect_trace = false`.
"""
function refday_basecase_artifacts(results)
    ni = results.REFDAY_NETINPUT
    lf = results.REFDAY_LINEFLOW
    (ni isa DataFrame && !isempty(ni)) || error(
        "REFDAY_NETINPUT is empty — this run has no assembled reference-day basecase " *
        "(a ReferenceDayBasecase run with collect_trace enabled writes it).")
    (lf isa DataFrame && !isempty(lf)) || error(
        "REFDAY_LINEFLOW is empty — this run has no assembled reference-day basecase " *
        "(a ReferenceDayBasecase run with collect_trace enabled writes it).")

    times = sort!(unique(Int.(ni.Time)))
    sort!(unique(Int.(lf.Time))) == times || error(
        "REFDAY_NETINPUT and REFDAY_LINEFLOW cover different timesteps.")

    nodes = sort!(unique(String.(ni.index)))
    lines = sort!(unique(String.(lf.index)))
    tpos = Dict{Int,Int}(t => i for (i, t) in enumerate(times))
    npos = Dict{String,Int}(n => i for (i, n) in enumerate(nodes))
    lpos = Dict{String,Int}(l => i for (i, l) in enumerate(lines))

    P = zeros(Float64, length(nodes), length(times))
    _fill_refday_cells!(P, ni.index, ni.Time, ni.ACINJECTION, npos, tpos)
    F = zeros(Float64, length(lines), length(times))
    _fill_refday_cells!(F, lf.index, lf.Time, lf.LINEFLOW, lpos, tpos)

    return Dict{Symbol,Any}(
        :netinput_ac => Containers.DenseAxisArray(P, nodes, times),
        :lineflows => Containers.DenseAxisArray(F, lines, times),
        :times => times,
    )
end

"""
Fill loop of [`refday_basecase_artifacts`](@ref), taken as arguments so it specialises on
the concrete DataFrame column types rather than dispatching per row.
"""
function _fill_refday_cells!(M, idx, tt, vals, rowpos, tpos)
    @inbounds for k in eachindex(idx, tt, vals)
        v = vals[k]
        ismissing(v) && continue
        i = get(rowpos, String(idx[k]), 0)
        j = get(tpos, Int(tt[k]), 0)
        (i == 0 || j == 0) && continue
        M[i, j] = Float64(v)
    end
    return M
end

"""
    refday_f0(results, strategy = FlatGSK(); lines = nothing, normalize_empty = :flat)

Flow-based reference flow `F0[l,t]` of a persisted reference-day basecase, recomputed
under `strategy` — the GSK is what turns a basecase into a flow-based domain, so
different strategies give different intercepts from the same physical basecase.

Returns a `DenseAxisArray` indexed `(line, t)`. `lines` defaults to **every** AC line in
`REFDAY_LINEFLOW`, not only `params.cne`: the CNE list is a property of the run's own GSK,
and asking "what would F0 look like under a different one" is exactly the question that
makes it the wrong filter. Pass `lines` to restrict it.

`normalize_empty` defaults to `:flat`, matching [`calc_fbmc_params`](@ref) rather than
[`build_gsk`](@ref)'s own `:zero` default — so calling this with the run's own strategy
reproduces the run's persisted `RAM.F0` exactly, which is what
`test_refday_trace_e2e()` asserts.

A time-dependent strategy (`is_time_dependent(strategy) == true`, e.g. [`GenLoadGSK`](@ref))
builds one GSK per hour from this same basecase via [`build_gsk_timeseries`](@ref).

`F0` is the intercept of a linearization, not a physical flow: `|F0| > fmax` is
legitimate. Do not clamp it.

# Example
```julia
results = DataFiles(joinpath("results", "refday_gsk"))
F0 = refday_f0(results, DispOnlyGSK())
F0["l1", 3]
```
"""
function refday_f0(results, strategy::GSKStrategy = FlatGSK();
                   lines = nothing, normalize_empty::Symbol = :flat)
    artifacts = refday_basecase_artifacts(results)
    params = results.params
    T = artifacts[:times]
    flow_lines = lines === nothing ? collect(axes(artifacts[:lineflows], 1)) : collect(lines)

    PTDFn = dict_to_matrix(params.ptdf)
    GSK = is_time_dependent(strategy) ?
        build_gsk_timeseries(params, strategy, artifacts[:netinput_ac], T;
                             normalize_empty = normalize_empty) :
        build_gsk(params, strategy; normalize_empty = normalize_empty)
    PTDFz = zonal_ptdf(PTDFn, GSK)

    return _basecase_f0(params, artifacts, PTDFz, T; lines = flow_lines)
end
