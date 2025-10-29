"""
    DataReportLevel

Enumeration for different levels of data validation reports.
"""
@enum DataReportLevel begin
    NOTE = 1
    WARNING = 2
    ERROR = 3
end

"""
    DataReportItem

Structure representing a single data validation report item.

# Fields
- `level::DataReportLevel`: The severity level (NOTE, WARNING, ERROR)
- `category::String`: Category of the validation issue (e.g., "file_access", "data_type", "range")
- `message::String`: Descriptive message about the validation issue
- `location::String`: Location where the issue was found (e.g., file path, column name)
"""
struct DataReportItem
    level::DataReportLevel
    category::String
    message::String
    location::String
end

"""
    DataReport

Container for collecting data validation reports during data loading.

# Fields
- `items::Vector{DataReportItem}`: Collection of all report items
- `has_errors::Bool`: Quick check if any errors were reported
"""
mutable struct DataReport
    items::Vector{DataReportItem}
    has_errors::Bool
    
    DataReport() = new(Vector{DataReportItem}(), false)
end

"""
    add_note!(report::DataReport, category::String, message::String, location::String="")

Add a note-level report item to the data report.
"""
function add_note!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(NOTE, category, message, location))
end

"""
    add_warning!(report::DataReport, category::String, message::String, location::String="")

Add a warning-level report item to the data report.
"""
function add_warning!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(WARNING, category, message, location))
end

"""
    add_error!(report::DataReport, category::String, message::String, location::String="")

Add an error-level report item to the data report.
"""
function add_error!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(ERROR, category, message, location))
    report.has_errors = true
end

"""
    get_errors(report::DataReport)

Return all error-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `ERROR`.
"""
get_errors(report::DataReport) = filter(item -> item.level == ERROR, report.items)

"""
    get_warnings(report::DataReport)

Return all warning-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `WARNING`.
"""
get_warnings(report::DataReport) = filter(item -> item.level == WARNING, report.items)

"""
    get_notes(report::DataReport)

Return all note-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `NOTE`.
"""
get_notes(report::DataReport) = filter(item -> item.level == NOTE, report.items)

"""
    has_issues(report::DataReport)

Check if the report contains any items (notes, warnings, or errors).
"""
has_issues(report::DataReport) = !isempty(report.items)

"""
    print_report(report::DataReport; show_notes::Bool=true, show_warnings::Bool=true, show_errors::Bool=true)

Print a formatted summary of the data report.
"""
function print_report(report::DataReport; show_notes::Bool=true, show_warnings::Bool=true, show_errors::Bool=true)
    if !has_issues(report)
        println("✓ Data loading completed without issues")
        return
    end
    
    println("Data Loading Report:")
    println("=" ^ 50)
    
    if show_errors
        errors = get_errors(report)
        if !isempty(errors)
            println("\n❌ ERRORS ($(length(errors))):")
            for item in errors
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_warnings
        warnings = get_warnings(report)
        if !isempty(warnings)
            println("\n⚠️  WARNINGS ($(length(warnings))):")
            for item in warnings
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_notes
        notes = get_notes(report)
        if !isempty(notes)
            println("\n📝 NOTES ($(length(notes))):")
            for item in notes
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    println()
end

"""
    validate_file_exists(report::DataReport, path::String, description::String="file")

Validate that a file exists and is readable, adding appropriate reports.
"""
function validate_file_exists(report::DataReport, path::String, description::String="file")
    if !isfile(path)
        add_error!(report, "file_access", "Required $description does not exist", path)
        return false
    end
    return true
end

"""
    validate_path_exists(report::DataReport, path::String, description::String="path")

Validate that a file or directory exists, adding appropriate reports.
This function accepts both files and directories, making it suitable for data loading
functions that can handle either (e.g., availability data stored as single file or directory of files).
"""
function validate_path_exists(report::DataReport, path::String, description::String="path")
    if !ispath(path)
        add_error!(report, "file_access", "Required $description does not exist", path)
        return false
    end
    return true
end

# ===== Network Topology Validation Helper Functions =====

