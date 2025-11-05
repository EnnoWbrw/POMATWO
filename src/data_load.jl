function add_plants!(params::Parameters, df_pp::AbstractDataFrame, report::DataReport, location::String="plants data")
    # Validate required columns
    required_columns = [:index, :plant_type, :node, :g_max, :eta]
    if !validate_required_columns(report, df_pp, required_columns, location)
        return  # Can't proceed without required columns
    end
    
    # Validate numeric columns
    validate_numeric_column(report, df_pp, :g_max, location; required=true, positive=true)
    validate_numeric_column(report, df_pp, :eta, location; required=true)
    validate_numeric_column(report, df_pp, :storage_capacity, location; required=false, positive=true)
    validate_numeric_column(report, df_pp, :storage_power, location; required=false, positive=true)
    validate_numeric_column(report, df_pp, :mc, location; required=false)
    validate_numeric_column(report, df_pp, :availability, location; required=false)
    
    # Validate efficiency range
    if hasproperty(df_pp, :eta)
        eta_data = skipmissing(df_pp[!, :eta])
        if any(x -> x < 0 || x > 1, eta_data)
            out_of_range_count = count(x -> x < 0 || x > 1, eta_data)
            add_warning!(report, "range_validation", 
                        "Column 'eta' has $out_of_range_count values outside [0,1] range", location)
        end
    end
    
    # Check for duplicate plant indices
    if hasproperty(df_pp, :index)
        indices = df_pp[!, :index]
        unique_indices = unique(indices)
        if length(indices) != length(unique_indices)
            duplicate_count = length(indices) - length(unique_indices)
            add_error!(report, "duplicate_values", 
                      "Found $duplicate_count duplicate plant indices", location)
        end
    end
    
    for row in eachrow(df_pp)
        # Skip rows with critical missing data
        if ismissing(row[:index]) || ismissing(row[:plant_type]) || 
           ismissing(row[:node]) || ismissing(row[:g_max]) || ismissing(row[:eta])
            add_warning!(report, "incomplete_data", 
                        "Skipping row with missing critical data", location)
            continue
        end
        
        push!(params.sets.P, row[:index])
        params.gmax[row[:index]] = row[:g_max]

        storage_capacity = hasproperty(row, :storage_capacity) ? row[:storage_capacity] : missing
        storage_power = hasproperty(row, :storage_power) ? row[:storage_power] : missing
        storage_param_exist = !ismissing(storage_capacity) && !ismissing(storage_power)

        if storage_param_exist
            params.storage[row[:index]] = storage_capacity
            params.gmax_storage[row[:index]] = storage_power
        end

        if haskey(row, :mc)
            if row[:mc] isa Number
                params.mc[row[:index]] = FixedProfile(row[:mc])
            end

        end

        if haskey(row, :availability)
            if row[:availability] isa Number
                params.avail[row[:index]] = FixedProfile(row[:availability])
            end

        end

        params.plant_type[row[:index]] = row[:plant_type]
        params.plant2node[row[:index]] = row[:node]
        params.eta[row[:index]] = row[:eta]
    end
    
    # Add summary note
    add_note!(report, "data_summary", 
              "Loaded $(length(params.sets.P)) plants", location)
end

function add_plants!(params::Parameters, df_pp::AbstractDataFrame)
    report = DataReport()
    add_plants!(params, df_pp, report, "plants DataFrame")
    if has_issues(report)
        @warn "Issues found while loading plants data:"
        print_report(report; show_notes=false)
    end
end



function add_plants!(params::Parameters, path::AbstractString)
    report = DataReport()
    
    if !validate_file_exists(report, path, "plants file")
        print_report(report)
        error("Cannot proceed without plants file")
    end
    
    try
        df = read_csv(path)
        add_plants!(params, df, report, path)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", path)
        print_report(report)
        rethrow(e)
    end
    
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    return report
end

function add_plants!(params::Parameters, files::Vector{<:AbstractString})
    for file in files
        df = read_csv(file)
        add_plants!(params, df)
    end
end

function add_plants!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "plants file")
        return
    end
    
    try
        df = read_csv(path)
        add_plants!(params, df, report, location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", location)
    end
end

function add_plants!(params::Parameters, files::Vector{<:AbstractString}, report::DataReport, location::String)
    for file in files
        if !validate_file_exists(report, file, "plants file")
            continue
        end
        
        try
            df = read_csv(file)
            add_plants!(params, df, report, file)
        catch e
            add_error!(report, "file_parsing", "Failed to parse file $(file): $(string(e))", location)
        end
    end
end

function add_nodes!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "nodes file")
        return
    end
    
    try
        df = read_csv(path)
        add_nodes!(params, df, report, location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", location)
    end
end

function add_zones!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "zones file")
        return
    end
    
    try
        df = read_csv(path)
        add_zones!(params, df, report, location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", location)
    end
end

function add_demand!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "demand file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        add_demand!(params, df, report, location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", location)
    end
