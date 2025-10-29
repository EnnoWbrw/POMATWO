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

"""
    validate_network_topology(report::DataReport, params::Parameters, location::String="network topology")

Validate network topology for common issues that cause singularity in PTDF calculation.
Checks for:
- Isolated nodes (not connected to any line)
- Network islands (disconnected subnetworks)
- Zero or missing reactances
- Lines referencing non-existent nodes
- Duplicate line definitions
"""
function validate_network_topology(report::DataReport, params, location::String="network topology")
    N = params.sets.N
    L = params.sets.L
    
    if isempty(L)
        add_note!(report, "network_validation", "No lines defined - skipping topology validation", location)
        return true
    end
    
    issues_found = false
    
    # Check 1: Lines reference valid nodes
    for l in L
        start_node = params.line_start[l]
        end_node = params.line_end[l]
        
        if !(start_node in N)
            add_error!(report, "network_topology", 
                      "Line '$l' references non-existent start node '$start_node'", location)
            issues_found = true
        end
        
        if !(end_node in N)
            add_error!(report, "network_topology", 
                      "Line '$l' references non-existent end node '$end_node'", location)
            issues_found = true
        end
        
        if start_node == end_node
            add_error!(report, "network_topology", 
                      "Line '$l' connects node '$start_node' to itself", location)
            issues_found = true
        end
    end
    
    # Check 2: Reactance and resistance values
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
    
    # Check 3: Find isolated nodes (not connected to any line)
    connected_nodes = Set{String}()
    for l in L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            push!(connected_nodes, params.line_start[l])
            push!(connected_nodes, params.line_end[l])
        end
    end
    
    isolated_nodes = setdiff(Set(N), connected_nodes)
    if !isempty(isolated_nodes)
        add_error!(report, "network_topology", 
                  "Found $(length(isolated_nodes)) isolated node(s) not connected to any line: $(join(sort(collect(isolated_nodes)), ", "))", 
                  location)
        issues_found = true
    end
    
    # Check 4: Detect network islands using depth-first search
    if length(connected_nodes) > 1
        adjacency = Dict{String, Vector{String}}()
        for n in connected_nodes
            adjacency[n] = String[]
        end
        
        for l in L
            if haskey(params.line_start, l) && haskey(params.line_end, l)
                start = params.line_start[l]
                stop = params.line_end[l]
                push!(adjacency[start], stop)
                push!(adjacency[stop], start)
            end
        end
        
        # DFS to find connected components
        visited = Set{String}()
        islands = Vector{Set{String}}()
        
        for start_node in connected_nodes
            if !(start_node in visited)
                # New island found
                island = Set{String}()
                stack = [start_node]
                
                while !isempty(stack)
                    node = pop!(stack)
                    if !(node in visited)
                        push!(visited, node)
                        push!(island, node)
                        for neighbor in adjacency[node]
                            if !(neighbor in visited)
                                push!(stack, neighbor)
                            end
                        end
                    end
                end
                
                push!(islands, island)
            end
        end
        
        if length(islands) > 1
            add_error!(report, "network_topology", 
                      "Network has $(length(islands)) disconnected islands (should be 1 connected network)", 
                      location)
            
            for (i, island) in enumerate(islands)
                island_nodes = join(sort(collect(island)), ", ")
                slack_in_island = count(n -> n in params.slack, island)
                add_error!(report, "network_topology", 
                          "Island $i: $(length(island)) nodes ($island_nodes), $slack_in_island slack bus(es)", 
                          location)
            end
            issues_found = true
        end
    end
    
    # Check 5: Duplicate lines (same start-end pair)
    line_connections = Dict{Tuple{String,String}, Vector{String}}()
    for l in L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            start = params.line_start[l]
            stop = params.line_end[l]
            # Normalize connection (order doesn't matter for undirected lines)
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
                        "Multiple lines ($(join(lines, ", "))) connect nodes '$n1' and '$n2' - parallel lines detected", 
                        location)
        end
    end
    
    # Check 6: Slack bus connectivity
    if !isempty(params.slack)
        for slack_node in params.slack
            if !(slack_node in connected_nodes)
                add_error!(report, "network_topology", 
                          "Slack bus '$slack_node' is not connected to any line", location)
                issues_found = true
            end
        end
    end
    
    return !issues_found
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