"""
    get_connected_nodes(params, line_type::Symbol=:all)

Get sets of nodes connected by AC lines, DC lines, or both.

# Arguments
- `params`: Parameters object containing network data
- `line_type`: `:ac`, `:dc`, or `:all` (default)

# Returns
- `ac_connected`: Set of nodes connected by AC lines
- `dc_connected`: Set of nodes connected by DC lines
- `all_connected`: Set of nodes connected by any line
- `dc_only`: Set of nodes connected only by DC lines
- `isolated`: Set of nodes not connected to any line
"""
function get_connected_nodes(params)
    N = params.sets.N
    L = params.sets.L
    DC = params.sets.DC
    
    ac_connected = Set{String}()
    for l in L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            push!(ac_connected, params.line_start[l])
            push!(ac_connected, params.line_end[l])
        end
    end
    
    dc_connected = Set{String}()
    for dc in DC
        if haskey(params.dc_start, dc) && haskey(params.dc_end, dc)
            push!(dc_connected, params.dc_start[dc])
            push!(dc_connected, params.dc_end[dc])
        end
    end
    
    all_connected = union(ac_connected, dc_connected)
    dc_only = setdiff(dc_connected, ac_connected)
    isolated = setdiff(Set(N), all_connected)
    
    return ac_connected, dc_connected, all_connected, dc_only, isolated
end

"""
    get_nodes_to_omit_for_ptdf(params)

Get list of nodes that must be omitted from PTDF calculation.
This includes truly isolated nodes and nodes connected only via DC lines.

# Arguments
- `params`: Parameters object containing network data

# Returns
- `Vector{String}`: List of node names to omit from PTDF calculation
"""
function get_nodes_to_omit_for_ptdf(params)
    _, _, _, dc_only, isolated = get_connected_nodes(params)
    return sort(collect(union(dc_only, isolated)))
end

"""
    build_adjacency_list(params, include_dc::Bool=true)

Build adjacency list representation of the network graph.

# Arguments
- `params`: Parameters object containing network data
- `include_dc`: Whether to include DC lines in adjacency (default: true)

# Returns
- `Dict{String, Vector{String}}`: Adjacency list mapping each node to its neighbors
- `Set{String}`: Set of all nodes in the graph
"""
function build_adjacency_list(params, include_dc::Bool=true)
    L = params.sets.L
    DC = params.sets.DC
    
    ac_connected, dc_connected, all_connected, _, _ = get_connected_nodes(params)
    
    nodes = include_dc ? all_connected : ac_connected
    adjacency = Dict{String, Vector{String}}()
    
    for n in nodes
        adjacency[n] = String[]
    end
    
    # Add AC line connections
    for l in L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            start = params.line_start[l]
            stop = params.line_end[l]
            if start in nodes && stop in nodes
                push!(adjacency[start], stop)
                push!(adjacency[stop], start)
            end
        end
    end
    
    # Add DC line connections if requested
    if include_dc
        for dc in DC
            if haskey(params.dc_start, dc) && haskey(params.dc_end, dc)
                start = params.dc_start[dc]
                stop = params.dc_end[dc]
                if start in nodes && stop in nodes
                    push!(adjacency[start], stop)
                    push!(adjacency[stop], start)
                end
            end
        end
    end
    
    return adjacency, nodes
end

"""
    find_network_islands(adjacency::Dict{String, Vector{String}}, nodes::Set{String})

Find disconnected components (islands) in a network using depth-first search.

# Arguments
- `adjacency`: Adjacency list representation of the network
- `nodes`: Set of all nodes to consider

# Returns
- `Vector{Set{String}}`: List of islands, each island is a set of node names
"""
function find_network_islands(adjacency::Dict{String, Vector{String}}, nodes::Set{String})
    visited = Set{String}()
    islands = Vector{Set{String}}()
    
    for start_node in nodes
        if !(start_node in visited)
            # New island found - perform DFS
            island = Set{String}()
            stack = [start_node]
            
            while !isempty(stack)
                node = pop!(stack)
                if !(node in visited)
                    push!(visited, node)
                    push!(island, node)
                    if haskey(adjacency, node)
                        for neighbor in adjacency[node]
                            if !(neighbor in visited)
                                push!(stack, neighbor)
                            end
                        end
                    end
                end
            end
            
            push!(islands, island)
        end
    end
    
    return islands
