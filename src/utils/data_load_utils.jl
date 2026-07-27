"""
    diagnose_singular_matrix(b_red::Matrix{Float64}, included_nodes::Vector{String}, report::DataReport, location::String)

Diagnostic function to identify why a matrix is singular.
Checks for network islands, zero rows/columns, and rank deficiency.
Diagnostic results are written to `report` via the `DataReport` API.
"""
function diagnose_singular_matrix(b_red::Matrix{Float64}, included_nodes::Vector{String}, report::DataReport, location::String="singular matrix diagnostics")
    n = size(b_red, 1)
    
    # Check determinant
    det_val = det(BigFloat.(b_red))
    
    # Check rank
    r = rank(b_red)
    add_note!(report, "singular_matrix_diagnostics",
              "Determinant: $det_val, Rank: $r / $n (deficit: $(n - r))",
              location)
    
    # Check for zero or near-zero rows/columns
    row_norms = [norm(b_red[i, :]) for i in 1:n]
    col_norms = [norm(b_red[:, j]) for j in 1:n]
    
    zero_rows = findall(x -> x < 1e-10, row_norms)
    zero_cols = findall(x -> x < 1e-10, col_norms)
    
    if !isempty(zero_rows)
        nodes_str = join(["$(included_nodes[i]) (row $i, norm: $(row_norms[i]))" for i in zero_rows], ", ")
        add_warning!(report, "singular_matrix_diagnostics",
                     "Nodes with near-zero rows (likely isolated or faulty line data): $nodes_str",
                     location)
    end
    
    if !isempty(zero_cols)
        nodes_str = join(["$(included_nodes[j]) (col $j, norm: $(col_norms[j]))" for j in zero_cols], ", ")
        add_warning!(report, "singular_matrix_diagnostics",
                     "Nodes with near-zero columns (likely isolated or faulty line data): $nodes_str",
                     location)
    end
    
    # Check condition number
    cond_num = cond(b_red)
    if cond_num > 1e12
        add_warning!(report, "singular_matrix_diagnostics",
                     "Condition number: $cond_num — matrix is severely ill-conditioned!",
                     location)
    else
        add_note!(report, "singular_matrix_diagnostics",
                  "Condition number: $cond_num",
                  location)
    end
    
    # Check for disconnected components (simplified check)
    # A connected network should have rank = n-1 for the Laplacian-like matrix
    if r < n - 1
        add_error!(report, "singular_matrix_diagnostics",
                   "Expected rank for connected network: $(n-1), actual rank: $r — network likely has $(n - r) disconnected islands!",
                   location)
    else
        add_note!(report, "singular_matrix_diagnostics",
                  "Expected rank for connected network: $(n-1), actual rank: $r",
                  location)
    end
    
    # Show diagonal values
    diag_vals = diag(b_red)
    add_note!(report, "singular_matrix_diagnostics",
              "Diagonal value statistics — Min: $(minimum(diag_vals)), Max: $(maximum(diag_vals)), Mean: $(sum(diag_vals) / n)",
              location)
    
    near_zero_diag = findall(x -> abs(x) < 1e-6, diag_vals)
    if !isempty(near_zero_diag)
        nodes_str = join(["$(included_nodes[i]): $(diag_vals[i])" for i in near_zero_diag], ", ")
        add_warning!(report, "singular_matrix_diagnostics",
                     "Nodes with near-zero diagonal (suspicious): $nodes_str",
                     location)
    end
end