end

function add_types!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "types file")
        return
    end
    
    try
        df = read_csv(path)
        add_types!(params, df, report, location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", location)
    end
end

function add_nodes!(params::Parameters, df_nodes::AbstractDataFrame, report::DataReport, location::String="nodes data")
    # Validate required columns
    required_columns = [:index, :zone, :slack]
    if !validate_required_columns(report, df_nodes, required_columns, location)
        return
    end
    
    # Validate slack column values (should be 0 or 1)
    if hasproperty(df_nodes, :slack)
        slack_data = skipmissing(df_nodes[!, :slack])
        if !all(x -> x in [0, 1], slack_data)
            invalid_count = count(x -> !(x in [0, 1]), slack_data)
            add_error!(report, "range_validation", 
                      "Column 'slack' has $invalid_count values not in {0, 1}", location)
        end
    end
    
    # Validate coordinate columns if present
    for coord_col in [:lat, :lon, :latitude, :longitude]
        if hasproperty(df_nodes, coord_col)
            validate_numeric_column(report, df_nodes, coord_col, location; required=false)
        end
    end
    
    # Check for duplicate node indices
    if hasproperty(df_nodes, :index)
        indices = df_nodes[!, :index]
        unique_indices = unique(indices)
        if length(indices) != length(unique_indices)
            duplicate_count = length(indices) - length(unique_indices)
            add_error!(report, "duplicate_values", 
                      "Found $duplicate_count duplicate node indices", location)
        end
    end
    
    slack_count = 0
    for row in eachrow(df_nodes)
        # Skip rows with critical missing data
        if ismissing(row[:index]) || ismissing(row[:zone]) || ismissing(row[:slack])
            add_warning!(report, "incomplete_data", 
                        "Skipping node row with missing critical data", location)
            continue
        end
        
        push!(params.sets.N, row[:index])
        if row[:slack] == 1 
            push!(params.slack, row[:index])
            slack_count += 1
        end
        params.node2zone[row[:index]] = row[:zone]
        
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
    
    # Validate slack bus configuration
    if slack_count == 0
        add_error!(report, "configuration_error", 
                  "No slack bus defined (need at least one node with slack=1)", location)
    elseif slack_count > 1
        add_warning!(report, "configuration_warning", 
                    "Multiple slack buses defined ($slack_count), this may cause issues", location)
    end
    
    add_note!(report, "data_summary", 
              "Loaded $(length(params.sets.N)) nodes with $slack_count slack bus(es)", location)
end

function add_nodes!(params::Parameters, df_nodes::AbstractDataFrame)
    report = DataReport()
    add_nodes!(params, df_nodes, report, "nodes DataFrame")
    if has_issues(report)
        @warn "Issues found while loading nodes data:"
        print_report(report; show_notes=false)
    end
end
function add_nodes!(params::Parameters, path::AbstractString)
    report = DataReport()
    
    if !validate_file_exists(report, path, "nodes file")
        print_report(report)
        error("Cannot proceed without nodes file")
    end
    
    try
        df = read_csv(path)
        add_nodes!(params, df, report, path)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", path)
        print_report(report)
        rethrow(e)
    end
    
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    return report
end

function add_zones!(params::Parameters, df_zones::AbstractDataFrame, report::DataReport, location::String="zones data")
    # Validate required columns
    required_columns = [:index]
    if !validate_required_columns(report, df_zones, required_columns, location)
        return
    end
    
    # Check for duplicate zone indices
    if hasproperty(df_zones, :index)
        indices = df_zones[!, :index]
        unique_indices = unique(indices)
        if length(indices) != length(unique_indices)
            duplicate_count = length(indices) - length(unique_indices)
            add_error!(report, "duplicate_values", 
                      "Found $duplicate_count duplicate zone indices", location)
        end
    end
    
    for row in eachrow(df_zones)
        if ismissing(row[:index])
            add_warning!(report, "incomplete_data", 
                        "Skipping zone row with missing index", location)
            continue
        end
        
        push!(params.sets.Z, row[:index])
    end
    
    add_note!(report, "data_summary", 
              "Loaded $(length(params.sets.Z)) zones", location)
end

function add_zones!(params::Parameters, df_zones::AbstractDataFrame)
    report = DataReport()
    add_zones!(params, df_zones, report, "zones DataFrame")
    if has_issues(report)
        @warn "Issues found while loading zones data:"
        print_report(report; show_notes=false)
    end
end

function add_zones!(params::Parameters, path::AbstractString)
    report = DataReport()
    
    if !validate_file_exists(report, path, "zones file")
        print_report(report)
        error("Cannot proceed without zones file")
    end
    
    try
        df = read_csv(path)
        add_zones!(params, df, report, path)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", path)
        print_report(report)
        rethrow(e)
    end
    
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    return report
end

function add_lines!(params::Parameters, df_lines::AbstractDataFrame)
    for row in eachrow(df_lines)
        push!(params.sets.L, row[:index])

        trm = 1 ### transfer reliability margin
        params.acline_capacity[row[:index]] = trm * row[:capacity]

        if haskey(row, :circuits)
            params.circuits[row[:index]] = row[:circuits]
        else
            params.circuits[row[:index]] = 1
        end

        if haskey(row, :x_pu) && haskey(row, :r_pu)
            params.resistance[row[:index]] = row[:r_pu]
            params.reactance[row[:index]] = row[:x_pu]
        else
            params.resistance[row[:index]] =
                row[:r] / zbase(row[:voltage]) / params.circuits[row[:index]]
            params.reactance[row[:index]] =
                row[:x] / zbase(row[:voltage]) / params.circuits[row[:index]]
        end

        if haskey(row, :b)
            params.bvector[row[:index]] = row[:b]
        end

        params.voltage[row[:index]] = row[:voltage]
        params.line_start[row[:index]] = row[:node_i]
        params.line_end[row[:index]] = row[:node_j]
    end
end

function add_lines!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_lines!(params, df)
end

function add_dclines!(params::Parameters, df_dclines::AbstractDataFrame)
    for row in eachrow(df_dclines)
        push!(params.sets.DC, row[:index])
        params.dcline_capacity[row[:index]] = row[:capacity]
        params.dc_start[row[:index]] = row[:node_i]
        params.dc_end[row[:index]] = row[:node_j]
    end
end

function add_dclines!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_dclines!(params, df)
end

# Stub implementations for other functions to accept report parameter
# These maintain original functionality while accepting a report parameter

function add_demand!(params::Parameters, df_demand::AbstractDataFrame, report::DataReport, location::String="demand data")
    # Original implementation with basic validation
    if !validate_required_columns(report, df_demand, Symbol[], location)  # No strict requirements, but check structure
        add_note!(report, "validation_info", "Demand data structure check completed", location)
    end
    
    stacked = "value" in names(df_demand)

    if stacked
        df_demand = unstack(df_demand, 1, 2, :value)
        df_demand = coalesce.(df_demand, 0)
    end

    s = names(df_demand)[1] in ["Hour", "index"] ? 2 : 1

    # Validate node consistency based on demand table columns (no explicit Time column expected)
    try
        node_cols = String.(names(df_demand)[s:end])
        # Errors for unknown nodes present in file
        for n in node_cols
            if !(n in params.sets.N)
                add_error!(report, "unknown_node_in_demand", "Node '" * n * "' appears in demand data but is not defined in nodes set", location)
            end
        end
        # Warnings for nodes that exist but have no column in the file
        missing_in_file = setdiff(params.sets.N, node_cols)
        for n in missing_in_file
            add_warning!(report, "node_missing_demand", "Node '" * n * "' has no demand column in input; will default to 0", location)
        end
    catch err
        add_note!(report, "demand_node_validation_skipped", "Could not infer node columns in demand DataFrame (" * string(err) * ")", location)
    end
    loaded_nodes = 0
    for col in pairs(eachcol(df_demand[!, s:end]))
        params.nodal_load[string(col[1])] = HourlyProfile(Vector(col[2]))
        loaded_nodes += 1
    end

    for n in setdiff(params.sets.N, keys(params.nodal_load))
        params.nodal_load[n] = FixedProfile(0)
    end
    
    add_note!(report, "data_summary", "Loaded demand data for $loaded_nodes nodes", location)
end

function add_demand!(params::Parameters, path::AbstractString)
    report = DataReport()
    
    if !validate_file_exists(report, path, "demand file")
        print_report(report)
        error("Cannot proceed without demand file")
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        add_demand!(params, df, report, path)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", path)
        print_report(report)
        rethrow(e)
    end
    
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    return report
end

function add_types!(params::Parameters, df_types::AbstractDataFrame, report::DataReport, location::String="types data")
    # Validate required columns
    required_columns = [:index, :dispatchable]
    if !validate_required_columns(report, df_types, required_columns, location)
        return
    end
    
    # Validate binary columns
    for binary_col in [:dispatchable, :prosumer, :storage]
        if hasproperty(df_types, binary_col)
            col_data = skipmissing(df_types[!, binary_col])
            if !all(x -> x in [0, 1], col_data)
                invalid_count = count(x -> !(x in [0, 1]), col_data)
                add_error!(report, "range_validation", 
                          "Column '$binary_col' has $invalid_count values not in {0, 1}", location)
            end
        end
    end
    
    # Validate numeric columns
    validate_numeric_column(report, df_types, :fuel_price, location; required=false, positive=true)
    validate_numeric_column(report, df_types, :co2content, location; required=false, positive=true)
    
    for row in eachrow(df_types)
        if ismissing(row[:index])
            add_warning!(report, "incomplete_data", 
                        "Skipping type row with missing index", location)
            continue
        end
        
        if hasproperty(row, :color)
            params.plant_type2color[row[:index]] = row[:color]
        end
        
        if !ismissing(row[:dispatchable])
            row[:dispatchable] == 1 && push!(params.dispatchable, row[:index])
            row[:dispatchable] == 0 && push!(params.nondispatchable, row[:index])
        end
        
        if hasproperty(row, :prosumer) && !ismissing(row[:prosumer])
            row[:prosumer] == 1 && push!(params.prosumer_types, row[:index])
        end
        
        if hasproperty(row, :storage) && !ismissing(row[:storage])
            row[:storage] == 1 && push!(params.storage_types, row[:index])
        end
        
        if hasproperty(row, :color)
            params.colors[row[:index]] = row[:color]
        end

        if haskey(row, :fuel_price) && !ismissing(row[:fuel_price])
            params.fuel_price[row[:index]] = FixedProfile(row[:fuel_price])
        end

        if haskey(row, :co2content) && !ismissing(row[:co2content])
            params.co2content[row[:index]] = row[:co2content]
        end
    end
    
    add_note!(report, "data_summary", 
              "Loaded $(length(params.dispatchable) + length(params.nondispatchable)) plant types", location)
end

function add_types!(params::Parameters, path::AbstractString)
    report = DataReport()
    
    if !validate_file_exists(report, path, "types file")
        print_report(report)
        error("Cannot proceed without types file")
    end
    
    try
        df = read_csv(path)
        add_types!(params, df, report, path)
    catch e
        add_error!(report, "file_parsing", "Failed to parse file: $(string(e))", path)
        print_report(report)
        rethrow(e)
    end
    
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    return report
end

# Stub implementations for optional data functions
function add_lines!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "lines file")
        return
    end
    
    try
        df = read_csv(path)
        # Call original function
        add_lines!(params, df)
        add_note!(report, "data_summary", "Loaded lines data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse lines file: $(string(e))", location)
    end