end

"""
    validate_line_references(report::DataReport, params, location::String)

Validate that AC and DC lines reference valid nodes and don't create self-loops.

# Returns
- `Bool`: true if no issues found, false otherwise
"""
function validate_line_references(report::DataReport, params, location::String)
    N = params.sets.N
    L = params.sets.L
    DC = params.sets.DC
    issues_found = false
    
    # Check AC lines
    for l in L
        start_node = params.line_start[l]
        end_node = params.line_end[l]
        
        if !(start_node in N)
            add_error!(report, "network_topology", 
                      "AC line '$l' references non-existent start node '$start_node'", location)
            issues_found = true
        end
        
        if !(end_node in N)
            add_error!(report, "network_topology", 
                      "AC line '$l' references non-existent end node '$end_node'", location)
            issues_found = true
        end
        
        if start_node == end_node
            add_error!(report, "network_topology", 
                      "AC line '$l' connects node '$start_node' to itself", location)
            issues_found = true
        end
    end
    
    # Check DC lines
    for dc in DC
        start_node = params.dc_start[dc]
        end_node = params.dc_end[dc]
        
        if !(start_node in N)
            add_error!(report, "network_topology", 
                      "DC line '$dc' references non-existent start node '$start_node'", location)
            issues_found = true
        end
        
        if !(end_node in N)
            add_error!(report, "network_topology", 
                      "DC line '$dc' references non-existent end node '$end_node'", location)
            issues_found = true
        end
        
        if start_node == end_node
            add_error!(report, "network_topology", 
                      "DC line '$dc' connects node '$start_node' to itself", location)
            issues_found = true
        end
    end
    
    return !issues_found
end

"""
    validate_line_parameters(report::DataReport, params, location::String)

Validate reactance and resistance values for AC lines.

# Returns
- `Bool`: true if no critical issues found, false otherwise
"""
function validate_line_parameters(report::DataReport, params, location::String)
    L = params.sets.L
    issues_found = false
    
    for l in L
        if haskey(params.reactance, l)
            x = params.reactance[l]
            if x == 0.0
                add_error!(report, "network_topology", 
                          "Line '$l' has zero reactance (x=0), which causes singularity", location)
                issues_found = true
            elseif abs(x) < 1e-10
                add_warning!(report, "network_topology", 
                            "Line '$l' has very small reactance (x=$x), may cause numerical issues", location)
            end
        end
        
        if haskey(params.resistance, l)
            r = params.resistance[l]
            if abs(r) < 1e-10 && !haskey(params.reactance, l)
                add_warning!(report, "network_topology", 
                            "Line '$l' has very small resistance and no reactance defined", location)
            end
        end
    end
    
    return !issues_found
end

"""
    validate_node_connectivity(report::DataReport, params, location::String)

Validate node connectivity, identifying isolated nodes and DC-only nodes.

# Returns
- `Bool`: true if no critical issues found, false otherwise
"""
function validate_node_connectivity(report::DataReport, params, location::String)
    ac_connected, _, _, dc_only, isolated = get_connected_nodes(params)
    issues_found = false
    
    # Report truly isolated nodes (ERROR)
    if !isempty(isolated)
        add_error!(report, "network_topology", 
                  "Found $(length(isolated)) isolated node(s) not connected to any AC or DC line: $(join(sort(collect(isolated)), ", "))", 
                  location)
        issues_found = true
    end
    
    # Report DC-only nodes (WARNING - need to be omitted from PTDF calculation)
    if !isempty(dc_only)
        add_warning!(report, "network_topology", 
                    "Found $(length(dc_only)) node(s) connected only via DC lines (must be omitted from PTDF calculation): $(join(sort(collect(dc_only)), ", "))", 
                    location)
    end
    
    return !issues_found
end

