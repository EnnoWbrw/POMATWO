
# ==================== GSK Strategy Types ====================
# To add a new strategy:
# 1. Define a new struct subtype of GSKStrategy
# 2. Implement compute_nodal_weights for the new strategy
# 3. Add the new strategy to the export list in POMATWO.jl
#
# A TIME-DEPENDENT strategy (one GSK per hour instead of one static matrix) needs
# two more methods:
# 4. is_time_dependent(::NewStrategy) = true
# 5. timedep_node_weight(::NewStrategy, params, node; gen, load) — the per-node,
#    per-hour weight, used by build_gsk_timeseries and by the GSKRedist
#    redistribution key alike.
# compute_nodal_weights stays required either way: it is what a plain build_gsk
# call (no basecase, no timestep) falls back to.
# =============================================================

"""
    GSKStrategy

Abstract type for Generation Shift Key computation strategies.
Each concrete strategy defines how to distribute zonal power injections across nodes.
"""
abstract type GSKStrategy end

"""
    FlatGSK <: GSKStrategy

Equal distribution: each node in a zone gets an equal share (1/n_nodes_in_zone).
"""
struct FlatGSK <: GSKStrategy end

"""
    GmaxGSK <: GSKStrategy

Capacity-weighted distribution: nodes receive shares proportional to their total 
generation capacity (sum of g_max over all plants at that node).
"""
struct GmaxGSK <: GSKStrategy end

"""
    CustomWeightsGSK <: GSKStrategy

User-provided nodal weights. The weights vector must have length n (number of nodes).
Weights are normalized per zone to sum to 1.

# Fields
- `weights::Vector{Float64}`: Nodal weights, same order as node_order
"""
struct CustomWeightsGSK <: GSKStrategy
    weights::Vector{Float64}
end

"""
    DispOnlyGSK <: GSKStrategy

Dispatchable-only capacity weighting: nodes receive shares proportional to the total
generation capacity of their *dispatchable* plants (sum of `g_max` over plants in
`params.sets.DISP`). Non-dispatchable units (e.g. wind, solar) do not contribute to the
node weight. Zones whose only plants are non-dispatchable fall back to the empty-zone rule
of [`build_gsk`](@ref). This mirrors the common flow-based assumption that a change in a
zone's net position is served by its dispatchable fleet.
"""
struct DispOnlyGSK <: GSKStrategy
end

"""
    GenLoadGSK <: GSKStrategy

Combined generation- and load-shift key (GLSK), following the refined "Country
GLSK" formula used in CWE flow-based capacity calculation:

```math
GLSK_i(t) = \\frac{|p_i^{GEN}(t)| + |p_i^{LOAD}(t)|}
                  {\\sum_{k \\in \\text{TSO area}} \\left(|p_k^{GEN}(t)| + |p_k^{LOAD}(t)|\\right)}
```

This strategy is *time-dependent* (`is_time_dependent(::GenLoadGSK) == true`):
one GSK matrix is built per timestep from the FBMC basecase (the model's IGM
equivalent) via [`build_gsk_timeseries`](@ref), with

- ``p_i^{LOAD}(t)`` = the node's `nodal_load` profile at `t` (0 if no load),
- ``p_i^{GEN}(t)``  = `p_i^{LOAD}(t) - netinput_ac[i, t]`, i.e. active generation
  recovered from the basecase nodal net injection (`netinput_ac` is
  import-positive: netinput = load + charge − gen).

Weights are normalized per zone (the TSO control area) and per timestep, so each
zone column sums to 1 for every `t`. Combining generation and load lets the key
reflect renewable infeed better than a pure capacity key.

As a [`GSKRedist`](@ref) redistribution key the same `|gen| + |load|` weight is
built per timestep from the forecast run's nodal data (net-injection baseline +
load). Only a plain [`build_gsk`](@ref) call — no basecase, no timestep — falls
back to *load-only* weights (mean of the load profile); capacity-based proxies
like ``g\\_max \\cdot \\overline{avail}`` are deliberately avoided, as they would
treat conventional plants as always running at full capacity.
"""
struct GenLoadGSK <: GSKStrategy end