end

function add_dclines!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "dclines file")
        return
    end
    
    try
        df = read_csv(path)
        # Call original function
        add_dclines!(params, df)
        add_note!(report, "data_summary", "Loaded DC lines data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse DC lines file: $(string(e))", location)
    end
end

function add_prs_demand!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "prosumer demand file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        # Call original function
        add_prs_demand!(params, df)
        add_note!(report, "data_summary", "Loaded prosumer demand data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse prosumer demand file: $(string(e))", location)
    end
end

function add_avail!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_path_exists(report, path, "availability file or directory")
        return
    end
    
    try
        # Call original function (handles both file and directory)
        add_avail!(params, path)
        add_note!(report, "data_summary", "Loaded availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse availability data: $(string(e))", location)
    end
end

function add_avail_planttype_nodal!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_path_exists(report, path, "nodal availability file or directory")
        return
    end
    
    try
        # Call original function (handles both file and directory)
        add_avail_planttype_nodal!(params, path)
        add_note!(report, "data_summary", "Loaded nodal plant type availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse nodal availability data: $(string(e))", location)
    end
end

function add_avail_planttype_zonal!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_path_exists(report, path, "zonal availability file or directory")
        return
    end
    
    try
        # Call original function (handles both file and directory)
        add_avail_planttype_zonal!(params, path)
        add_note!(report, "data_summary", "Loaded zonal plant type availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse zonal availability data: $(string(e))", location)
    end