"""
    diagnose_missing_slacks(island_nodes, slack_list, params, report, location)

Identify disconnected AC islands among nodes included in the PTDF calculation and
report which islands are missing a slack bus. Suggests a candidate slack node for
each island that currently lacks one.

Called automatically when the B-matrix is found to be singular.
Diagnostic results are written to `report` via the `DataReport` API.
"""
function diagnose_missing_slacks(island_nodes::Vector{String}, slack_list::Vector{String}, params::Parameters, report::DataReport, location::String="island slack diagnostics")
    island_node_set = Set(island_nodes)
    L = params.sets.L

    # Build AC-only adjacency restricted to included nodes
    adjacency = Dict{String, Vector{String}}(n => String[] for n in island_nodes)
    for l in L
        s = get(params.line_start, l, nothing)
        e = get(params.line_end,   l, nothing)
        if !isnothing(s) && !isnothing(e) && s in island_node_set && e in island_node_set
            push!(adjacency[s], e)
            push!(adjacency[e], s)
        end
    end

    # DFS to find connected components
    visited = Set{String}()
    islands = Vector{Vector{String}}()
    for start in island_nodes
        if !(start in visited)
            island = String[]
            stack = [start]
            while !isempty(stack)
                node = pop!(stack)
                if !(node in visited)
                    push!(visited, node)
                    push!(island, node)
                    for nb in adjacency[node]
                        !(nb in visited) && push!(stack, nb)
                    end
                end
            end
            push!(islands, island)
        end
    end

    slack_set = Set(slack_list)

    add_note!(report, "island_slack_diagnostics",
              "Found $(length(islands)) AC island(s) among $(length(island_nodes)) nodes. Each island requires exactly 1 slack bus.",
              location)

    n_missing = 0
    for (i, island) in enumerate(sort(islands, by=length, rev=true))
        slack_in_island = filter(n -> n in slack_set, island)
        has_slack = !isempty(slack_in_island)

        if has_slack
            add_note!(report, "island_slack_diagnostics",
                      "Island $i ($(length(island)) nodes): OK — slack: $(join(slack_in_island, ", "))",
                      location)
        else
            n_missing += 1
            candidate = first(sort(island))
            add_error!(report, "island_slack_diagnostics",
                       "Island $i ($(length(island)) nodes): NO SLACK — suggested candidate: $candidate",
                       location)
        end
    end

    if n_missing > 0
        add_error!(report, "island_slack_diagnostics",
                   "Identified $n_missing island(s) without a slack bus. Each island must have exactly 1 slack node defined in the input data to ensure a non-singular B-matrix. Check report for details and suggested candidate nodes for slack assignment.",
                   location)
    else
        add_note!(report, "island_slack_diagnostics",
                  "All islands already have a slack node. Singularity is likely caused by zero/near-zero line reactances — check line parameters.",
                  location)
    end
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
            add_error!(report, "matrix_calculation", 
                        "B-matrix is not symmetric - indicates numerical or algorithmic issue", 
                        "PTDF calculation")
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
        b_red_inv = zeros(size(b_red))

        # Try regular inversion first. This avoids expensive and numerically fragile
        # determinant checks on very large matrices.
        try
            b_red_inv = inv(b_red)
        catch e
            if e isa LinearAlgebra.SingularException
                @warn """
                B-matrix inversion failed (singular matrix).
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

                # Run detailed diagnostics on reduced matrix
                included_nodes = N[included_idx]
           
                diagnose_singular_matrix(b_red, included_nodes, report, "PTDF calculation")
    

                # For island-slack diagnostics include slack buses (omit only PTDF-omitted nodes)
                island_nodes_idx = setdiff(1:length(N), omit_idx)
                island_nodes = N[island_nodes_idx]
                    diagnose_missing_slacks(island_nodes, slack_list, params, report, "PTDF calculation")
                    add_warning!(report, "ptdf_calculation", 
                                "B-matrix is singular - using pseudoinverse (may produce inaccurate PTDF values). Check report for detailed island slack diagnostics.", 
                                "PTDF calculation")
                b_red_inv = pinv(b_red)
            else
                rethrow(e)
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

function find_connected_zones(params::Parameters)
    @unpack L, DC = params.sets
    @unpack line_start, line_end, dc_start, dc_end, node2zone = params
    
    connected_zones = Set{Tuple{String, String}}()
    
    # Check AC lines for inter-zonal connections
    for l in L
        z_start = node2zone[line_start[l]]
        z_end = node2zone[line_end[l]]
        if z_start != z_end
            push!(connected_zones, (z_start, z_end))
            push!(connected_zones, (z_end, z_start))
        end
    end
    
    # Check DC lines for inter-zonal connections
    for dc in DC
        z_start = node2zone[dc_start[dc]]
        z_end = node2zone[dc_end[dc]]
        if z_start != z_end
            push!(connected_zones, (z_start, z_end))
            push!(connected_zones, (z_end, z_start))
        end
    end
    
    return collect(connected_zones)
end

function find_connected_zones_ac(params::Parameters)
    @unpack L, DC = params.sets
    @unpack line_start, line_end, dc_start, dc_end, node2zone = params
    
    connected_zones = Set{Tuple{String, String}}()
    
    # Check AC lines for inter-zonal connections
    for l in L
        z_start = node2zone[line_start[l]]
        z_end = node2zone[line_end[l]]
        if z_start != z_end
            push!(connected_zones, (z_start, z_end))
            push!(connected_zones, (z_end, z_start))
        end
    end
    return collect(connected_zones)
end


# Store coordinates for a single node row into params.node_coords
function _load_node_coords!(params::Parameters, row, report::DataReport, location::String)
    if "lat" in names(row) && "lon" in names(row)
        if !ismissing(row[:lat]) && !ismissing(row[:lon])
            params.node_coords[row[:index]] = [row[:lon], row[:lat]]
        else
            params.node_coords[row[:index]] = [0.0, 0.0]
            add_note!(report, "missing_coordinates",
                     "Node $(row[:index]) missing coordinates, using [0.0, 0.0]", location)
        end
    elseif "latitude" in names(row) && "longitude" in names(row)
        if !ismissing(row[:latitude]) && !ismissing(row[:longitude])
            params.node_coords[row[:index]] = [row[:longitude], row[:latitude]]
        else
            params.node_coords[row[:index]] = [0.0, 0.0]
            add_note!(report, "missing_coordinates",
                     "Node $(row[:index]) missing coordinates, using [0.0, 0.0]", location)
        end
    else
        params.node_coords[row[:index]] = [0.0, 0.0]
    end
end

# Load nodes using the legacy 0/1 slack format (deprecated).
# Emits a deprecation warning. Each node with slack=1 becomes a standalone slack bus;
# no slack_zone grouping is built.
function _add_nodes_legacy!(params::Parameters, df_nodes::AbstractDataFrame, report::DataReport, location::String)
    add_warning!(report, "deprecated_slack_format",
        "The numeric 0/1 'slack' column format is deprecated. " *
        "Use node index references instead: set each node's 'slack' value to the " *
        "index of its slack bus (or to its own index if it IS the slack bus). " *
        "Support for the 0/1 format may be removed in a future version.", location)

    for row in eachrow(df_nodes)
        if ismissing(row[:index]) || ismissing(row[:zone]) || ismissing(row[:slack])
            add_warning!(report, "incomplete_data",
                        "Skipping node row with missing critical data", location)
            continue
        end

        push!(params.sets.N, row[:index])
        params.node2zone[row[:index]] = row[:zone]

        if row[:slack] == 1 || row[:slack] == 1.0 || row[:slack] == "1"
            push!(params.slack, string(row[:index]))
        end

        _load_node_coords!(params, row, report, location)
    end
end

# Validate the reference-based slack column and raise errors for inconsistencies.
function _validate_slack_references(df_nodes::AbstractDataFrame, report::DataReport, location::String)
    non_missing_slack = collect(skipmissing(df_nodes[!, :slack]))
    all_indices = Set(string.(skipmissing(df_nodes[!, :index])))

    # Every slack value must point to a known node index
    for s in unique(non_missing_slack)
        if !(string(s) in all_indices)
            add_error!(report, "invalid_slack_reference",
                      "Slack value '$s' does not match any node index", location)
        end
    end

    # A node referenced as a slack bus by others must also reference itself
    index_to_slack = Dict(string(row[:index]) => string(row[:slack])
                          for row in eachrow(df_nodes)
                          if !ismissing(row[:index]) && !ismissing(row[:slack]))
    for s in unique(values(index_to_slack))
        if haskey(index_to_slack, s) && index_to_slack[s] != s
            add_error!(report, "invalid_slack_reference",
                      "Node '$s' is referenced as a slack bus by other nodes, " *
                      "but its own 'slack' value is '$(index_to_slack[s])'. " *
                      "A slack bus must reference itself.", location)
        end
    end
end

# Load nodes using the reference-based slack format.
# Builds both params.slack (self-referencing nodes) and params.slack_zone (all groups).
function _add_nodes_reference!(params::Parameters, df_nodes::AbstractDataFrame, report::DataReport, location::String)
    _validate_slack_references(df_nodes, report, location)

    for row in eachrow(df_nodes)
        if ismissing(row[:index]) || ismissing(row[:zone]) || ismissing(row[:slack])
            add_warning!(report, "incomplete_data",
                        "Skipping node row with missing critical data", location)
            continue
        end

        push!(params.sets.N, row[:index])
        params.node2zone[row[:index]] = row[:zone]
        _load_node_coords!(params, row, report, location)
    end

    # Slack buses are the nodes whose slack value equals their own index
    for row in eachrow(df_nodes)
        if !ismissing(row[:index]) && !ismissing(row[:slack]) &&
           string(row[:index]) == string(row[:slack])
            push!(params.slack, string(row[:index]))
        end
    end

    # Group every node by its slack reference to build slack_zone
    for gdf in groupby(df_nodes, :slack)
        s = string(first(gdf[!, :slack]))
        params.slack_zone[s] = string.(gdf[!, :index])
    end
end