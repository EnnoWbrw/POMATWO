"""
    unified_balance.jl

Provides a unified framework for creating energy balance equations
across different market types and configurations.
"""

"""
    create_unified_balance!(sr::SubRun, market_scope::MarketScope, market_state::MarketState)

Creates energy balance equations using a unified framework that works across
zonal and nodal markets, with or without prosumers.

This replaces the multiple specialized link_components functions with a single
parameterized implementation that dispatches on traits.
"""
function create_unified_balance!(
    sr::SubRun{MT,PS,RD,MS},
    market_scope::MarketScope,
) where {MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup, MS<:DayAhead}
    
    params = sr.modelrun.params
    T = sr.market_state.Time
    m = sr.optigraph
    balance = sr.balance
    
    # Get spatial units based on market scope
    spatial_units = balance_spatial_unit(market_scope, params)
    unit_name = balance_unit_name(market_scope)
    
    # Model parameters
    infeas_cost = 1000
    has_prs = !(sr.modelrun.setup.ProsumerSetup isa NoProsumer)
    
    # Create slack variables for infeasibility
    @variable(balance, 0 <= CU[spatial_units, T])
    @variable(balance, 0 <= LL[spatial_units, T])
    @objective(balance, Min, infeas_cost * sum(CU[u, t] + LL[u, t] for u in spatial_units, t in T))
    
    # Create balance equation
    create_balance_constraint!(sr, market_scope, spatial_units, T, has_prs)
    
    # Store results
    result_key = market_scope isa ZonalScope ? :ZonalMarketBalance : :NodalMarketBalance
    create_balance_results_df!(sr.results, result_key)
    
    constraint_ref = market_scope isa ZonalScope ? :ZonalMarketBalance : :NodalMarketBalance
    
    for u in spatial_units, t in T
        row = (
            Time = t,
            MarketBalance = m[constraint_ref][u, t],
            CU = CU[u, t],
            LL = LL[u, t],
        )
        
        # Add unit identifier (Zone or Node)
        row = merge((; zip([unit_name], [u])...), row)
        push!(sr.results[result_key], row)
    end
    
    return m
end

"""
    create_balance_constraint!(sr, market_scope, spatial_units, T, has_prs)

Creates the actual balance constraint based on market scope.
"""
function create_balance_constraint!(
    sr::SubRun,
    scope::ZonalScope,
    zones,
    T,
    has_prs,
)
    @unpack DISP, NDISP, PRS = sr.modelrun.params.sets
    @unpack plants_in_zone, nodes_in_zone, storages_in_zone, nodal_load, prs_demand = sr.modelrun.params
    m = sr.optigraph
    balance = sr.balance
    
    @linkconstraint(
        m,
        ZonalMarketBalance[z = zones, t = T],
        sum(sr.disp[:GEN][p, t] for p in intersect(DISP, plants_in_zone[z])) +
        sum(sr.ndisp[:FEEDIN][p, t] for p in intersect(NDISP, plants_in_zone[z])) +
        sum(sr.sto[:GEN][s, t] - sr.sto[:CHARGE][s, t] for s in storages_in_zone[z]) +
        network_injection_expr(scope, sr, z, t) - 
        balance[:CU][z, t] ==
        sum(nodal_load[n][t] for n in nodes_in_zone[z] if haskey(nodal_load, n)) -
        balance[:LL][z, t] +
        (has_prs ? sum(prs_demand[prs][t] for prs in intersect(PRS, plants_in_zone[z]); init = 0) : 0)
    )
end

function create_balance_constraint!(
    sr::SubRun,
    scope::NodalScope,
    nodes,
    T,
    has_prs,
)
    @unpack DISP, NDISP, PRS = sr.modelrun.params.sets
    @unpack plants_in_node, storages_in_node, nodal_load, prs_demand = sr.modelrun.params
    m = sr.optigraph
    balance = sr.balance
    
    @linkconstraint(
        m,
        NodalMarketBalance[n = nodes, t = T],
        sum(sr.disp[:GEN][p, t] for p in intersect(DISP, plants_in_node[n])) +
        sum(sr.ndisp[:FEEDIN][p, t] for p in intersect(NDISP, plants_in_node[n])) +
        sum(sr.sto[:GEN][s, t] - sr.sto[:CHARGE][s, t] for s in storages_in_node[n]) +
        network_injection_expr(scope, sr, n, t) - 
        balance[:CU][n, t] ==
        nodal_load[n][t] - balance[:LL][n, t] +
        (has_prs ? sum(prs_demand[prs][t] for prs in intersect(PRS, plants_in_node[n]); init = 0) : 0)
    )
end

"""
    create_balance_results_df!(results, key)

Creates the appropriate DataFrame structure for balance results.
"""
function create_balance_results_df!(results, ::Symbol)
    # Delegates to existing df_* functions
    if !haskey(results, :ZonalMarketBalance)
        df_zonalmarketbalance(results)
    end
    if !haskey(results, :NodalMarketBalance)
        df_nodalmarketbalance(results)
    end
end