end

function add_ntc!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "NTC file")
        return
    end
    
    try
        df = read_csv(path)
        # Call original function
        add_ntc!(params, df)
        add_note!(report, "data_summary", "Loaded NTC data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse NTC file: $(string(e))", location)
    end
end

function add_fixed_exchange!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "fixed exchange file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        # Call original function  
        add_fixed_exchange!(params, df)
        add_note!(report, "data_summary", "Loaded fixed exchange data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse fixed exchange file: $(string(e))", location)
    end
end

function add_inflow!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_path_exists(report, path, "inflow file or directory")
        return
    end
    
    try
        # Call original function (handles both file and directory)
        add_inflow!(params, path)
        add_note!(report, "data_summary", "Loaded inflow data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse inflow data: $(string(e))", location)
    end
end

function add_fuel_prices!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "fuel prices file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        # Call original function
        add_fuel_prices!(params, df)
        add_note!(report, "data_summary", "Loaded fuel prices data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse fuel prices file: $(string(e))", location)
    end
end

function add_historical_generation!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "historical generation file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        # Call original function
        add_historical_generation!(params, df)
        add_note!(report, "data_summary", "Loaded historical generation data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse historical generation file: $(string(e))", location)
    end
end

# Keep original function signatures for backward compatibility
function add_demand!(params::Parameters, df_demand::AbstractDataFrame)
    report = DataReport()
    add_demand!(params, df_demand, report, "demand DataFrame")
    if has_issues(report)
        @warn "Issues found while loading demand data:"
        print_report(report; show_notes=false)
    end