"""
    is_time_dependent(strategy::GSKStrategy) -> Bool

Whether the strategy builds one GSK per timestep from the FBMC basecase
([`build_gsk_timeseries`](@ref)) instead of a single static matrix
([`build_gsk`](@ref)). Defaults to `false`; setting it `true` obliges the strategy to
define a [`timedep_node_weight`](@ref) method.
"""
is_time_dependent(::GSKStrategy) = false
is_time_dependent(::GenLoadGSK) = true

"""
    timedep_node_weight(strategy::GSKStrategy, params, node; gen, load) -> Float64

Per-node weight of a *time-dependent* strategy at one hour, before the per-zone
normalization — only the ratios within a zone matter.

`gen` and `load` are the node's active generation and load at the hour the CALLER
evaluates, already converted to the caller's sign convention. The two call sites differ
in both:

- [`build_gsk_timeseries`](@ref) reads the FBMC basecase at the TARGET hour `t`, where
  `netinput_ac` is import-positive, so `gen = load - netinput_ac[node, t]`;
- the [`GSKRedist`](@ref) redistribution key reads the forecast run's nodal data at the
  node's REFERENCE hour, where the injection baseline `nd.P` is export-positive, so
  `gen = P + load`.

A method must therefore derive its weight from the passed `gen`/`load` plus STATIC node
attributes obtained from `params` (installed capacities, plant sets, zone membership).
Neither call site passes a timestep, so a time-indexed `params` lookup would silently
evaluate the wrong hour in at least one of them.

No default weight exists: a strategy with `is_time_dependent(strategy) == true` must
define a method, otherwise both call sites error.
"""
timedep_node_weight(strategy::GSKStrategy, params, node; gen, load) = error(
    "$(typeof(strategy)) is time-dependent but defines no timedep_node_weight method " *
    "(required by build_gsk_timeseries and the GSKRedist redistribution key).")

timedep_node_weight(::GenLoadGSK, params, node; gen, load) = abs(gen) + abs(load)

# ==================== Weight Computation Dispatch ====================

"""
    compute_nodal_weights(strategy::GSKStrategy, params, nodes) -> Vector{Float64}

Compute nodal weights according to the given strategy.
Returns a vector of length n with non-negative weights.
"""
function compute_nodal_weights(strategy::FlatGSK, params, nodes)
    return ones(Float64, length(nodes))
end

function compute_nodal_weights(strategy::GmaxGSK, params, nodes)
    n = length(nodes)
    weights = zeros(Float64, n)
    
    # Aggregate g_max per node
    nodemap = Dict(nlabel => 0.0 for nlabel in nodes)
    for (p, node_lbl) in params.plant2node
        if haskey(nodemap, node_lbl) && haskey(params.gmax, p)
            nodemap[node_lbl] += params.gmax[p]
        end
    end
    
    for (i, nlabel) in enumerate(nodes)
        weights[i] = nodemap[nlabel]
    end
    
    return weights
end


function compute_nodal_weights(strategy::DispOnlyGSK, params, nodes)
    n = length(nodes)
    weights = zeros(Float64, n)
    
    # Aggregate g_max per node
    nodemap = Dict(nlabel => 0.0 for nlabel in nodes)
    for (p, node_lbl) in params.plant2node
        if haskey(nodemap, node_lbl) && haskey(params.gmax, p) && (p in params.sets.DISP)
            nodemap[node_lbl] += params.gmax[p]
        end
    end
    
    for (i, nlabel) in enumerate(nodes)
        weights[i] = nodemap[nlabel]
    end
    
    return weights
end


# Mean of a ConcreteProfile (representative value for the static GSK). Duck-typed
# on `.val` because the profile types are defined in a later-included file.
function _profile_avg(p)
    v = p.val
    v isa AbstractVector || return v
    return isempty(v) ? 0.0 : sum(v) / length(v)
end

# Static fallback (no basecase available): load-only weights, mean of the nodal
# load profile. Capacity-based generation terms are deliberately excluded —
# gmax·mean(avail) would treat conventionals (avail ≡ 1) as running at full
# capacity all the time. Only reachable through a plain `build_gsk` call: the
# FBMC pipeline uses `build_gsk_timeseries` and GSKRedist builds per-timestep
# GLSK weights itself, so warn that the result is not the real GLSK.
function compute_nodal_weights(strategy::GenLoadGSK, params, nodes)
    @warn "GenLoadGSK used in a static build_gsk call without a basecase: falling back " *
          "to load-only weights (mean of nodal_load per node). For the per-timestep " *
          "GLSK use build_gsk_timeseries or the FBMC pipeline (calc_fbmc_params)." maxlog = 1
    n = length(nodes)

    weights = zeros(Float64, n)
    for (i, nlabel) in enumerate(nodes)
        load = haskey(params.nodal_load, nlabel) ?
               _profile_avg(params.nodal_load[nlabel]) : 0.0
        weights[i] = abs(load)
    end

    return weights
