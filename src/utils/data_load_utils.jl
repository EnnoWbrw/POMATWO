
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