"""
    validate_network_islands(report::DataReport, params, location::String)

Validate network connectivity, checking for disconnected islands in both the overall network
and the AC-only network (relevant for PTDF).

# Returns
- `Bool`: true if no critical issues found, false otherwise
"""
function validate_network_islands(report::DataReport, params, location::String)
    issues_found = false
    
    # Check overall network islands (AC + DC)
    adjacency_all, all_nodes = build_adjacency_list(params, true)
    if length(all_nodes) > 1
        islands_all = find_network_islands(adjacency_all, all_nodes)
        
        if length(islands_all) > 1
            add_error!(report, "network_topology", 
                      "Network has $(length(islands_all)) disconnected islands considering AC+DC lines (should be 1 connected network)", 
                      location)
            
            for (i, island) in enumerate(islands_all)
                island_nodes = join(sort(collect(island)), ", ")
                slack_in_island = count(n -> n in params.slack, island)
                add_error!(report, "network_topology", 
                          "Island $i: $(length(island)) nodes ($island_nodes), $slack_in_island slack bus(es)", 
                          location)
            end
            issues_found = true
        end
    end
    
    # Check AC network islands (relevant for PTDF)
    adjacency_ac, ac_nodes = build_adjacency_list(params, false)
    if !isempty(params.sets.L) && length(ac_nodes) > 1
        islands_ac = find_network_islands(adjacency_ac, ac_nodes)
        
        if length(islands_ac) > 1
            add_warning!(report, "network_topology", 
                        "AC network has $(length(islands_ac)) disconnected islands for PTDF calculation", 
                        location)
            
            for (i, island) in enumerate(islands_ac)
                island_nodes = join(sort(collect(island)), ", ")
                slack_in_island = count(n -> n in params.slack, island)
                add_warning!(report, "network_topology", 
                            "AC island $i: $(length(island)) nodes ($island_nodes), $slack_in_island slack bus(es)", 
                            location)
            end
        end
    end
    
    return !issues_found
end

"""
    validate_duplicate_lines(report::DataReport, params, location::String)

Check for parallel lines (multiple lines connecting the same pair of nodes).

# Returns
- `Bool`: Always returns true (warnings only, no errors)
"""
function validate_duplicate_lines(report::DataReport, params, location::String)
    L = params.sets.L
    DC = params.sets.DC
    
    # Check AC lines
    line_connections = Dict{Tuple{String,String}, Vector{String}}()
    for l in L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            start = params.line_start[l]
            stop = params.line_end[l]
            connection = start < stop ? (start, stop) : (stop, start)
            
            if !haskey(line_connections, connection)
                line_connections[connection] = String[]
            end
            push!(line_connections[connection], l)
        end
    end
    
    for ((n1, n2), lines) in line_connections
        if length(lines) > 1
            add_warning!(report, "network_topology", 
                        "Multiple AC lines ($(join(lines, ", "))) connect nodes '$n1' and '$n2' - parallel lines detected", 
                        location)
        end
    end
    
    # Check DC lines
    dc_connections = Dict{Tuple{String,String}, Vector{String}}()
    for dc in DC
        if haskey(params.dc_start, dc) && haskey(params.dc_end, dc)
            start = params.dc_start[dc]
            stop = params.dc_end[dc]
            connection = start < stop ? (start, stop) : (stop, start)
            
            if !haskey(dc_connections, connection)
                dc_connections[connection] = String[]
            end
            push!(dc_connections[connection], dc)
        end
    end
    
    for ((n1, n2), lines) in dc_connections
        if length(lines) > 1
            add_warning!(report, "network_topology", 
                        "Multiple DC lines ($(join(lines, ", "))) connect nodes '$n1' and '$n2' - parallel lines detected", 
                        location)
        end
    end
    
    return true
end

"""
    validate_slack_bus_connectivity(report::DataReport, params, location::String)

Validate that slack buses are properly connected to the network.

# Returns
- `Bool`: true if no critical issues found, false otherwise
"""
function validate_slack_bus_connectivity(report::DataReport, params, location::String)
    if isempty(params.slack)
        return true
    end
    
    _, _, all_connected, dc_only, _ = get_connected_nodes(params)
    issues_found = false
    
    for slack_node in params.slack
        if !(slack_node in all_connected)
            add_error!(report, "network_topology", 
                      "Slack bus '$slack_node' is not connected to any AC or DC line", location)
            issues_found = true
        elseif slack_node in dc_only
            add_warning!(report, "network_topology", 
                        "Slack bus '$slack_node' is connected only via DC lines (cannot participate in AC power flow)", 
                        location)
        end
    end
    
    return !issues_found
