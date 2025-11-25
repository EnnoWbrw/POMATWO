"""
    isinvertible(A::Matrix{Float64}) -> Bool

Check if matrix A is invertible by computing its determinant with high precision.
Uses BigFloat arithmetic to avoid numerical errors, with tolerance 1e-18.
"""
isinvertible(A::Matrix{Float64}) = !isapprox(det(BigFloat.(A)), 0, atol = 1e-18)

"""
    diagnose_singular_matrix(b_red::Matrix{Float64}, included_nodes::Vector{String})

Diagnostic function to identify why a matrix is singular.
Checks for network islands, zero rows/columns, and rank deficiency.
"""
function diagnose_singular_matrix(b_red::Matrix{Float64}, included_nodes::Vector{String})
    n = size(b_red, 1)
    
    println("\n" * "="^60)
    println("SINGULAR MATRIX DIAGNOSTICS")
    println("="^60)
    
    # Check determinant
    det_val = det(BigFloat.(b_red))
    println("Determinant: ", det_val)
    
    # Check rank
    r = rank(b_red)
    println("Rank: $r / $n (deficit: $(n - r))")
    
    # Check for zero or near-zero rows/columns
    row_norms = [norm(b_red[i, :]) for i in 1:n]
    col_norms = [norm(b_red[:, j]) for j in 1:n]
    
    zero_rows = findall(x -> x < 1e-10, row_norms)
    zero_cols = findall(x -> x < 1e-10, col_norms)
    
    if !isempty(zero_rows)
        println("\nNodes with near-zero rows (likely isolated or faulty line data):")
        for i in zero_rows
            println("  - $(included_nodes[i]) (row $i, norm: $(row_norms[i]))")
        end
    end
    
    if !isempty(zero_cols)
        println("\nNodes with near-zero columns (likely isolated or faulty line data):")
        for j in zero_cols
            println("  - $(included_nodes[j]) (col $j, norm: $(col_norms[j]))")
        end
    end
    
    # Check condition number
    cond_num = cond(b_red)
    println("\nCondition number: $cond_num")
    if cond_num > 1e12
        println("  ⚠️  Matrix is severely ill-conditioned!")
    end
    
    # Check for disconnected components (simplified check)
    # A connected network should have rank = n-1 for the Laplacian-like matrix
    println("\nExpected rank for connected network: $(n-1)")
    println("Actual rank: $r")
    if r < n - 1
        println("  ⚠️  Network likely has $(n - r) disconnected islands!")
    end
    
    # Show diagonal values
    diag_vals = diag(b_red)
    println("\nDiagonal value statistics:")
    println("  Min: $(minimum(diag_vals))")
    println("  Max: $(maximum(diag_vals))")
    println("  Mean: $(sum(diag_vals) / n)")
    
    near_zero_diag = findall(x -> abs(x) < 1e-6, diag_vals)
    if !isempty(near_zero_diag)
        println("\nNodes with near-zero diagonal (suspicious):")
        for i in near_zero_diag
            println("  - $(included_nodes[i]): $(diag_vals[i])")
        end
    end
    
    println("="^60 * "\n")
end