end

function compute_nodal_weights(strategy::CustomWeightsGSK, params, nodes)
    n = length(nodes)
    @assert length(strategy.weights) == n "Custom weights must have length n=$n, got $(length(strategy.weights))"
    return Float64.(strategy.weights)
end

# ==================== GSK Matrix Construction ====================

"""
    build_gsk(params, strategy::GSKStrategy=FlatGSK(); 
              node_order=nothing, zone_order=nothing, normalize_empty=:zero)

Construct a Generation Shift Key matrix G (n×z) that maps zonal net injections to nodal injections.

# Arguments
- `params`: Parameters object containing network topology and plant data
- `strategy::GSKStrategy`: Strategy for computing GSK (default: `FlatGSK()`)
  * `FlatGSK()` → equal split within each zone
  * `GmaxGSK()` → proportional to generation capacity per node
  * `CustomWeightsGSK(weights)` → user-provided nodal weights

# Keyword Arguments
- `node_order`: Vector controlling node row order (default: sorted nodes)
- `zone_order`: Vector controlling zone column order (default: sorted zones)
- `normalize_empty`: How to handle zones with zero total weight
  * `:zero` → column of zeros
  * `:flat` → uniform distribution across zone members

# Returns
- `G::DenseAxisArray{Float64,2}`: GSK matrix (n×z) indexed by nodes and zones, where column sums are 1 (or 0 for empty zones)

# Examples
```julia
# Equal distribution
G = build_gsk(params, FlatGSK())

# Capacity-weighted
G = build_gsk(params, GmaxGSK())

# Custom weights
custom_w = [0.5, 0.3, 0.2]
G = build_gsk(params, CustomWeightsGSK(custom_w))

# Access by label
G["node1", "zone1"]
```
"""
function build_gsk(params, strategy::GSKStrategy=FlatGSK();
                   node_order::Union{Nothing,AbstractVector}=nothing,
                   zone_order::Union{Nothing,AbstractVector}=nothing,
                   normalize_empty::Symbol=:zero)

    nodes, zones, node_to_zone = _gsk_orderings(params, node_order, zone_order)

    # Delegate to strategy-specific method
    G_matrix = build_gsk_matrix(strategy, params, nodes, zones, node_to_zone, normalize_empty)

    # Convert to DenseAxisArray
    G = Containers.DenseAxisArray(G_matrix, nodes, zones)

    return G
end

# Deterministic node/zone ordering plus node→zone column index, shared by
# `build_gsk` and `build_gsk_timeseries`.
function _gsk_orderings(params, node_order, zone_order)
    nodes = node_order === nothing ? sort!(collect(params.sets.N)) : collect(node_order)
    zones = zone_order === nothing ? sort!(collect(params.sets.Z)) : collect(zone_order)

    zidx = Dict(zones[i] => i for i in eachindex(zones))
    node_to_zone = Vector{Int}(undef, length(nodes))

    for (i, nlabel) in enumerate(nodes)
        zlabel = params.node2zone[nlabel]
        @assert haskey(zidx, zlabel) "Zone $(zlabel) of node $(nlabel) not found in zone_order"
        node_to_zone[i] = zidx[zlabel]
    end

    return nodes, zones, node_to_zone
end

"""
    build_gsk_matrix(strategy::GSKStrategy, ...) -> Matrix{Float64}

Build GSK matrix from nodal weights. Normalizes weights per zone so columns sum to 1.
"""
function build_gsk_matrix(strategy::GSKStrategy, params, nodes, zones, node_to_zone, normalize_empty)
    # Compute nodal weights using strategy
    weights = compute_nodal_weights(strategy, params, nodes)
    return _normalize_per_zone(weights, node_to_zone, length(zones), normalize_empty)
end

