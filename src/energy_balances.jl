"""
    create_energybalance(sr::SubRun{MT,MS}) where {MT<:MarketType,MS<:MarketState}

Creates the energy balance equations for a given market and market state.
Adds generators, storage, network, prosumer components, and links all components for the optimization graph.
"""
function create_energybalance(sr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <: RedispatchSetup, MS<:MarketState}
    add_disp_generators(sr)
    add_ndisp_generators(sr)
    add_storage(sr)
    add_network(sr)
    add_prosumer(sr)
    link_components(sr)
end



"""
    create_energybalance(sr::SubRun{MT,MS}) where {MT<:MarketType,MS<:ProsumerOptimizationState}

Creates the energy balance equations for the prosumer optimization state.
Adds only the prosumer components for the optimization graph.
"""
function create_energybalance(
    sr::SubRun{MT,PS,RD,MS},
) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup, MS<:ProsumerOptimizationState}
    add_prosumer(sr)
end

"""
    link_components(sr::SubRun{MT,MS}) where {MT<:ZonalMarketType,MS<:DayAhead}

Links all components for a zonal market in the day-ahead market state.
Defines variables, objectives, and constraints for zonal market balance.
Stores results in the :ZonalMarketBalance DataFrame.

Uses the new unified balance framework for improved maintainability.
"""
function link_components(sr::SubRun{MT,PS, RD, MS}) where {MT<:ZonalMarketType,PS <: ProsumerSetup, RD <: RedispatchSetup,MS<:DayAhead}
    # Use unified balance framework with zonal scope
    return create_unified_balance!(sr, market_scope(MT))
end

"""
    link_components(sr::SubRun{MT,MS}) where {MT<:NodalMarketType,MS<:DayAhead}

Links all components for a nodal market in the day-ahead market state.
Defines variables, objectives, and constraints for nodal market balance.
Stores results in the :NodalMarketBalance DataFrame.

Uses the new unified balance framework for improved maintainability.
"""
function link_components(sr::SubRun{MT,PS, RD,MS}) where {MT<:NodalMarketType,PS <: ProsumerSetup, RD <:RedispatchSetup,MS<:DayAhead}
    # Use unified balance framework with nodal scope
    return create_unified_balance!(sr, market_scope(MT))
end

"""
    link_components(sr::SubRun{MT,MS}) where {MT<:Union{ZonalMarketWithRedispatch,NodalMarketWithRedispatch},MS<:Redispatch}

Links all components for zonal or nodal market with redispatch in the redispatch market state.
Defines variables, objectives, and constraints for nodal market redispatch balance.
Stores results in the :NodalMarketRedispBalance DataFrame.
"""
function link_components( sr::SubRun{MT,PS, RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup,RD <: RedispatchSetup,MS<:Redispatch}
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