function calc_h_b!(params, report::Union{DataReport,Nothing}=nothing)
    @unpack N, L, DC = params.sets
    @unpack line_start, line_end, dc_start, dc_end, reactance, resistance, slack = params

    incidence = Containers.DenseAxisArray(zeros(Int, length(L), length(N)), L, N)
    dcincidence = Containers.DenseAxisArray(zeros(Int, length(DC), length(N)), DC, N)
    bvector = Containers.DenseAxisArray(zeros(Float64, length(L)), L)

    for l in L
        incidence[l, line_start[l]] = -1
        incidence[l, line_end[l]] = 1
        if haskey(params.bvector, l)
            bvector[l] = params.bvector[l]
        else
            bvector[l] = reactance[l] / ((reactance[l]^2) + (resistance[l]^2))
            params.bvector[l] = reactance[l] / ((reactance[l]^2) + (resistance[l]^2))
        end
    end

    for dc in DC
        dcincidence[dc, dc_start[dc]] = -1
        dcincidence[dc, dc_end[dc]] = 1
    end

    h = bvector.data .* incidence.data
    b = h' * incidence.data

    if !issymmetric(b)
        @warn "B-matrix is not symmetric. This indicates a numerical or algorithmic issue."
        if !isnothing(report)
            add_error!(report, "matrix_calculation", 
                        "B-matrix is not symmetric - indicates numerical or algorithmic issue", 
                        "PTDF calculation")
        end
    end

    calc_PTDF!(h, b, slack, N, L, params, report)

    for l in eachindex(L), n in eachindex(N)
        params.h[(L[l], N[n])] = h[l, n]
    end

    for n in eachindex(N), m in eachindex(N)
        params.b[(N[n], N[m])] = b[n, m]
    end

end
function calc_PTDF!(h::Matrix{Float64}, b::Matrix{Float64}, slack_list::Vector{String}, N::Vector{String}, L::Vector{String}, params::Parameters, report::Union{DataReport,Nothing}=nothing)

    # Get nodes that should be omitted from PTDF calculation
    # (isolated nodes and DC-only nodes)
    nodes_to_omit = get_nodes_to_omit_for_ptdf(params)
    
    # Find indices of nodes to omit
    omit_idx = findall(n -> n in nodes_to_omit, N)
    
    # Find indices of slack buses in N
    slack_idx = findall(n -> n in slack_list, N)

    if isempty(slack_idx)
        error("No slack buses found in params.slack")
    end

    if length(slack_list) > 1
        @warn "Multiple slack buses found."
    end
    
    # Report omitted nodes
    if !isempty(nodes_to_omit)
        @info """
        Omitting $(length(nodes_to_omit)) node(s) from PTDF calculation:
        $(join(sort(nodes_to_omit), ", "))
        Reason: Nodes are either isolated or connected only via DC lines.
        """
    end

    # Indices to exclude: slack buses + nodes to omit
    excluded_idx = union(slack_idx, omit_idx)
    
    # Indices of nodes included in B-matrix inversion
    included_idx = setdiff(1:length(N), excluded_idx)
    
    if isempty(included_idx)
        @warn """
        No nodes available for PTDF calculation after excluding slack and omitted nodes.
        PTDF matrix will be zeros.
        """
        # Create zero PTDF matrix
        ptdf = zeros(length(L), length(N))
    else
        # Create reduced B-matrix (excluding slack and omitted nodes)
        b_red = b[included_idx, included_idx]

        if !isinvertible(b_red)
            # Matrix is singular - try to provide helpful diagnostic
            @warn """
            B-matrix is singular (determinant is zero).
            This typically indicates:
            - Isolated network sections (islands)
            - Missing or zero line reactances
            - Duplicate or contradictory line definitions
            
            Network topology issues:
            - Total nodes: $(length(N))
            - Slack nodes: $(length(slack_idx)) at $(slack_list)
            - Omitted nodes: $(length(omit_idx))
            - Nodes in calculation: $(length(included_idx))
            - Lines: $(length(L))
            
            Attempting pseudoinverse for PTDF calculation (may produce inaccurate results).
            """
            
            # Run detailed diagnostics
            included_nodes = N[included_idx]
            diagnose_singular_matrix(b_red, included_nodes)
            
            # Add warning to report
            if !isnothing(report)
                add_warning!(report, "ptdf_calculation", 
                            "B-matrix is singular - using pseudoinverse (may produce inaccurate PTDF values). See console output for detailed diagnostics.", 
                            "PTDF calculation")
            end
            
            # Use pseudoinverse as fallback
            b_red_inv = pinv(b_red)
        else
            # Try regular inversion, catch singularity errors
            try
                b_red_inv = inv(b_red)
            catch e
                if e isa LinearAlgebra.SingularException
                    @warn """
                    Matrix inversion failed despite full rank.
                    This may indicate numerical conditioning issues.
                    Using pseudoinverse as fallback.
                    """
                    
                    # Add warning to report
                    if !isnothing(report)
                        add_warning!(report, "ptdf_calculation", 
                                    "Matrix inversion failed despite determinant check - using pseudoinverse due to numerical conditioning issues", 
                                    "PTDF calculation")
                    end
                    
                    b_red_inv = pinv(b_red)
                else
                    rethrow(e)
                end
            end
        end

        # Create full inverse matrix with embedded B⁻¹
        # Excluded nodes (slack + omitted) remain zero
        b_inv_full = zeros(length(N), length(N))
        b_inv_full[included_idx, included_idx] .= b_red_inv

        # PTDF = H * B⁻¹
        ptdf = h * b_inv_full
    end

    # Store PTDF values
    for l in eachindex(L), n in eachindex(N)
        params.ptdf[(L[l], N[n])] = ptdf[l, n]
    end