# Normalize nodal weights per zone so each zone column sums to 1 (or is handled
# by the empty-zone rule). Shared by the static and per-timestep GSK builders.
function _normalize_per_zone(weights::Vector{Float64}, node_to_zone::Vector{Int}, z::Int, normalize_empty::Symbol)
    n = length(weights)

    # Aggregate weights per zone
    zone_sums = zeros(Float64, z)
    zone_counts = zeros(Int, z)

    @inbounds for i in 1:n
        j = node_to_zone[i]
        zone_sums[j] += weights[i]
        zone_counts[j] += 1
    end

    # Build normalized GSK matrix
    G = zeros(Float64, n, z)

    @inbounds for i in 1:n
        j = node_to_zone[i]

        if zone_sums[j] > 0
            # Standard case: normalize by zone sum
            G[i, j] = weights[i] / zone_sums[j]
        else
            # Empty zone handling
            if normalize_empty === :flat
                G[i, j] = zone_counts[j] == 0 ? 0.0 : 1.0 / zone_counts[j]
            elseif normalize_empty === :zero
                G[i, j] = 0.0
            else
                error("normalize_empty must be :zero or :flat, got :$normalize_empty")
            end
        end
    end

    return G
end

"""
    build_gsk_timeseries(params, strategy::GSKStrategy, netinput_ac, T;
                         node_order=nothing, zone_order=nothing, normalize_empty=:zero)

Build one GSK matrix per timestep from the FBMC basecase, returned as a
`DenseAxisArray` of size n×z×|T| indexed by (node, zone, t). `strategy` must be
time-dependent (`is_time_dependent`); a static strategy has no per-timestep meaning and
is rejected instead of silently returning |T| identical matrices — use
[`build_gsk`](@ref) for those.

Per node `i` and timestep `t` the weight is
[`timedep_node_weight`](@ref)`(strategy, params, i; gen, load)` with
`load = nodal_load[i][t]` (0 if the node has no load profile) and
`gen = load - netinput_ac[i, t]` (active generation recovered from the basecase
nodal net injection; `netinput_ac` is **import-positive**, i.e.
`netinput = load + charge - gen`, so storage charge is absorbed into `gen`).
[`GenLoadGSK`](@ref) — the only time-dependent strategy shipped — turns that into
`|gen| + |load|`, which is where the absorbed charge becomes harmless. Weights are
normalized per zone and timestep, so every zone column sums to 1 for each `t` (empty
zones follow `normalize_empty`, see [`build_gsk`](@ref)).

# Arguments
- `netinput_ac`: DenseAxisArray (node × time) of AC nodal net injections from the
  basecase (`TwoDayAhead` optimization or [`build_refday_basecase`](@ref)).
- `T`: timesteps to build GSKs for (must be covered by `netinput_ac`).
"""
function build_gsk_timeseries(params, strategy::GSKStrategy, netinput_ac, T;
                              node_order::Union{Nothing,AbstractVector}=nothing,
                              zone_order::Union{Nothing,AbstractVector}=nothing,
                              normalize_empty::Symbol=:zero)
    is_time_dependent(strategy) || error(
        "build_gsk_timeseries: $(typeof(strategy)) is not time-dependent, a per-timestep " *
        "GSK has no meaning for it. Use build_gsk(params, strategy) instead.")
    nodes, zones, node_to_zone = _gsk_orderings(params, node_order, zone_order)
    n, z = length(nodes), length(zones)
    times = collect(T)

    G_data = Array{Float64,3}(undef, n, z, length(times))
    weights = Vector{Float64}(undef, n)

    for (k, t) in enumerate(times)
        for (i, nlabel) in enumerate(nodes)
            load = haskey(params.nodal_load, nlabel) ? params.nodal_load[nlabel][t] : 0.0
            # netinput_ac follows the model's ACINJECTION convention (import-
            # positive: netinput = load + charge - gen, see the nodal balance in
            # energy_balances.jl and the NP negation in calc_ram), so generation
            # is recovered as load - netinput (storage charge is absorbed into
            # gen). GSKRedist passes the same pair from an export-positive
            # baseline — the strategy only ever sees gen/load, never the sign
            # convention they came from.
            gen = load - netinput_ac[nlabel, t]
            weights[i] = timedep_node_weight(strategy, params, nlabel; gen = gen, load = load)
        end
        G_data[:, :, k] = _normalize_per_zone(weights, node_to_zone, z, normalize_empty)
    end

    return Containers.DenseAxisArray(G_data, nodes, zones, times)
end