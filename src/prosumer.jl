
function df_prosumer(dict)
    if !haskey(dict, :PRS)
        dict[:PRS] = DataFrame(;
            index = String[],
            Time = Int[],
            PRS_TOTAL_GEN = AffExpr[],
            PRS_SELF = VariableRef[],
            PRS_CU = AffOrVarOrFloatOrInt[],
            PRS_NETINPUT = AffOrVarOrFloatOrInt[],
            PRS_STO_LVL = AffOrVarOrFloatOrInt[],
            PRS_STO_OUT = AffOrVarOrFloatOrInt[],
            PRS_STO_IN = AffOrVarOrFloatOrInt[],
            PRS_BUY = VariableRef[],
            PRS_SELL = VariableRef[],
            INF = VariableRef[],
        )
    end
end

function add_prosumer(
    sr::SubRun{MT,MS},
    po::NoProsumer,
) where {MT<:MarketType,MS<:Union{ProsumerOptimizationState}}

    return nothing
end

function add_prosumer(
    sr::SubRun{MT,MS},
    po::ProsumerSetup,
) where {MT<:MarketType,MS<:DayAhead}

    return nothing
end

function add_prosumer(
    sr::SubRun{MT,MS},
    po::NoProsumer,
) where {MT<:MarketType,MS<:Redispatch}
    return nothing
end

function add_prosumer(
    sr::SubRun{MT,MS},
    po::ProsumerSetup,
) where {MT<:MarketType,MS<:Redispatch}


    @unpack PRS = sr.modelrun.params.sets
    T = sr.market_state.Time
    prev_result = sr.market_state.da_market_result[:prs_netinput]

    @expression(sr.prosumer, PRS_NETINPUT[prs = PRS, t = T], prev_result[prs, t])
end

function add_prosumer(
    sr::SubRun{MT,MS},
    po::ProsumerSetup,
) where {MT<:MarketType,MS<:ProsumerOptimizationState}

    T = sr.market_state.Time
    @unpack PRS, PRS_STO = sr.modelrun.params.sets
    @unpack gmax, gmax_storage, storage, prs_demand, avail = sr.modelrun.params
    m = sr.prosumer

    generation = Dict((prs, t) => gmax[prs] * avail[prs][t] for prs in PRS, t in T)


    @variable(m, 0 <= PRS_STO_OUT[prs = PRS_STO, t = T] <= gmax_storage[prs])
    @variable(m, 0 <= PRS_STO_IN[prs = PRS_STO, t = T] <= gmax_storage[prs])
    @variable(m, 0 <= PRS_STO_LVL[prs = PRS_STO, t = T] <= storage[prs])
    @variable(m, 0 <= PRS_BUY[prs = PRS, t = T] <= prs_demand[prs][t])
    @variable(m, 0 <= PRS_SELL[prs = PRS, t = T] <= generation[prs, t])
    @variable(m, 0 <= INF[prs = PRS, t = T])
    @variable(m, 0 <= PRS_SELF[prs = PRS, t = T])
    @variable(m, 0 <= PRS_CU[prs = PRS, t = T])

    @expression(m, PRS_TOTAL_GEN[prs = PRS, t = T], generation[prs, t] - PRS_CU[prs, t])

    @expression(m, PRS_NETINPUT[prs = PRS, t = T], PRS_SELL[prs, t] - PRS_BUY[prs, t])

    @constraint(
        m,
        GenerationBalance[prs = PRS, t = T],
        PRS_TOTAL_GEN[prs, t] ==
        PRS_SELF[prs, t] + PRS_SELL[prs, t] + (prs in PRS_STO ? PRS_STO_IN[prs, t] : 0)
    )

    @constraint(
        m,
        StorageBalance[prs = PRS_STO, t = T],
        PRS_STO_LVL[prs, t] ==
        0.999 * PRS_STO_LVL[prs, prev_period(T, t)] + 0.9 * PRS_STO_IN[prs, t] #todo: should be eta in the future
        -
        PRS_STO_OUT[prs, t] / 0.9
    )

    @constraint(
        m,
        EnergyBalance[prs = PRS, t = T],
        PRS_SELF[prs, t] + (prs in PRS_STO ? PRS_STO_OUT[prs, t] : 0) + PRS_BUY[prs, t] ==
        prs_demand[prs][t]
    )

    add_prosumer_objective(sr, po)

    df_prosumer(sr.results)

    for prs in PRS, t in T
        push!(
            sr.results[:PRS],
            (
                index = prs,
                Time = t,
                PRS_TOTAL_GEN = PRS_TOTAL_GEN[prs, t],
                PRS_SELF = PRS_SELF[prs, t],
                PRS_CU = PRS_CU[prs, t],
                PRS_NETINPUT = PRS_NETINPUT[prs, t],
                PRS_STO_LVL = (prs in PRS_STO ? PRS_STO_LVL[prs, t] : 0),
                PRS_STO_OUT = (prs in PRS_STO ? PRS_STO_OUT[prs, t] : 0),
                PRS_STO_IN = (prs in PRS_STO ? PRS_STO_IN[prs, t] : 0),
                PRS_BUY = PRS_BUY[prs, t],
                PRS_SELL = PRS_SELL[prs, t],
                INF = INF[prs, t],
            ),
        )

    end

    return m