end

"""
    build_gsk(params; node_order=nothing, zone_order=nothing, weights=:flat, normalize_empty=:zero)

Construct a Generation Shift Key matrix G (n×z) that maps zonal net injections to nodal injections.

- `params` must contain `sets.N` (nodes), `sets.Z` (zones) and `node2zone` mappings.
- `node_order` (Vector) controls the node order used for columns of PTDF(l×n). 
   If `nothing`, a stable default is used (sorted nodes).
- `zone_order` (Vector) controls the zone columns order of G; default = sorted zones.
- `weights`:
    * `:flat` → equal split within each zone
    * `:gmax` → proportional to available capacity per node (sum of `g_max` of plants at that node)
      (uses `params.plant2node` and `params.gmax`)
    * or a numeric vector of length n (precomputed nodal weights)
- `normalize_empty` for zones with zero total weight:
    * `:zero` → column of zeros
    * `:flat` → uniform across members of that zone

Returns `(G::Matrix{Float64}, node_order::Vector, zone_order::Vector)`.
Column sums of G are 1 (except empty zones when `:zero`).
"""
function build_gsk(params;
                   node_order::Union{Nothing,AbstractVector}=nothing,
                   zone_order::Union{Nothing,AbstractVector}=nothing,
                   weights::Union{Symbol,AbstractVector}=:flat,
                   normalize_empty::Symbol=:zero)

    # --- choose a deterministic order that matches calc_PTDF ---
    nodes = node_order === nothing ? sort!(collect(params.sets.N)) : collect(node_order)
    zones = zone_order === nothing ? sort!(collect(params.sets.Z)) : collect(zone_order)

    n = length(nodes)
    z = length(zones)

    # map zone label -> 1..z
    zidx = Dict(zones[i] => i for i in 1:z)

    # node_to_zone index vector aligned with `nodes`
    node_to_zone = Vector{Int}(undef, n)
    for (i, nlabel) in enumerate(nodes)
        zlabel = params.node2zone[nlabel]  # zone label from data loading
        @assert haskey(zidx, zlabel) "Zone $(zlabel) of node $(nlabel) not found in zone_order"
        node_to_zone[i] = zidx[zlabel]
    end

    # --- build nodal weights ---
    w = zeros(Float64, n)

    if weights === :flat
        w .= 1.0
    elseif weights === :gmax
        # sum of g_max per node via plant mapping
        # (params.plant2node :: Dict{plant => node}, params.gmax :: Dict{plant => Float64})
        nodemap = Dict(nlabel => 0.0 for nlabel in nodes)
        for (p, node_lbl) in params.plant2node
            if haskey(nodemap, node_lbl) && haskey(params.gmax, p)
                nodemap[node_lbl] += params.gmax[p]
            end
        end
        for (i, nlabel) in enumerate(nodes)
            w[i] = nodemap[nlabel]
        end
    elseif weights isa AbstractVector
        @assert length(weights) == n "custom weights must have length n"
        w .= Float64.(weights)
    else
        error("`weights` must be :flat, :gmax, or a numeric vector")
    end

    # --- aggregate per zone and normalize ---
    sums   = zeros(Float64, z)
    counts = zeros(Int, z)
    @inbounds for i in 1:n
        j = node_to_zone[i]
        sums[j]   += w[i]
        counts[j] += 1
    end

    G = zeros(Float64, n, z)
    @inbounds for i in 1:n
        j = node_to_zone[i]
        if sums[j] > 0
            G[i, j] = w[i] / sums[j]
        else
            if normalize_empty === :flat
                G[i, j] = counts[j] == 0 ? 0.0 : 1.0 / counts[j]
            elseif normalize_empty === :zero
                G[i, j] = 0.0
            else
                error("normalize_empty must be :zero or :flat")
            end
        end
    end

    return G, nodes, zones