end

"""
    validate_network_topology(report::DataReport, params::Parameters, location::String="network topology")

Validate network topology for common issues that cause singularity in PTDF calculation.

This function orchestrates multiple validation checks:
- Line reference validation (nodes exist, no self-loops)
- Line parameter validation (reactance, resistance)
- Node connectivity (isolated nodes, DC-only nodes)
- Network islands (overall and AC-only)
- Duplicate/parallel lines
- Slack bus connectivity

# Arguments
- `report::DataReport`: Report object to accumulate validation messages
- `params`: Parameters object containing network data
- `location::String`: Location identifier for error messages

# Returns
- `Bool`: true if no critical issues found, false if errors were detected
"""
function validate_network_topology(report::DataReport, params, location::String="network topology")
    L = params.sets.L
    DC = params.sets.DC
    
    if isempty(L) && isempty(DC)
        add_note!(report, "network_validation", "No AC or DC lines defined - skipping topology validation", location)
        return true
    end
    
    # Run all validation checks
    valid_refs = validate_line_references(report, params, location)
    valid_params = validate_line_parameters(report, params, location)
    valid_connectivity = validate_node_connectivity(report, params, location)
    valid_islands = validate_network_islands(report, params, location)
    validate_duplicate_lines(report, params, location)  # Always returns true (warnings only)
    valid_slack = validate_slack_bus_connectivity(report, params, location)
    
    # Return true only if no critical errors were found
    return valid_refs && valid_params && valid_connectivity && valid_islands && valid_slack
end

"""
    validate_numeric_column(report::DataReport, df::AbstractDataFrame, column::Symbol, 
                           location::String; required::Bool=true, positive::Bool=false)

Validate that a column contains numeric values with optional constraints.
"""
function validate_numeric_column(report::DataReport, df::AbstractDataFrame, column::Symbol, 
                                location::String; required::Bool=true, positive::Bool=false)
    if !hasproperty(df, column)
        if required
            add_error!(report, "missing_column", "Required column '$column' not found", location)
        else
            add_note!(report, "missing_column", "Optional column '$column' not found", location)
        end
        return false
    end
    
    col_data = df[!, column]
    
    # Check for missing values in required columns
    if required && any(ismissing, col_data)
        missing_count = count(ismissing, col_data)
        add_error!(report, "missing_values", 
                  "Column '$column' has $missing_count missing values", location)
    end
    
    # Check data types
    non_missing_data = skipmissing(col_data)
    if !all(x -> isa(x, Number), non_missing_data)
        non_numeric_count = count(x -> !isa(x, Number), non_missing_data)
        add_error!(report, "data_type", 
                  "Column '$column' has $non_numeric_count non-numeric values", location)
        return false
    end
    
    # Check positive constraint
    if positive && any(x -> x < 0, non_missing_data)
        negative_count = count(x -> x < 0, non_missing_data)
        add_error!(report, "range_validation", 
                  "Column '$column' has $negative_count negative values (must be >= 0)", location)
    end
    
    return true
end

"""
    validate_required_columns(report::DataReport, df::AbstractDataFrame, 
                             required_columns::Vector{Symbol}, location::String)

Validate that all required columns are present in a DataFrame.
"""
function validate_required_columns(report::DataReport, df::AbstractDataFrame, 
                                 required_columns::Vector{Symbol}, location::String)
    missing_columns = Symbol[]
    for col in required_columns
        if !hasproperty(df, col)
            push!(missing_columns, col)
        end
    end
    
    if !isempty(missing_columns)
        add_error!(report, "missing_columns", 
                  "Missing required columns: $(join(missing_columns, ", "))", location)
        return false
    end
    
    return true
end