end

function add_types!(params::Parameters, df_types::AbstractDataFrame)
    report = DataReport()
    add_types!(params, df_types, report, "types DataFrame")
    if has_issues(report)
        @warn "Issues found while loading types data:"
        print_report(report; show_notes=false)
    end
end

function add_min_generation!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "minimum generation file")
        return
    end
    
    try
        df = read_csv(path)
        disallowmissing!(df)
        # Call original function
        add_min_generation!(params, df)
        add_note!(report, "data_summary", "Loaded minimum generation data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse minimum generation file: $(string(e))", location)
    end
end

function add_prs_demand!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_prs_demand!(params, df)
end

function add_prs_demand!(params::Parameters, df::AbstractDataFrame)
    stacked = "value" in names(df)

    if stacked
        df = unstack(df, 1, 2, :value)
        df = coalesce.(df, 0)
        select!(df, Not(names(df)[1]))
        disallowmissing!(df)
    end

    for col in pairs(eachcol(df))
        params.prs_demand[string(col[1])] = HourlyProfile(col[2])
    end
end

function add_avail!(params::Parameters, files::Vector{<:AbstractString})
    for file in files
        df = read_csv(file)
        add_avail!(params, df)
    end
end

function add_avail!(params::Parameters, path::AbstractString)
    if isfile(path)
        df = read_csv(path)
        add_avail!(params, df)
    else
        add_avail!(params, readdir(path, join = true))
    end
end

function add_avail!(params::Parameters, df_avail::AbstractDataFrame)
    for col in pairs(eachcol(df_avail))
        params.avail[string(col[1])] = HourlyProfile(col[2])
    end
end

function add_avail_planttype_nodal!(params::Parameters, path::AbstractString)
    if isfile(path)
        df = read_csv(path)
        add_avail_planttype_nodal!(params, df)
    else
        for file in readdir(path, join = true)
            df = read_csv(file)
            add_avail_planttype_nodal!(params, df)
        end
    end
end

function add_avail_planttype_nodal!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df[!, 2:end]))
        pt = first(df[!, 1])
        node = string(col[1])
        params.avail_planttype_nodal[pt, node] = HourlyProfile(Vector(col[2]))
    end
end

function add_avail_planttype_zonal!(params::Parameters, path::AbstractString)
    if isfile(path)
        df = read_csv(path)
        add_avail_planttype_zonal!(params, df)
    else
        for file in readdir(path, join = true)
            df = read_csv(file)
            add_avail_planttype_zonal!(params, df)
        end
    end
end

function add_avail_planttype_zonal!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df))
        zone = first(df[!, 1])
        plant_type = string(col[1])
        params.avail_planttype_zonal[plant_type, zone] = HourlyProfile(Vector(col[2]))
    end
end

function add_ntc!(params::Parameters, df_ntc::AbstractDataFrame)
    for row in eachrow(df_ntc)
        i, j = row[:zone_i], row[:zone_j]
        push!(params.sets.NTC, (i, j))
        params.ntc[i, j] = row[:ntc]
    end
end

function add_ntc!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_ntc!(params, df)
end

