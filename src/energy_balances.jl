
function create_energybalance(sr::SubRun{MT,MS}) where {MT<:MarketType,MS<:MarketState}
    add_disp_generators(sr)
    add_ndisp_generators(sr)
    add_storage(sr)
    add_network(sr)
    add_prosumer(sr, sr.modelrun.setup.ProsumerSetup)
    link_components(sr)
end

function create_energybalance(sr::SubRun{MT,MS}) where {MT<:MarketType,MS<:Redispatch}
    add_disp_generators(sr)
    add_ndisp_generators(sr)
    add_storage(sr)
    add_network(sr)
    add_prosumer(sr, sr.modelrun.setup.ProsumerSetup)
    link_components(sr)
end

function create_energybalance(
    sr::SubRun{MT,MS},
) where {MT<:MarketType,MS<:ProsumerOptimizationState}
    add_prosumer(sr, sr.modelrun.setup.ProsumerSetup)
end

function link_components(sr::SubRun{MT,MS}) where {MT<:ZonalMarketType,MS<:DayAhead}
    @unpack DISP, NDISP, Z, PRS  = sr.modelrun.params.sets
    @unpack plants_in_zone, nodes_in_zone, storages_in_zone, nodal_load, prs_demand  = sr.modelrun.params
    T = sr.market_state.Time
    m = sr.optigraph
    balance = sr.balance

    infeas_cost = 1000
    has_prs = !(sr.modelrun.setup.ProsumerSetup isa NoProsumer)

    @variable(balance, 0 <= CU[Z, T])
    @variable(balance, 0 <= LL[Z, T])
    @objective(balance, Min, infeas_cost * sum(CU[z, t] + LL[z, t] for z in Z, t in T))

    df_zonalmarketbalance(sr.results)


    @linkconstraint(
        m,
        ZonalMarketBalance[z = Z, t = T],
        sum(sr.disp[:GEN][p, t] for p in intersect(DISP, plants_in_zone[z])) +
        sum(sr.ndisp[:FEEDIN][p, t] for p in intersect(NDISP, plants_in_zone[z])) +
        sum(sr.sto[:GEN][s, t] - sr.sto[:CHARGE][s, t] for s in storages_in_zone[z]) +
        sr.network[:EXCHANGE][z, t] - balance[:CU][z, t] ==
        sum(nodal_load[z][t] for z in nodes_in_zone[z] if haskey(nodal_load, z)) -
        balance[:LL][z, t]
                   + (has_prs ?
            sum(
                prs_demand[prs][t] for
                prs in intersect(PRS, plants_in_zone[z]);
                init = 0,
            ) : 0
    )
    )

    for z in Z, t in T
        push!(
            sr.results[:ZonalMarketBalance],
            (
                Time = t,
                Zone = z,
                MarketBalance = ZonalMarketBalance[z, t],
                CU = CU[z, t],
                LL = LL[z, t],
            ),
        )

    end

    return m
end


function link_components(sr::SubRun{MT,MS}) where {MT<:NodalMarketType,MS<:DayAhead}
    @unpack DISP, NDISP, N, PRS = sr.modelrun.params.sets
    @unpack plants_in_node, storages_in_node, nodal_load, prs_demand = sr.modelrun.params
    T = sr.market_state.Time
    m = sr.optigraph
    balance = sr.balance

    infeas_cost = 1000
    has_prs = !(sr.modelrun.setup.ProsumerSetup isa NoProsumer)

    @variable(balance, 0 <= CU[N, T])
    @variable(balance, 0 <= LL[N, T])
    @objective(balance, Min, infeas_cost * sum(CU[n, t] + LL[n, t] for n in N, t in T))

    @linkconstraint(
        m,
        NodalMarketBalance[n = N, t = T],
        sum(sr.disp[:GEN][p, t] for p in intersect(DISP, plants_in_node[n])) +
        sum(sr.ndisp[:FEEDIN][p, t] for p in intersect(NDISP, plants_in_node[n])) +
        sum(sr.sto[:GEN][s, t] - sr.sto[:CHARGE][s, t] for s in storages_in_node[n]) +
        sr.network[:NETINPUT][n, t] - balance[:CU][n, t] ==
        nodal_load[n][t] - balance[:LL][n, t]
           + (has_prs ?
            sum(
                prs_demand[prs][t] for
                prs in intersect(PRS, plants_in_node[n]);
                init = 0,
            ) : 0
    )
    )

    df_nodalmarketbalance(sr.results)

    for n in N, t in T
        push!(
            sr.results[:NodalMarketBalance],
            (
                Time = t,
                Node = n,
                MarketBalance = NodalMarketBalance[n, t],
                CU = CU[n, t],
                LL = LL[n, t],
            ),
        )
    end

    return m
end


function link_components(
    sr::SubRun{MT,MS},
) where {MT<:Union{ZonalMarketWithRedispatch,NodalMarketWithRedispatch},MS<:Redispatch}
    @unpack DISP, NDISP, N, PRS = sr.modelrun.params.sets
    @unpack plants_in_node, storages_in_node, nodal_load, prs_demand = sr.modelrun.params
    params = sr.modelrun.params
    T = sr.market_state.Time
    m = sr.optigraph
    balance = sr.balance

    infeas_cost = 1000

    has_prs = !(sr.modelrun.setup.ProsumerSetup isa NoProsumer)

    if has_prs
        NDISP = setdiff(NDISP, PRS)
    end
    #     load = params.nodal_load #params.nodal_load_no_prs
    # else
    #     load = params.nodal_load
    # end

    @variable(balance, 0 <= CU[N, T])
    @variable(balance, 0 <= LL[N, T])
    @objective(balance, Min, infeas_cost * sum(CU[n, t] + LL[n, t] for n in N, t in T))

    @linkconstraint(
        m,
        NodalMarketBalance[n = N, t = T],
        sum(sr.disp[:GEN_REDISP][p, t] for p in intersect(DISP, plants_in_node[n])) +
        sum(
            sr.sto[:GEN_REDISP][s, t] - sr.sto[:CHARGE_REDISP][s, t] for
            s in storages_in_node[n]
        ) +
        sum(sr.ndisp[:FEEDIN_REDISP][p, t] for p in intersect(NDISP, plants_in_node[n])) +
        (
            has_prs ?
            sum(
                sr.prosumer[:PRS_NETINPUT][prs, t] for
                prs in intersect(PRS, plants_in_node[n]);
                init = 0,
            ) : 0
        ) +
        sr.network[:NETINPUT][n, t] - balance[:CU][n, t] == params.nodal_load[n][t] - balance[:LL][n, t]
    )

    df_nodalmarketredispbalance(sr.results)

    for n in N, t in T
        push!(
            sr.results[:NodalMarketRedispBalance],
            (
                Time = t,
                Node = n,
                MarketBalance = NodalMarketBalance[n, t],
                CU = CU[n, t],
                LL = LL[n, t],
            ),
        )
    end

    return m
end
