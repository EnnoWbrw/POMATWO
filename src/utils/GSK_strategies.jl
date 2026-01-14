
# ==================== GSK Strategy Types ====================
# To add a new strategy:
# 1. Define a new struct subtype of GSKStrategy
# 2. Implement compute_nodal_weights for the new strategy
# 3. Add the new strategy to the export list in POMATWO.jl
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

struct DispOnlyGSK <: GSKStrategy
end

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
    
    # Establish deterministic node and zone ordering
    nodes = node_order === nothing ? sort!(collect(params.sets.N)) : collect(node_order)
    zones = zone_order === nothing ? sort!(collect(params.sets.Z)) : collect(zone_order)
    
    n = length(nodes)
    z = length(zones)
    
    # Build zone mapping
    zidx = Dict(zones[i] => i for i in 1:z)
    node_to_zone = Vector{Int}(undef, n)
    
    for (i, nlabel) in enumerate(nodes)
        zlabel = params.node2zone[nlabel]
        @assert haskey(zidx, zlabel) "Zone $(zlabel) of node $(nlabel) not found in zone_order"
        node_to_zone[i] = zidx[zlabel]
    end
    
    # Delegate to strategy-specific method
    G_matrix = build_gsk_matrix(strategy, params, nodes, zones, node_to_zone, normalize_empty)
    
    # Convert to DenseAxisArray
    G = Containers.DenseAxisArray(G_matrix, nodes, zones)
    
    return G
end

"""
    build_gsk_matrix(strategy::GSKStrategy, ...) -> Matrix{Float64}

Build GSK matrix from nodal weights. Normalizes weights per zone so columns sum to 1.
"""
function build_gsk_matrix(strategy::GSKStrategy, params, nodes, zones, node_to_zone, normalize_empty)
    n, z = length(nodes), length(zones)
    
    # Compute nodal weights using strategy
    weights = compute_nodal_weights(strategy, params, nodes)
    
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