function add_inflow!(params::Parameters, df_inflow::AbstractDataFrame)
    for col in pairs(eachcol(df_inflow))
        params.inflow[string(col[1])] = HourlyProfile(col[2])
    end
end

function add_inflow!(params::Parameters, arr::Vector{<:AbstractString})
    for file in arr
        add_inflow!(params, file)
    end
end

function add_inflow!(params::Parameters, path::AbstractString)
    if isfile(path)
        df = read_csv(path)
        add_inflow!(params, df)
    else
        for file in readdir(path, join = true)
            df = read_csv(file)
            add_inflow!(params, df)
        end
    end
end

function add_fixed_exchange!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_fixed_exchange!(params, df)
end

function add_fixed_exchange!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df))
        params.fixed_exchange[string(col[1])] = HourlyProfile(Vector(col[2]))
    end
end

function add_fuel_prices!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_fuel_prices!(params, df)
end

function add_fuel_prices!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df))
        params.fuel_price[string(col[1])] = HourlyProfile(Vector(col[2]))
    end
end

function add_historical_generation!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_historical_generation!(params, df)
end

function add_historical_generation!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df))
        params.historical_generation[string(col[1])] = HourlyProfile(Vector(col[2]))
    end
end

function add_min_generation!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_min_generation!(params, df)
end

function add_min_generation!(params::Parameters, df::AbstractDataFrame)
    for col in pairs(eachcol(df))
        params.min_generation[string(col[1])] = HourlyProfile(Vector(col[2]))
    end
end


"""
    load_data_with_report(data::Dict)

Extended version of load_data that returns both Parameters and a DataReport.

# Usage
params, report = load_data_with_report(data_files)
"""
function load_data_with_report(data::Dict)
    params = Parameters()
    report = DataReport()
    
    # Check required keys
    required_keys = [:plants, :nodes, :zones, :demand, :types]
    missing_keys = [key for key in required_keys if !haskey(data, key)]
    
    if !isempty(missing_keys)
        add_error!(report, "missing_configuration", 
                  "Missing required data keys: $(join(missing_keys, ", "))", "data configuration")
        return params, report
    end
    
    # Load required data with validation
    try
        if isa(data[:plants], Vector)
            add_plants!(params, data[:plants], report, "plants")
        else
            add_plants!(params, data[:plants], report, data[:plants])
        end
        add_nodes!(params, data[:nodes], report, data[:nodes]) 
        add_zones!(params, data[:zones], report, data[:zones])
        add_demand!(params, data[:demand], report, data[:demand])
        add_types!(params, data[:types], report, data[:types])
    catch e
        add_error!(report, "critical_error", "Failed to load required data: $(string(e))", "core data loading")
        return params, report
    end
    
    # Load optional data with validation
    if haskey(data, :lines)
        try
            add_lines!(params, data[:lines], report, data[:lines])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load lines: $(string(e))", data[:lines])
        end
    end

    if haskey(data, :dclines)
        try
            add_dclines!(params, data[:dclines], report, data[:dclines])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load dclines: $(string(e))", data[:dclines])
        end
    end

    if haskey(data, :prs_demand)
        try
            add_prs_demand!(params, data[:prs_demand], report, data[:prs_demand])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load prosumer demand: $(string(e))", data[:prs_demand])
        end
    end

    if haskey(data, :avail)
        try
            add_avail!(params, data[:avail], report, data[:avail])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load availability: $(string(e))", data[:avail])
        end
    end

    if haskey(data, :avail_planttype_nodal)
        try
            add_avail_planttype_nodal!(params, data[:avail_planttype_nodal], report, data[:avail_planttype_nodal])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load nodal availability: $(string(e))", data[:avail_planttype_nodal])
        end
    end

    if haskey(data, :avail_planttype_zonal)
        try
            add_avail_planttype_zonal!(params, data[:avail_planttype_zonal], report, data[:avail_planttype_zonal])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load zonal availability: $(string(e))", data[:avail_planttype_zonal])
        end
    end

    if haskey(data, :ntc)
        try
            add_ntc!(params, data[:ntc], report, data[:ntc])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load NTC: $(string(e))", data[:ntc])
        end
    end

    if haskey(data, :fixed_exchange)
        try
            add_fixed_exchange!(params, data[:fixed_exchange], report, data[:fixed_exchange])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load fixed exchange: $(string(e))", data[:fixed_exchange])
        end
    end

    if haskey(data, :inflow)
        try
            add_inflow!(params, data[:inflow], report, data[:inflow])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load inflow: $(string(e))", data[:inflow])
        end
    end

    if haskey(data, :fuel_prices)
        try
            add_fuel_prices!(params, data[:fuel_prices], report, data[:fuel_prices])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load fuel prices: $(string(e))", data[:fuel_prices])
        end
    end

    if haskey(data, :historical_generation)
        try
            add_historical_generation!(params, data[:historical_generation], report, data[:historical_generation])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load historical generation: $(string(e))", data[:historical_generation])
        end
    end

    if haskey(data, :min_generation)
        try
            add_min_generation!(params, data[:min_generation], report, data[:min_generation])
        catch e
            add_warning!(report, "optional_data_error", "Failed to load min generation: $(string(e))", data[:min_generation])
        end
    end
    
    # Continue with post-processing only if no critical errors
    if !report.has_errors
        try
            # Validate network topology before attempting PTDF calculation
            if !isempty(params.sets.L)
                validate_network_topology(report, params, "network topology validation")
                
                # Only proceed with PTDF if no topology errors found
                if report.has_errors
                    add_note!(report, "processing_incomplete", 
                             "Skipping PTDF calculation due to network topology errors", "post-processing")
                    return params, report
                end
            end
            
            calc_h_b!(params, report)
            create_subsets!(params)
            create_mappers!(params)
            calc_mc!(params)
            map_avail_planttype!(params)
            haskey(data, :prs_demand) && calc_nodal_load_no_prs!(params)
            
            # Add completion note with warning count
            warning_count = length(get_warnings(report))
            if warning_count > 0
                add_note!(report, "processing_complete", 
                         "Data processing completed with $warning_count warning(s). Please review the warnings for potential issues.", "post-processing")
            else
                add_note!(report, "processing_complete", 
                         "Data processing completed successfully", "post-processing")
            end
        catch e
            add_error!(report, "post_processing_error", "Failed during post-processing: $(string(e))", "post-processing")
        end
    end

    return params, report