end


"""
    zonal_ptdf(PTDF, GSK) -> Matrix

Compute zonal PTDF (l×z) as PTDF(l×n) * GSK(n×z).

Assumes that the columns of PTDF correspond to `nodes` in the same order
used to build GSK.
"""
function zonal_ptdf(PTDF::AbstractMatrix, GSK::AbstractMatrix)
    @assert size(PTDF, 2) == size(GSK, 1) "PTDF is l×n, GSK must be n×z"
    PTDF * GSK
end

"""
    zone_to_zone_ptdf(PTDFz; zones=nothing, exclude_self=true)

Build the zone→zone PTDF for all ordered pairs (z_export, z_import).

- `PTDFz` is l×z (from `zonal_ptdf`).
- If `zones` is provided (vector of zone labels in the same order as PTDFz columns),
  a tuple vector `pairs` of labels is returned alongside the matrix.
- Returns `(PTDFzz, pairs)` where:
   * `PTDFzz` is l×m with m = z*(z-1) if `exclude_self` (default), else z*z
   * `pairs[k]` = (z_export, z_import) for column k
"""
function zone_to_zone_ptdf(PTDFz::AbstractMatrix; zones=nothing, exclude_self::Bool=true)
    l, z = size(PTDFz)
    m = exclude_self ? z*(z-1) : z*z
    T = eltype(PTDFz)
    M = Matrix{T}(undef, l, m)
    pairs = Vector{Tuple}(undef, m)
    k = 1
    @inbounds for zi in 1:z          # importer
        for zo in 1:z                # exporter
            if exclude_self && zo == zi
                continue
            end
            # column = PTDFz[:, importer] - PTDFz[:, exporter]
            @views M[:, k] = PTDFz[:, zi] .- PTDFz[:, zo]
            pairs[k] = zones === nothing ? (zo, zi) : (zones[zo], zones[zi])
            k += 1
        end
    end
    return M, pairs
end

function calc_mc!(params)

    if haskey(params.fuel_price, "co2")
        co2price = params.fuel_price["co2"]

    else
        co2price = FixedProfile(0)
    end

    iter = setdiff(params.sets.P, keys(params.mc))
    for p in iter
        fp = params.fuel_price[params.plant_type[p]]
        co2content = params.co2content[params.plant_type[p]]
        eta = params.eta[p]

        if co2content > 0
            co2cost = _calc_co2cost(co2price, co2content, eta)
        else
            co2cost = FixedProfile(0)
        end

        mc = _calc_mc(fp, eta)

        params.mc[p] = merge_mc_co2cost(mc, co2cost)
    end
end

_calc_co2cost(price::HourlyProfile, co2content, eta) =
    HourlyProfile(price.val .* co2content ./ eta)
_calc_co2cost(price::FixedProfile, co2content, eta) =
    FixedProfile(price.val * co2content / eta)
_calc_mc(price::FixedProfile, eta) = FixedProfile(price.val / eta)
_calc_mc(price::HourlyProfile, eta) = HourlyProfile(price.val ./ eta)