end


function add_prosumer_objective(
    sr::SubRun{MT,MS},
    po::ProsumerOptimization,
) where {MT<:MarketType,MS<:ProsumerOptimizationState}
    @unpack PRS, PRS_STO = sr.modelrun.params.sets
    m = sr.prosumer

    T = sr.market_state.Time
    if po.retail_type == :buy_price
        price = Dict((prs, t) => po.buy_price for prs in PRS, t in T)
    elseif po.retail_type == :flat
        price = assign_price_to_prs(sr)
        intermediate_mean =
            Dict(prs => mean([min(price[prs, t], 0) for t in T]) for prs in PRS)
        price = Dict((prs, t) => intermediate_mean[prs] for prs in PRS, t in T)
    elseif po.retail_type == :realtime
        price = assign_price_to_prs(sr)
    end

    sell_price = po.sell_price
    netzentgelte = 250

    @objective(
        m,
        Min,
        sum((price[prs, t] + netzentgelte) * m[:PRS_BUY][prs, t] for prs in PRS, t in T) -
        sum(sell_price * m[:PRS_SELL][prs, t] for prs in PRS, t in T) +
        10 * sum(m[:PRS_STO_OUT][prs, t] + m[:PRS_STO_IN][prs, t] for prs in PRS, t in T) +
        sum(1000 * m[:INF][prs, t] for prs in PRS, t in T)
    )
end

function add_prosumer_objective(
    sr::SubRun{MT,MS},
    po::ProsumerSetup,
) where {MT<:MarketType,MS<:DayAhead}
    @unpack PRS = sr.modelrun.params.sets
    T = sr.market_state.Time
    m = sr.prosumer

    @objective(m, Min, sum(1000 * m[:INF][prs, t] for prs in PRS, t in T))
end

function assign_price_to_prs(
    sr::SubRun{MT,MS},
) where {MT<:ZonalMarketType,MS<:ProsumerOptimizationState}
    @unpack PRS = sr.modelrun.params.sets
    @unpack plant2zone = sr.modelrun.params
    T = sr.market_state.Time

    p = sr.market_state.price[:price]
    return Dict((prs, t) => p[plant2zone[prs], t] for prs in PRS, t in T)
end

function assign_price_to_prs(
    sr::SubRun{MT,MS},
) where {MT<:NodalMarketType,MS<:ProsumerOptimizationState}
    @unpack PRS = sr.modelrun.params.sets
    @unpack plant2node = sr.modelrun.params
    T = sr.market_state.Time

    p = sr.market_state.price[:price]
    return Dict((prs, t) => p[plant2node[prs], t] for prs in PRS, t in T)
end