end

"""
    load_data(data::Dict)

Reads a collection of model input files specified by a dictionary and returns a fully populated `Parameters` struct for use in the market simulation.

# Arguments
- `data::Dict{Symbol, String}`: A dictionary mapping required and optional parameter names to file paths.

# Required keys
The following keys **must** be included in `data`:
- `:plants` - Plant specification file.
- `:nodes` - Node topology file.
- `:zones` - Zone definition file.
- `:demand` - Nodal or zonal demand input.
- `:types` - Technology or plant type definitions.

# Optional keys
These keys can optionally be included to enable extended model functionality:
- Network:
  - `:lines` - AC transmission line definitions.
  - `:dclines` - DC line definitions (requires `:lines` to be included).
- Availability and plant characteristics:
  - `:avail` -  Plant availability.
  - `:avail_planttype_nodal` - Availability by plant type and node.
  - `:avail_planttype_zonal` - Availability by plant type and zone.
  - `:min_generation` - Minimum generation constraints.
- Market and operation:
  - `:ntc` - Net Transfer Capacities between zones.
  - `:fixed_exchange` - Fixed exchange schedules.
  - `:prs_demand` - Prosumer demand profiles.
  - `:fuel_prices` - Time-dependent fuel prices.
  - `:inflow` - Storage inflow data (e.g. hydro).
  - `:historical_generation` - Historical generation for calibration.

!!! danger "Optional Keys"
    Some model features (e.g. redispatch or zonal availability mapping) depend on optional keys. Omitting them may disable those capabilities. The functionallity of optional file inputs and keys is currently not included in automated testing.
--- 

# Example

```julia
data = Dict(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)

params = load_data(data)
```
"""
function load_data(data::Dict)
    params, report = load_data_with_report(data)
    
    # Print warnings and errors, but allow execution to continue for backward compatibility
    if has_issues(report)
        print_report(report; show_notes=false)
    end
    
    # Only throw error if there are critical errors that prevent functioning
    if report.has_errors
        error("Data loading failed with critical errors. Use load_data_with_report() for detailed error information.")
    end
    
    return params
end

"""
    validate_params(params::Parameters)

Validate a Parameters object for common issues, particularly network topology problems.
Returns a DataReport with detailed diagnostics.

# Example
```julia
params = load_data(data_files)
report = validate_params(params)
print_report(report)
```
"""
function validate_params(params::Parameters)
    report = DataReport()
    
    # Validate basic data presence
    if isempty(params.sets.N)
        add_error!(report, "missing_data", "No nodes defined", "basic validation")
    end
    
    if isempty(params.sets.Z)
        add_error!(report, "missing_data", "No zones defined", "basic validation")
    end
    
    if isempty(params.sets.P)
        add_error!(report, "missing_data", "No plants defined", "basic validation")
    end
    
    # Validate network topology if lines are defined
    if !isempty(params.sets.L)
        validate_network_topology(report, params, "network topology")
    else
        add_note!(report, "validation_info", "No transmission lines defined - operating in copper plate mode", "network validation")
    end
    
    # Validate slack bus presence
    if isempty(params.slack)
        add_error!(report, "missing_data", "No slack bus defined", "slack bus validation")
    end
    
    return report