merge_mc_co2cost(mc, co2cost) = HourlyProfile(mc.val .+ co2cost.val)
merge_mc_co2cost(mc::FixedProfile, co2cost::FixedProfile) =
    FixedProfile(mc.val + co2cost.val)

function create_mappers!(params)
    @unpack Z, N, P, NTC = params.sets

    for n in N
        params.plants_in_node[n] = filter(p -> params.plant2node[p] == n, params.sets.P)
        params.storages_in_node[n] = filter(s -> params.plant2node[s] == n, params.sets.S)
    end

    for p in P
        params.plant2zone[p] = params.node2zone[params.plant2node[p]]
        if params.plant_type[p] in params.dispatchable
            if !(get(params.storage, p, 0) > 0)
                push!(params.sets.DISP, p)
            end
        else
            push!(params.sets.NDISP, p)
        end
    end

    for z in Z
        params.nodes_in_zone[z] = filter(n -> params.node2zone[n] == z, params.sets.N)
        params.plants_in_zone[z] = filter(p -> params.plant2zone[p] == z, params.sets.P)
        params.storages_in_zone[z] = filter(s -> params.plant2zone[s] == z, params.sets.S)

        imp = [zz for zz in Z if (zz, z) in NTC]
        isempty(imp) || (params.importing_ntcs[z] = imp)
        exp = [zz for zz in Z if (z, zz) in NTC]
        isempty(exp) || (params.exporting_ntcs[z] = exp)
    end

end

function map_avail_planttype!(params::Parameters)
    iter = setdiff(params.sets.P, keys(params.avail))
    for p in iter

        pt = params.plant_type[p]
        n = params.plant2node[p]
        z = params.plant2zone[p]

        if haskey(params.avail_planttype_nodal, (pt, n))
            params.avail[p] = params.avail_planttype_nodal[pt, n]
        elseif haskey(params.avail_planttype_zonal, (pt, z))
            params.avail[p] = params.avail_planttype_zonal[pt, z]
        else
            params.avail[p] = FixedProfile(1)
        end
    end
end

check_all_same(arr) = all(x -> x == first(arr), arr)

function calc_nodal_load_no_prs!(params::Parameters)
    @unpack PRS = params.sets
    @unpack nodal_load, prs_demand, plants_in_node = params

    for (k, v) in params.nodal_load
        prs_at_node = intersect(PRS, plants_in_node[k])
        max_length = max(length(v), [length(prs_demand[prs]) for prs in prs_at_node]...)
        prs_demand_at_node =
            [sum(prs_demand[prs][t] for prs in prs_at_node; init = 0) for t = 1:max_length]
        net_demand = [v[t] - sum(prs_demand_at_node[t]) for t = 1:max_length]

        if check_all_same(net_demand)
            params.nodal_load_no_prs[k] = FixedProfile(net_demand[1])
        else
            params.nodal_load_no_prs[k] = HourlyProfile(net_demand)
        end
    end

end

function create_subsets!(params::Parameters)


    # push all generators which are prosumers to PRS
    for p in params.sets.P
        plantype = params.plant_type[p]
        if plantype in params.prosumer_types
            push!(params.sets.PRS, p)
            if haskey(params.storage, p)
                is_not_zero = params.storage[p] > 0 && params.gmax_storage[p] > 0
                is_not_zero && push!(params.sets.PRS_STO, p)
            end
        end
    end

    # push all generators with storage to S
    for p in params.sets.P
        has_params = haskey(params.storage, p)

        if has_params
            params_not_zero = params.storage[p] > 0 #&& params.gmax_storage[p] > 0
        else
            params_not_zero = false
        end

        is_prs = p in params.sets.PRS

        if params_not_zero && !is_prs
            push!(params.sets.S, p)
        end
    end

end

calc_gmax(params::Parameters, p::String, t::Int) = params.avail[p][t] * params.gmax[p]