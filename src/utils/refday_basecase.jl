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
# apportioned among components {RES, conv, load, NP} by user shares β (sum=1);
# each component's zonal amount is spread to nodes by a redistribution key,
# clipped to physical headroom; unabsorbed remainder cascades down
# `fallback_order`, with :NP (unbounded) closing the gap exactly.
#
# The nodal injection baseline is the AC-only ACINJECTION column of the
# NETINPUT result table (DC contributions excluded), matching what `calc_ram`
# consumes; legacy result sets reconstruct it from the LINEFLOW table.
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
- `β_RES, β_conv, β_load, β_NP`: apportionment shares of the gap (should sum to 1).
- `resolution`: `:zonal` (gap per zone, spread by `redist`) or `:nodal` (gap per
  node; the output nodal net injection then equals the target's nodal injection).
- `res_prestep`: if `true`, hard-set RES to the target first (nodal direct, or
  zonal-scaled preserving reference intra-zone shares), then apportion the rest.
- `redist`: nodal redistribution key for zonal corrections.
- `fallback_order`: cascade order for remainders when a component saturates;
  should end in `:NP` so the gap always closes.
"""
Base.@kwdef struct ShareShift <: ShiftMethod
    β_RES::Float64  = 0.0
    β_conv::Float64 = 0.5
    β_load::Float64 = 0.5
    β_NP::Float64   = 0.0
    resolution::Symbol = :zonal
    res_prestep::Bool  = false
    redist::RedistKey  = GSKRedist()
    fallback_order::Vector{Symbol} = [:conv, :load, :NP]
end

"Warn on inconsistent share configuration; error on invalid resolution."
function validate_shares(m::ShareShift)
    s = m.β_RES + m.β_conv + m.β_load + m.β_NP
    isapprox(s, 1.0; atol = 1e-6) || @warn "Shift shares sum to $s, expected 1.0"
    (:NP in m.fallback_order) || @warn "fallback_order lacks :NP; residual gap may not fully close"
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
    ReferenceDayBasecase(; source, source_type = "2DA", matching = MatchingConfig(), shift = ShareShift())

Reference-day (D2CF-style) basecase methodology for flow-based market runs:
instead of solving the `TwoDayAhead` optimization, the FBMC basecase is built
by matching every target day to a similar reference day of a previous
("forecast") model run and shifting its nodal injection pattern to the target
day's renewable infeed and zonal net positions.

# Keyword fields
- `source::Union{String,DataFiles}`: results directory of the forecast run, or
  a preloaded [`DataFiles`](@ref).
- `source_type::String = "2DA"`: which result set of the source to read
  (`"2DA"` = TwoDayAhead basecase tables, `""` = regular market result tables).
  The chosen set must contain nodal `NETINPUT`/`LINEFLOW`/`GEN` data.
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

function _classify_plant(p, params::Parameters, res_tags)
    p in params.sets.S && return :sto
    pt = get(params.plant_type, p, "")
    any(tag -> occursin(tag, pt), res_tags) && return :res
    return :conv
end

"""
    _ac_injection_baseline(results::DataFiles) -> Dict{(node,Time) => Float64}

AC-only nodal net injection per (node, time). Uses the persisted `ACINJECTION`
column when present; otherwise reconstructs it from the saved `LINEFLOW` table
via the incidence convention (line_start = -1, line_end = +1), which is DC-free
and matches the model's `ACINJECTION` expression.
"""
function _ac_injection_baseline(results::DataFiles)
    ni = results.NETINPUT
    if "ACINJECTION" in names(ni)
        return Dict((r.index, r.Time) => Float64(r.ACINJECTION) for r in eachrow(ni))
    end
    params = results.params
    P = Dict{Tuple{String,Int},Float64}()
    for r in eachrow(results.LINEFLOW)
        f = Float64(r.LINEFLOW)
        ns = params.line_start[r.index]; ne = params.line_end[r.index]
        P[(ns, r.Time)] = get(P, (ns, r.Time), 0.0) - f
        P[(ne, r.Time)] = get(P, (ne, r.Time), 0.0) + f
    end
    return P
end

"""
    precompute_nodal(results::DataFiles; res_tags) -> NamedTuple

Precompute the per-(node, time) lookups used by the shift: RES and conventional
generation, nodal load, AC net-injection baseline, per-node class capacities,
and zone maps. Storage dispatch stays inside the net-injection baseline (not a
shift lever).
"""
function precompute_nodal(results::DataFiles; res_tags = ["solar", "wind"])
    params = results.params
    nodes  = sort(collect(params.sets.N))
    times  = sort(unique(results.NETINPUT.Time))

    gen = copy(results.GEN)
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

    gmax_conv = Dict(n => 0.0 for n in nodes)
    gmax_res  = Dict(n => 0.0 for n in nodes)
    for (p, n) in params.plant2node
        haskey(gmax_conv, n) || continue
        cls = _classify_plant(p, params, res_tags)
        g = Float64(get(params.gmax, p, 0.0))
        cls == :conv && (gmax_conv[n] += g)
        cls == :res  && (gmax_res[n]  += g)
    end

    # AC-only nodal injection baseline (DC excluded); matches calc_ram's :netinput_ac
    P = _ac_injection_baseline(results)

    LOAD = Dict{Tuple{String,Int},Float64}()
    for n in nodes, t in times
        LOAD[(n, t)] = haskey(params.nodal_load, n) ? params.nodal_load[n][t] : 0.0
    end

    nodes_in_zone = Dict(z => sort(collect(v)) for (z, v) in params.nodes_in_zone)

    return (; nodes, times, RES, CONV, gmax_conv, gmax_res, P, LOAD, nodes_in_zone)
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
        # Time-dependent strategies (e.g. GenLoadGSK) have no basecase in the
        # redistribution context — fall back to per-timestep load weights
        # (equivalent to LoadPropRedist, but evaluated at each t).
        return Dict(n => get(nd.LOAD, (n, t), 0.0) for n in znodes)
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

"Per-node signed bounds (Δ injection) available from `comp` at a node."
function _comp_bounds(comp, n, nd, res_w, conv_w, load_w)
    if comp == :conv
        return (-conv_w[n], nd.gmax_conv[n] - conv_w[n])
    elseif comp == :load          # cut load → raise injection (≤ current load); add load unbounded
        return (-Inf, load_w[n])
    elseif comp == :RES
        return (-res_w[n], nd.gmax_res[n] - res_w[n])
    else                          # :NP unbounded (exchange/slack)
        return (-Inf, Inf)
    end
end

# ---------------------------------------------------------------------------
# The shift
# ---------------------------------------------------------------------------

"""
    shift_single(nd, params, t_tgt, t_ref, method) -> Dict(node => net_injection)

Build the target-day nodal net injection from reference day `t_ref` and target
day `t_tgt` under `method`. `t_ref` is either a single time step (global
reference day) or a per-node map `node => reference_time` (scoped / per-TSO
matching, where each group borrows its own reference day).
"""
shift_single(nd, params, t_tgt, t_ref::Integer, method::ShareShift; gsk = nothing) =
    shift_single(nd, params, t_tgt, Dict(n => Int(t_ref) for n in nd.nodes), method; gsk = gsk)

function shift_single(nd, params, t_tgt, ref_of_node::AbstractDict, method::ShareShift; gsk = nothing)
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
                    p_new[n] += d
                    res_w[n] += d
                end
            end
        end
    end

    # ---- net-position gap apportionment ----
    zones = method.resolution == :nodal ? [(n, [n]) for n in nodes] :
                                          collect(nd.nodes_in_zone)
    order = unique([:RES, method.fallback_order..., :NP])
    share = Dict(:RES => method.β_RES, :conv => method.β_conv,
                 :load => method.β_load, :NP => method.β_NP)

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
                lo[n], hi[n] = _comp_bounds(comp, n, nd, res_w, conv_w, load_w)
            end
            applied, rem = _waterfill(amount, znodes, w, lo, hi)
            for n in znodes
                p_new[n] += applied[n]
                comp == :conv && (conv_w[n] += applied[n])
                comp == :RES  && (res_w[n]  += applied[n])
                comp == :load && (load_w[n] -= applied[n])   # +injection ⇒ load down
            end
            carried = rem
        end
    end
    return p_new
end

# ---------------------------------------------------------------------------
# Basecase assembly
# ---------------------------------------------------------------------------

"""
    build_refday_basecase(results, matches, method; res_tags, scope, fallback_matches) -> Dict

Assemble a TwoDayAhead-style FBMC basecase from a target→reference time mapping
(`matches` with columns `target_time`, `matched_time` — and `group` when
produced by [`match_by_scope`](@ref)). Returns a Dict with the keys `calc_ram`
/ `calc_fbmc_params` consume:

- `:netinput_ac` => DenseAxisArray (node × target_time) nodal net injection
- `:lineflows`   => DenseAxisArray (line × target_time) = PTDFn · netinput

so the reference-day construction is a drop-in replacement for the
`TwoDayAhead` optimization.

# Scoped (per-TSO) matching
Pass `scope` (e.g. `ZonalMatchScope()`) together with a `matches` table from
[`match_by_scope`](@ref) to let every node group borrow its own reference day.
Groups without a match for an hour fall back to `fallback_matches` (a global
match table); hours unresolved in any group are skipped with a warning.
"""
function build_refday_basecase(results::DataFiles, matches, method::ShiftMethod;
                               res_tags = ["solar", "wind"],
                               scope::MatchScope = GlobalMatchScope(),
                               fallback_matches = nothing)
    validate_shares(method)
    params = results.params
    nd = precompute_nodal(results; res_tags = res_tags)

    tgt_times = sort(unique(matches.target_time))
    refmap, skipped = resolve_ref_times(matches, scope, params, tgt_times;
                                        fallback_matches = fallback_matches)
    build_times = [tt for tt in tgt_times if !(tt in Set(skipped))]
    isempty(build_times) && error("build_refday_basecase: no target hour is fully resolved — check matches/scope/fallback_matches.")

    # Precompute a static GSK for the redistribution key; time-dependent
    # strategies bypass it in _key_weights (per-timestep load weights instead).
    gsk = (method isa ShareShift && method.redist isa GSKRedist &&
           !is_time_dependent(method.redist.strategy)) ?
          build_gsk(params, method.redist.strategy; normalize_empty = :flat) : nothing

    nodes = nd.nodes
    nidx  = Dict(n => i for (i, n) in enumerate(nodes))
    Pmat  = zeros(length(nodes), length(build_times))
    for (j, tt) in enumerate(build_times)
        ref_of_node = Dict(n => refmap[(n, tt)] for n in nodes)
        p_new = shift_single(nd, params, tt, ref_of_node, method; gsk = gsk)
        for n in nodes
            Pmat[nidx[n], j] = p_new[n]
        end
    end

    netinput_ac = Containers.DenseAxisArray(Pmat, nodes, collect(build_times))

    PTDFn = dict_to_matrix(params.ptdf)                  # l×n DenseAxisArray
    ptdf_nodes = collect(axes(PTDFn, 2))
    lines = collect(axes(PTDFn, 1))
    Preordered = Pmat[[nidx[n] for n in ptdf_nodes], :]  # align rows to PTDF node order
    LF = PTDFn.data * Preordered
    lineflows = Containers.DenseAxisArray(LF, lines, collect(build_times))

    return Dict(:netinput_ac => netinput_ac, :lineflows => lineflows)
end

# ---------------------------------------------------------------------------
# Config-driven entry point (used by the solving pipeline)
# ---------------------------------------------------------------------------

_load_refday_source(bc::ReferenceDayBasecase) =
    bc.source isa DataFiles ? bc.source : DataFiles(bc.source; type = bc.source_type)

"""
    build_refday_basecase(bc::ReferenceDayBasecase, params::Parameters) -> Dict

Config-driven entry point: load the forecast run's results, run the (scoped)
reference-day matching per `bc.matching`, shift per `bc.shift`, and return the
whole-horizon basecase dict (`:netinput_ac`, `:lineflows`).

Validates that the source results are usable (non-empty parameters, identical
node set) before building.
"""
function build_refday_basecase(bc::ReferenceDayBasecase, params::Parameters)
    ref = _load_refday_source(bc)
    cfg = bc.matching

    # --- validation: fail loudly on unusable sources ---
    isempty(ref.params.sets.N) && error(
        "ReferenceDayBasecase: source results have empty Parameters (stale params.jld2 " *
        "from an older POMATWO version?). Re-run the forecast scenario with the current package.")
    Set(ref.params.sets.N) == Set(params.sets.N) || error(
        "ReferenceDayBasecase: node set of the source results does not match the current model.")
    isempty(ref.NETINPUT) && error(
        "ReferenceDayBasecase: source results contain no nodal NETINPUT data " *
        "(source_type = \"$(bc.source_type)\"). Choose a source/result set with nodal network data.")

    # --- renewable frame + matching ---
    gen_df = copy(ref.GEN)
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
                                 fallback_matches = fallback)
end
