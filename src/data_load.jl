calc_gmax(params::Parameters, p::String, t::Int) = params.avail[p][t] * params.gmax[p]

function add_plants!(params::Parameters, df_pp::AbstractDataFrame)
    for row in eachrow(df_pp)
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
end



function add_plants!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_plants!(params, df)
end

function add_plants!(params::Parameters, files::Vector{<:AbstractString})
    for file in files
        df = read_csv(file)
        add_plants!(params, df)
    end
end

function add_nodes!(params::Parameters, df_nodes::AbstractDataFrame)
    for row in eachrow(df_nodes)
        push!(params.sets.N, row[:index])
        row[:slack] == 1 && push!(params.slack, row[:index])
        params.node2zone[row[:index]] = row[:zone]
        if "lat" in names(row) && "lon" in names(row)
            params.node_coords[row[:index]] = [row[:lon], row[:lat]]
        elseif "latitude" in names(row) && "longitude" in names(row)
            params.node_coords[row[:index]] = [row[:longitude], row[:latitude]]
        else
            params.node_coords[row[:index]] = [0.0, 0.0]
        end
    end
end
function add_nodes!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_nodes!(params, df)
end

function add_zones!(params::Parameters, df_zones::AbstractDataFrame)
    for row in eachrow(df_zones)
        push!(params.sets.Z, row[:index])
    end
end

function add_zones!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_zones!(params, df)
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

function add_demand!(params::Parameters, df_demand::AbstractDataFrame)

    stacked = "value" in names(df_demand)

    if stacked
        df_demand = unstack(df_demand, 1, 2, :value)
        df_demand = coalesce.(df_demand, 0)
    end

    s = names(df_demand)[1] in ["Hour", "index"] ? 2 : 1
    for col in pairs(eachcol(df_demand[!, s:end]))
        params.nodal_load[string(col[1])] = HourlyProfile(Vector(col[2]))
    end

    for n in setdiff(params.sets.N, keys(params.nodal_load))
        params.nodal_load[n] = FixedProfile(0)
    end
end

function add_demand!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    disallowmissing!(df)
    return add_demand!(params, df)
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

function add_types!(params::Parameters, df_types::AbstractDataFrame)
    for row in eachrow(df_types)
        params.plant_type2color[row[:index]] = row[:color]
        row[:dispatchable] == 1 && push!(params.dispatchable, row[:index])
        row[:dispatchable] == 0 && push!(params.nondispatchable, row[:index])
        row[:prosumer] == 1 && push!(params.prosumer_types, row[:index])
        row[:storage] == 1 && push!(params.storage_types, row[:index])
        params.colors[row[:index]] = row[:color]

        if haskey(row, :fuel_price)
            params.fuel_price[row[:index]] = FixedProfile(row[:fuel_price])
        end

        if haskey(row, :co2content)
            params.co2content[row[:index]] = row[:co2content]
        end
    end
end

function add_types!(params::Parameters, path::AbstractString)
    df = read_csv(path)
    return add_types!(params, df)
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
"""
function load_data(data::Dict)

    params = Parameters()
    add_plants!(params, data[:plants])
    add_nodes!(params, data[:nodes])
    add_zones!(params, data[:zones])
    add_demand!(params, data[:demand])
    add_types!(params, data[:types])

    if haskey(data, :lines)
    add_lines!(params, data[:lines])
    end

    if haskey(data, :dclines)
        add_lines!(params, data[:dclines])
    end

    if haskey(data, :prs_demand)
        add_prs_demand!(params, data[:prs_demand])
    end

    if haskey(data, :avail)
        add_avail!(params, data[:avail])
    end

    if haskey(data, :avail_planttype_nodal)
        add_avail_planttype_nodal!(params, data[:avail_planttype_nodal])
    end

    if haskey(data, :avail_planttype_zonal)
        add_avail_planttype_zonal!(params, data[:avail_planttype_zonal])
    end


    if haskey(data, :ntc)
        add_ntc!(params, data[:ntc])
    end

    if haskey(data, :fixed_exchange)
        add_fixed_exchange!(params, data[:fixed_exchange])
    end

    if haskey(data, :inflow)
        add_inflow!(params, data[:inflow])
    end

    if haskey(data, :fuel_prices)
        add_fuel_prices!(params, data[:fuel_prices])
    end

    if haskey(data, :historical_generation)
        add_historical_generation!(params, data[:historical_generation])
    end

    if haskey(data, :min_generation)
        add_min_generation!(params, data[:min_generation])
    end

    calc_h_b!(params)
    create_subsets!(params)
    create_mappers!(params)

    calc_mc!(params)
    map_avail_planttype!(params)
    haskey(data, :prs_demand) && calc_nodal_load_no_prs!(params)

    sanity_checks(params)

    return params
end

function calc_h_b!(params)
    @unpack N, L, DC = params.sets
    @unpack line_start, line_end, dc_start, dc_end, reactance, resistance = params

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

    for l in eachindex(L), n in eachindex(N)
        params.h[(L[l], N[n])] = h[l, n]
    end

    for n in eachindex(N), m in eachindex(N)
        params.b[(N[n], N[m])] = b[n, m]
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