end

"""
    validate_params(params::Parameters, setup::ModelSetup)

Extended validation that additionally checks time-series lengths against the configured TimeHorizon
and validates node consistency for nodal availability and nodal load.

Returns a DataReport containing any errors, warnings, and notes.
"""
function validate_params(params::Parameters, setup::ModelSetup)
    # Start with the base validations
    report = validate_params(params)

    # 1) Time horizon length checks (row count vs TimeHorizon.stop)
    stop_val = setup.TimeHorizon.stop

    # Helper to get apparent length of a Profile (FixedProfile -> 1)
    _plen(p) = p isa HourlyProfile ? length(p.val) : 1

    # Demand (nodal_load)
    for (n, prof) in params.nodal_load
        len = _plen(prof)
        if prof isa HourlyProfile && len < stop_val
            add_error!(report, "timeseries_length_mismatch", "Nodal demand at node '" * n * "' has length $(len) but TimeHorizon.stop=$(stop_val)", "validate_params")
        elseif prof isa HourlyProfile && len > stop_val
            add_warning!(report, "timeseries_length_excess", "Nodal demand at node '" * n * "' has length $(len) exceeding TimeHorizon.stop=$(stop_val); excess data will be ignored", "validate_params")
        end
    end

    # Availability per plant (covers prosumer availability as well)
    for (p, prof) in params.avail
        len = _plen(prof)
        if prof isa HourlyProfile && len < stop_val
            add_error!(report, "timeseries_length_mismatch", "Availability for plant '" * p * "' has length $(len) but TimeHorizon.stop=$(stop_val)", "validate_params")
        elseif prof isa HourlyProfile && len > stop_val
            add_warning!(report, "timeseries_length_excess", "Availability for plant '" * p * "' has length $(len) exceeding TimeHorizon.stop=$(stop_val); excess data will be ignored", "validate_params")
        end
    end

    # Inflow
    for (k, prof) in params.inflow
        len = _plen(prof)
        if prof isa HourlyProfile && len < stop_val
            add_error!(report, "timeseries_length_mismatch", "Inflow series '" * k * "' has length $(len) but TimeHorizon.stop=$(stop_val)", "validate_params")
        elseif prof isa HourlyProfile && len > stop_val
            add_warning!(report, "timeseries_length_excess", "Inflow series '" * k * "' has length $(len) exceeding TimeHorizon.stop=$(stop_val); excess data will be ignored", "validate_params")
        end
    end

    # 2) Node existence checks for nodal availability and nodal demand
    # 2a) Nodal availability: nodes referenced must exist
    if !isempty(params.avail_planttype_nodal)
        nodes_in_avail = unique(last.(collect(keys(params.avail_planttype_nodal))))
        for n in nodes_in_avail
            if !(n in params.sets.N)
                add_error!(report, "unknown_node_in_availability", "Node '" * n * "' appears in nodal availability but is not defined in nodes set", "validate_params")
            end
        end
        # Warn for nodes that exist but have no nodal availability mapping
        nodes_without_avail = setdiff(params.sets.N, nodes_in_avail)
        for n in nodes_without_avail
            add_warning!(report, "node_missing_availability", "Node '" * n * "' has no nodal availability mapping", "validate_params")
        end
    else
        add_note!(report, "nodal_availability_absent", "No nodal availability data present", "validate_params")
    end

    # 2b) Nodal demand: keys must be valid nodes, and warn for missing nodes
    if !isempty(params.nodal_load)
        for n in keys(params.nodal_load)
            if !(n in params.sets.N)
                add_error!(report, "unknown_node_in_demand", "Node '" * n * "' appears in nodal demand but is not defined in nodes set", "validate_params")
            end
        end
        nodes_without_demand = setdiff(params.sets.N, collect(keys(params.nodal_load)))
        for n in nodes_without_demand
            add_warning!(report, "node_missing_demand", "Node '" * n * "' has no nodal demand entry", "validate_params")
        end
    else
        add_note!(report, "nodal_demand_absent", "No nodal demand data present", "validate_params")
    end

    return report
end