calc_gmax(params::Parameters, p::String, t::Int) = params.avail[p][t] * params.gmax[p]

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

        storage_param_exist =
            !ismissing(row[:storage_capacity]) && !ismissing(row[:storage_power])

        if storage_param_exist
            params.storage[row[:index]] = row[:storage_capacity]
            params.gmax_storage[row[:index]] = row[:storage_power]
        end

        if haskey(row, :mc)
            if row[:mc] isa Number
                params.mc[row[:index]] = FixedProfile(row[:mc])
            end
            # else
            #     params.mc[row[:index]] = FixedProfile(0)
        end

        if haskey(row, :availability)
            if row[:availability] isa Number
                params.avail[row[:index]] = FixedProfile(row[:availability])
            end
            # else
            #     params.avail[row[:index]] = FixedProfile(1)
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

        trm = 1
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
    if !validate_required_columns(report, df_demand, [], location)  # No strict requirements, but check structure
        add_note!(report, "validation_info", "Demand data structure check completed", location)
    end
    
    stacked = "value" in names(df_demand)

    if stacked
        df_demand = unstack(df_demand, 1, 2, :value)
        df_demand = coalesce.(df_demand, 0)
    end

    s = names(df_demand)[1] in ["Hour", "index"] ? 2 : 1
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
    if !validate_file_exists(report, path, "availability file")
        return
    end
    
    try
        # Call original function
        add_avail!(params, path)
        add_note!(report, "data_summary", "Loaded availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse availability file: $(string(e))", location)
    end
end

function add_avail_planttype_nodal!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "nodal availability file")
        return
    end
    
    try
        # Call original function
        add_avail_planttype_nodal!(params, path)
        add_note!(report, "data_summary", "Loaded nodal plant type availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse nodal availability file: $(string(e))", location)
    end
end

function add_avail_planttype_zonal!(params::Parameters, path::AbstractString, report::DataReport, location::String)
    if !validate_file_exists(report, path, "zonal availability file")
        return
    end
    
    try
        # Call original function
        add_avail_planttype_zonal!(params, path)
        add_note!(report, "data_summary", "Loaded zonal plant type availability data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse zonal availability file: $(string(e))", location)
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
    if !validate_file_exists(report, path, "inflow file")
        return
    end
    
    try
        # Call original function
        add_inflow!(params, path)
        add_note!(report, "data_summary", "Loaded inflow data", location)
    catch e
        add_error!(report, "file_parsing", "Failed to parse inflow file: $(string(e))", location)
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
"""
    load_data(data::Dict{Symbol, String})

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

!!! note
    Some advanced model features (e.g. redispatch or zonal availability mapping) depend on optional keys. Omitting them may disable those capabilities.

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
# Extended version of load_data that returns both Parameters and a DataReport
# Usage: params, report = load_data_with_report(data_files)
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
        add_plants!(params, data[:plants], report, data[:plants])
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
            calc_h_b!(params)
            create_subsets!(params)
            create_mappers!(params)
            calc_mc!(params)
            map_avail_planttype!(params)
            haskey(data, :prs_demand) && calc_nodal_load_no_prs!(params)
            sanity_checks(params)
            add_note!(report, "processing_complete", "Data processing completed successfully", "post-processing")
        catch e
            add_error!(report, "post_processing_error", "Failed during post-processing: $(string(e))", "post-processing")
        end
    end

    return params, report
end

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
end

function calc_h_b!(params)
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

    calc_PTDF!(h, b, slack, N, L, params)

    for l in eachindex(L), n in eachindex(N)
        params.h[(L[l], N[n])] = h[l, n]
    end

    for n in eachindex(N), m in eachindex(N)
        params.b[(N[n], N[m])] = b[n, m]
    end

end
function calc_PTDF!(h::Matrix{Float64}, b::Matrix{Float64}, slack_list::Vector{String}, N::Vector{String}, L::Vector{String}, params::Parameters)

    # Indexpositionen der Slack-Busse in N finden
    slack_idx = findall(n -> n in slack_list, N)

    if isempty(slack_idx)
        error("No slack buses found in params.slack")
    end

    if length(slack_list) > 1
        @warn "Multiple slack buses found."
    end

    # Indizes der Nicht-Slack-Knoten
    non_slack = setdiff(1:length(N), slack_idx)

    # Reduzierte B-Matrix erzeugen
    b_red = b[non_slack, non_slack]

    # Invertiere reduzierte Matrix
    b_red_inv = inv(b_red)

    # Erzeuge vollständige Inverse mit eingebetteter B⁻¹
    b_inv_full = zeros(length(N), length(N))
    b_inv_full[non_slack, non_slack] .= b_red_inv

    # PTDF = H * B⁻¹
    ptdf = h * b_inv_full

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

function sanity_checks(params::Parameters)

    each_prs_has_avail = !any(params.sets.PRS) do prs
        haskey(params.avail, prs)
    end

    if !each_prs_has_avail
        @warn "Not all prosumers have an availability profile!"
    end

    each_storage_has_gmax_and_capacity = !any(params.sets.S) do s
        haskey(params.gmax_storage, s) && haskey(params.storage, s)
    end

    if !each_storage_has_gmax_and_capacity
        @warn "Not all storage units have a capacity and a maximum power!"
    end

end  # function sanity_checks
