
"""
Add dispatchable generators to the model for the DayAhead market and the
TwoDayAhead basecase. Defines variables, objective, and constraints for
dispatchable generation. Updates results with generation data.
"""
function add_disp_generators(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup, MS<:DAor2DA}
    T = mr.market_state.Time
    @unpack DISP = mr.modelrun.params.sets
    @unpack gmax, mc, avail, historical_generation, min_generation = mr.modelrun.params
    m = mr.disp

    # generation variables
    @variable(m, 0 <= GEN[p = DISP, t = T] <= avail[p][t] * gmax[p])

    # objective function
    @objective(m, Min, sum(mc[p][t] * GEN[p, t] for p in DISP, t in T))

    if !isempty(historical_generation)
        fueltypes_historical_disp =
            intersect(mr.modelrun.params.dispatchable, keys(historical_generation))
        fueltypes_historical_disp =
            setdiff(fueltypes_historical_disp, mr.modelrun.params.storage_types)
        for ft in fueltypes_historical_disp
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], DISP)
            @constraint(
                m,
                [t = T],
                sum(GEN[p, t] for p in generators) == historical_generation[ft][t]
            )
        end
    end

    if !isempty(min_generation)
        fueltypes_mingen_disp =
            intersect(mr.modelrun.params.dispatchable, keys(min_generation))
        fueltypes_mingen_disp =
            setdiff(fueltypes_mingen_disp, mr.modelrun.params.storage_types)
        for ft in fueltypes_mingen_disp
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], DISP)
            @constraint(
                m,
                [t = T],
                sum(GEN[p, t] for p in generators) >= min_generation[ft][t]
            )
        end
    end

    df_gen(mr.results)

    append_results!(mr.results, :GEN, DataFrame(
        index = repeat(DISP, inner = length(T)),
        Time = repeat(collect(T), outer = length(DISP)),
        GEN = [GEN[p, t] for p in DISP for t in T],
        mc = [mc[p][t] for p in DISP for t in T],
        gmax = [avail[p][t] * gmax[p] for p in DISP for t in T],
        CU = zeros(Int, length(DISP) * length(T)),
    ))

    return m
end

"""
Add non-dispatchable generators to the model for the DayAhead market and the
TwoDayAhead basecase. Defines variables, objective, and constraints for
non-dispatchable generation. Updates results with generation data.
"""
function add_ndisp_generators(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup, MS<:DAor2DA}
    T = mr.market_state.Time
    @unpack NDISP = mr.modelrun.params.sets
    @unpack gmax, avail, historical_generation, min_generation = mr.modelrun.params
    m = mr.ndisp

    # generation variables
    @variable(m, 0 <= CU[p = NDISP, t = T] <= avail[p][t] * gmax[p])
    @expression(m, FEEDIN[p = NDISP, t = T], avail[p][t] * gmax[p] - CU[p, t])

    # `@objective` REPLACES the node objective, it does not add to it. Accumulate every cost
    # term into `obj` and set the objective exactly once, at the end of the builder.
    # NDISP may be empty, so accumulate term by term rather than with `sum` — outside a JuMP
    # macro, `sum` over an empty collection throws.
    obj = AffExpr()
    for p in NDISP, t in T
        add_to_expression!(obj, 50.0, CU[p, t])
    end

    if !isempty(historical_generation)
        fueltypes_historical_ndisp =
            intersect(mr.modelrun.params.nondispatchable, keys(historical_generation))

        @variable(m, HISTORICAL_INF[ft = fueltypes_historical_ndisp, t = T] >= 0)
        for ft in fueltypes_historical_ndisp, t in T
            add_to_expression!(obj, 1000.0, HISTORICAL_INF[ft, t])
        end

        for ft in fueltypes_historical_ndisp
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], NDISP)
            @constraint(
                m,
                [t = T],
                sum(FEEDIN[p, t] for p in generators) + HISTORICAL_INF[ft, t] ==
                historical_generation[ft][t]
            )
        end
    end

    if !isempty(min_generation)
        fueltypes_mingen_ndisp =
            intersect(mr.modelrun.params.nondispatchable, keys(min_generation))

        @variable(m, MINGEN_INF[ft = fueltypes_mingen_ndisp, t = T] >= 0)
        for ft in fueltypes_mingen_ndisp, t in T
            add_to_expression!(obj, 1000.0, MINGEN_INF[ft, t])
        end

        for ft in fueltypes_mingen_ndisp
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], NDISP)
            @constraint(
                m,
                [t = T],
                sum(FEEDIN[p, t] for p in generators) + MINGEN_INF[ft, t] >=
                min_generation[ft][t]
            )
        end
    end

    @objective(m, Min, obj)

    df_gen(mr.results)

    append_results!(mr.results, :GEN, DataFrame(
        index = repeat(NDISP, inner = length(T)),
        Time = repeat(collect(T), outer = length(NDISP)),
        GEN = [FEEDIN[p, t] for p in NDISP for t in T],
        mc = zeros(Int, length(NDISP) * length(T)),
        gmax = [avail[p][t] * gmax[p] for p in NDISP for t in T],
        CU = [CU[p, t] for p in NDISP for t in T],
    ))

    return m
end

"""
    initial_level(boundary::StorageBoundary, sr::SubRun, STO_LVL, s, T, carry_key)

Storage level the first hour of a time split connects to, per boundary condition:

- `CyclicStorage`: the level variable of the split's last hour (cyclic within split).
- `CarryOverStorage`: the level carried over from the previous split
  (`sr.ctx[carry_key]`), or `start_share * capacity` in the first split.
"""
initial_level(::CyclicStorage, sr::SubRun, STO_LVL, s, T, carry_key) = STO_LVL[s, T[end]]

function initial_level(b::CarryOverStorage, sr::SubRun, STO_LVL, s, T, carry_key)
    carried = get(sr.ctx, carry_key, nothing)
    carried === nothing && return b.start_share * sr.modelrun.params.storage[s]
    return carried[s]
end

"""
Add storage units to the model for the DayAhead market and the TwoDayAhead
basecase. Defines variables, objective, and constraints for storage operation.
The level of the first hour of the split connects to the boundary condition of
`setup.StorageBoundary` (see [`StorageBoundary`](@ref)).
Updates results with storage, charge, and generation data.
"""
function add_storage(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup, MS<:DAor2DA}
    T = mr.market_state.Time
    @unpack S = mr.modelrun.params.sets
    @unpack gmax_storage,
    gmax,
    eta,
    storage,
    mc,
    historical_generation,
    min_generation,
    inflow = mr.modelrun.params
    m = mr.sto

    inflow = Dict((s, t) => haskey(inflow, s) ? inflow[s][t] : 0 for s in S, t in T)

    # storage variables
    @variable(m, 0 <= GEN[s = S, t = T] <= gmax[s])
    @variable(m, 0 <= CHARGE[s = S, t = T] <= gmax_storage[s])
    @variable(m, 0 <= STO_LVL[s = S, t = T] <= storage[s])
    @variable(m, 0 <= INF_POS[s = S, t = T])
    @variable(m, 0 <= INF_NEG[s = S, t = T])

    @expression(m, INF[s = S, t = T], INF_POS[s, t] - INF_NEG[s, t])
    # objective function
    @objective(
        m,
        Min,
        #sum(max(mc[s][t], 0.01) * GEN[s, t] for s in S, t in T)
        sum(mc[s][t] * GEN[s, t] for s in S, t in T) +
        sum(10000 * (INF_POS[s, t] + INF_NEG[s, t]) for s in S, t in T)
    )

    boundary = mr.modelrun.setup.StorageBoundary
    for s in S
        for t in T
            prev_lvl =
                t == T[1] ? initial_level(boundary, mr, STO_LVL, s, T, :sto_lvl_start) :
                STO_LVL[s, prev_period(T, t)]
            @constraint(
                m,
                STO_LVL[s, t] ==
                prev_lvl - GEN[s, t] / eta[s] +
                CHARGE[s, t] * eta[s] +
                inflow[s, t] +
                INF[s, t]
            )
        end
    end

    if !isempty(historical_generation)
        fueltypes_historical_s =
            intersect(mr.modelrun.params.storage_types, keys(historical_generation))
        for ft in fueltypes_historical_s
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], S)
            #			@constraint(m, [t=T], sum(GEN[s, t] for s in generators) == historical_generation[ft][t])
            @constraint(
                m,
                sum(GEN[s, t] for s in generators, t in T) ==
                sum(historical_generation[ft][t] for t in T)
            )
        end
    end

    if !isempty(min_generation)
        fueltypes_mingen_s =
            intersect(mr.modelrun.params.storage_types, keys(min_generation))
        for ft in fueltypes_mingen_s
            generators = filter(x -> ft == mr.modelrun.params.plant_type[x], S)
            @constraint(
                m,
                [t = T],
                sum(GEN[s, t] for s in generators) >= min_generation[ft][t]
            )
        end
    end

    ### to dataframe
    df_gen(mr.results)
    df_charge(mr.results)
    df_sto(mr.results)

    index = repeat(S, inner = length(T))
    Time = repeat(collect(T), outer = length(S))

    append_results!(mr.results, :GEN, DataFrame(
        index = index,
        Time = Time,
        GEN = [GEN[s, t] for s in S for t in T],
        mc = [mc[s][t] for s in S for t in T],
        gmax = [gmax_storage[s] for s in S for t in T],
        CU = zeros(Int, length(S) * length(T)),
    ))

    append_results!(mr.results, :CHARGE, DataFrame(
        index = index,
        Time = Time,
        CHARGE = [CHARGE[s, t] for s in S for t in T],
        gmax = [gmax_storage[s] for s in S for t in T],
    ))

    append_results!(mr.results, :STO_LVL, DataFrame(
        index = index,
        Time = Time,
        STO_LVL = [STO_LVL[s, t] for s in S for t in T],
        storage = [storage[s] for s in S for t in T],
        inf = [INF[s, t] for s in S for t in T],
    ))

    return m
end

# ### Redispatch ###
"""
Add dispatchable generators to the model for Redispatch market.
Defines variables, objective, and constraints for redispatch generation.
Updates results with redispatch data.
"""
function add_disp_generators(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack DISP = mr.modelrun.params.sets
    @unpack gmax, mc, avail = mr.modelrun.params
    m = mr.disp

    redispatch_cost = mr.modelrun.setup.RedispatchSetup.disp_cost
    g = mr.market_state.da_market_result[:disp_generation]

    # generation variables
    @variable(m, 0 <= GEN_UP[p = DISP, t = T] <= avail[p][t] * gmax[p] - g[p, t])
    @variable(m, 0 <= GEN_DOWN[p = DISP, t = T] <= g[p, t])
    # objective function
    @objective(
        m,
        Min,
        sum(redispatch_cost * (GEN_UP[p, t] + GEN_DOWN[p, t]) for p in DISP, t in T)
    )

    @expression(m, GEN_REDISP[p = DISP, t = T], GEN_UP[p, t] - GEN_DOWN[p, t] + g[p, t])

    df_redispatch(mr.results)

    nrows = length(DISP) * length(T)
    append_results!(mr.results, :REDISP, DataFrame(
        index = repeat(DISP, inner = length(T)),
        Time = repeat(collect(T), outer = length(DISP)),
        GEN_REDISP = [GEN_REDISP[p, t] for p in DISP for t in T],
        GEN_UP = [GEN_UP[p, t] for p in DISP for t in T],
        GEN_DOWN = [GEN_DOWN[p, t] for p in DISP for t in T],
        gen = [g[p, t] for p in DISP for t in T],
        CU_REDISP = zeros(Int, nrows),
        CHARGE_REDISP = zeros(Int, nrows),
        CHARGE_UP = zeros(Int, nrows),
        CHARGE_DOWN = zeros(Int, nrows),
        max_up = [avail[p][t] * gmax[p] - g[p, t] for p in DISP for t in T],
    ))

    return m
end

"""
Add non-dispatchable generators to the model for Redispatch market.
Defines variables, objective, and constraints for redispatch non-dispatchable generation.
Updates results with redispatch data.

Non-dispatchables are redispatched in both directions: `GEN_UP` recalls generation that was
curtailed in the day-ahead (bounded by that curtailment, so it can never exceed the
available potential `avail * gmax`), `GEN_DOWN` curtails further. Prosumer plants are
exempt: they represent aggregated household-scale capacity, not TSO-dispatchable assets, and
their day-ahead behaviour is frozen (see `add_prosumer` for `Redispatch`).
"""
function add_ndisp_generators(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack NDISP, PRS = mr.modelrun.params.sets
    @unpack gmax, avail = mr.modelrun.params
    m = mr.ndisp

    if !(mr.modelrun.setup.ProsumerSetup isa NoProsumer)
        NDISP = setdiff(NDISP, PRS)
    end

    res_up_cost = mr.modelrun.setup.RedispatchSetup.res_up_cost
    res_down_cost = mr.modelrun.setup.RedispatchSetup.res_down_cost

    cu = mr.market_state.da_market_result[:ndisp_cu]
    feedin_da = Dict((p, t) => avail[p][t] * gmax[p] - cu[p, t] for p in NDISP, t in T)

    # generation variables
    @variable(m, 0 <= GEN_UP[p = NDISP, t = T] <= cu[p, t])
    @variable(m, 0 <= GEN_DOWN[p = NDISP, t = T] <= feedin_da[p, t])

    @expression(
        m,
        FEEDIN_REDISP[p = NDISP, t = T],
        feedin_da[p, t] + GEN_UP[p, t] - GEN_DOWN[p, t]
    )
    @expression(m, CU[p = NDISP, t = T], cu[p, t] - GEN_UP[p, t] + GEN_DOWN[p, t])

    @objective(
        m,
        Min,
        sum(
            res_up_cost * GEN_UP[p, t] + res_down_cost * GEN_DOWN[p, t] for p in NDISP,
            t in T
        )
    )

    df_redispatch(mr.results)

    nrows = length(NDISP) * length(T)
    append_results!(mr.results, :REDISP, DataFrame(
        index = repeat(NDISP, inner = length(T)),
        Time = repeat(collect(T), outer = length(NDISP)),
        GEN_REDISP = [FEEDIN_REDISP[p, t] for p in NDISP for t in T],
        GEN_UP = [GEN_UP[p, t] for p in NDISP for t in T],
        GEN_DOWN = [GEN_DOWN[p, t] for p in NDISP for t in T],
        gen = [feedin_da[p, t] for p in NDISP for t in T],
        CU_REDISP = [CU[p, t] for p in NDISP for t in T],
        CHARGE_REDISP = zeros(Int, nrows),
        CHARGE_UP = zeros(Int, nrows),
        CHARGE_DOWN = zeros(Int, nrows),
        max_up = [cu[p, t] for p in NDISP for t in T],
    ))

    return m
end

"""
Add storage units to the model for Redispatch market.
Defines variables, objective, and constraints for redispatch storage operation.
Updates results with redispatch data.
"""
function add_storage(mr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS <:ProsumerSetup, RD <:RedispatchSetup,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack S = mr.modelrun.params.sets
    @unpack gmax, gmax_storage, eta, storage, mc, inflow = mr.modelrun.params
    m = mr.sto

    inflow = Dict((s, t) => haskey(inflow, s) ? inflow[s][t] : 0 for s in S, t in T)

    g = mr.market_state.da_market_result[:sto_generation]
    charge = mr.market_state.da_market_result[:sto_charge]

    redispatch_cost = mr.modelrun.setup.RedispatchSetup.sto_cost

    # storage variables
    @variable(m, 0 <= GEN_UP[s = S, t = T] <= gmax[s] - g[s, t])
    @variable(m, 0 <= GEN_DOWN[s = S, t = T] <= g[s, t])
    @variable(m, 0 <= CHARGE_UP[s = S, t = T] <= gmax_storage[s] - charge[s, t])
    @variable(m, 0 <= CHARGE_DOWN[s = S, t = T] <= charge[s, t])
    @variable(m, 0 <= STO_LVL_REDISP[s = S, t = T] <= storage[s])
    @variable(m, 0 <= INF_POS[s = S, t = T])
    @variable(m, 0 <= INF_NEG[s = S, t = T])

    @expression(m, INF[s = S, t = T], INF_POS[s, t] - INF_NEG[s, t])

    @expression(m, GEN_REDISP[s = S, t = T], GEN_UP[s, t] - GEN_DOWN[s, t] + g[s, t])

    @expression(
        m,
        CHARGE_REDISP[s = S, t = T],
        CHARGE_UP[s, t] - CHARGE_DOWN[s, t] + charge[s, t]
    )

    # objective function
    @objective(
        m,
        Min,
        sum(redispatch_cost * (GEN_UP[s, t] + GEN_DOWN[s, t]) for s in S, t in T) +
        sum(10000 * (INF_POS[s, t] + INF_NEG[s, t]) for s in S, t in T)
    )
  
    boundary = mr.modelrun.setup.StorageBoundary
    for s in S
        for t in T
            prev_lvl =
                t == T[1] ?
                initial_level(boundary, mr, STO_LVL_REDISP, s, T, :sto_lvl_start_redisp) :
                STO_LVL_REDISP[s, prev_period(T, t)]
            @constraint(
                m,
                STO_LVL_REDISP[s, t] ==
                prev_lvl - GEN_REDISP[s, t] / eta[s] +
                CHARGE_REDISP[s, t] * eta[s] +
                inflow[s, t] +
                INF[s, t]
            )
        end
    end

    ### to dataframe
    df_redispatch(mr.results)

    append_results!(mr.results, :REDISP, DataFrame(
        index = repeat(S, inner = length(T)),
        Time = repeat(collect(T), outer = length(S)),
        GEN_REDISP = [GEN_REDISP[s, t] for s in S for t in T],
        GEN_UP = [GEN_UP[s, t] for s in S for t in T],
        GEN_DOWN = [GEN_DOWN[s, t] for s in S for t in T],
        gen = [g[s, t] for s in S for t in T],
        CU_REDISP = zeros(Int, length(S) * length(T)),
        CHARGE_REDISP = [CHARGE_REDISP[s, t] for s in S for t in T],
        CHARGE_UP = [CHARGE_UP[s, t] for s in S for t in T],
        CHARGE_DOWN = [CHARGE_DOWN[s, t] for s in S for t in T],
        max_up = [gmax[s] - g[s, t] for s in S for t in T],
    ))

    return m
end

"""
Add network constraints for nodal market types using DC load flow.
Returns the result of add_dclf.
"""
function add_network(sr::SubRun{NodalMarket{LF}, PS, RD, MS}) where {LF<:DCLFFormulation, PS <:ProsumerSetup, RD <:RedispatchSetup,MS<:MarketState}
    return add_dclf(sr, LF)
end  # function _add_network

"""
Add network constraints for zonal market with redispatch using DC load flow.
Returns the result of add_dclf.
"""
function add_network(sr::SubRun{MT, PS, DCLF{LF}, MS}) where {MT<:MarketType, PS <: ProsumerSetup, LF <:DCLFFormulation ,MS<:Redispatch}
    return add_dclf(sr,LF)
end  # function _add_network

"""
Add DC load flow constraints to the model.
Defines variables, objective, and constraints for power flows.
Updates results with net input and line flow data.
"""
function add_dclf(sr::SubRun, ::Type{PhaseAngle})
    T = sr.market_state.Time
    @unpack N, DC, L = sr.modelrun.params.sets
    @unpack b,
    h,
    slack,
    slack_zone,
    acline_capacity,
    dcline_capacity,
    dc_start,
    dc_end,
    line_start,
    line_end,
    bvector = sr.modelrun.params
    m = sr.network

    incidence = Containers.DenseAxisArray(zeros(Int, length(L), length(N)), L, N)
    for l in L
        incidence[l, line_start[l]] = -1
        incidence[l, line_end[l]] = 1
    end

    dcincidence = Containers.DenseAxisArray(zeros(Int, length(DC), length(N)), DC, N)
    for dc in DC
        dcincidence[dc, dc_start[dc]] = -1
        dcincidence[dc, dc_end[dc]] = 1
    end

    # @variable(m, DELTA[N, T])
    @variable(m, 0 <= F_POS[T, dc = DC] <= dcline_capacity[dc])
    @variable(m, 0 <= F_NEG[T, dc = DC] <= dcline_capacity[dc])
    @expression(m, F[t = T, dc = DC], F_POS[t, dc] - F_NEG[t, dc])

    ##pomato version
    # https://github.com/richard-weinhold/MarketModel/blob/main/src/model_functions.jl

    @variable(m, THETA[T, N])

    # Note: no line-limit slack variables. Line limits can never make the model
    # infeasible on their own (THETA = 0 is always feasible for the network node);
    # any resulting imbalance is absorbed by the CU/LL slacks of the market balance.

    @expression(
        m,
        LINEFLOW[l = L, t = T],
        bvector[l] * sum(incidence[l, n] * THETA[t, n] for n in N)
    )

    @expression(
        m,
        NETINPUT[n = N, t = T],
        sum(incidence[l, n] * LINEFLOW[l, t] for l in L) +
        sum(dcincidence[dc, n] * F[t, dc] for dc in DC)
    )

    @expression(
    m,
    ACINJECTION[n = N, t = T],
    sum(incidence[l, n] * LINEFLOW[l, t] for l in L)
    )

    for n in slack, t in T
        JuMP.fix(THETA[t, n], 0)
    end


    @constraint(m, LineLimitPos[l = L, t = T], LINEFLOW[l, t] <= acline_capacity[l])

    @constraint(m, LineLimitNeg[l = L, t = T], -acline_capacity[l] <= LINEFLOW[l, t])

    if !isempty(slack_zone)
        @constraint(
            m,
            SlackZoneBalance[zs = keys(slack_zone), t = T],
            sum(ACINJECTION[n, t] for n in slack_zone[zs]) == 0
        )
    end


    ### to dataframe
    df_netinput(sr.results)
    df_lineflow(sr.results)

    append_results!(sr.results, :NETINPUT, DataFrame(
        index = repeat(N, inner = length(T)),
        Time = repeat(collect(T), outer = length(N)),
        NETINPUT = [NETINPUT[n, t] for n in N for t in T],
        ACINJECTION = [ACINJECTION[n, t] for n in N for t in T],
        DELTA = [THETA[t, n] for n in N for t in T],
    ))

    append_results!(sr.results, :LINEFLOW, DataFrame(
        index = repeat(L, inner = length(T)),
        Time = repeat(collect(T), outer = length(L)),
        LINEFLOW = [LINEFLOW[l, t] for l in L for t in T],
        line_capacity = [acline_capacity[l] for l in L for t in T],
    ))

    append_results!(sr.results, :DCLINEFLOW, DataFrame(
        index = repeat(DC, inner = length(T)),
        Time = repeat(collect(T), outer = length(DC)),
        DCLINEFLOW = [F[t, l] for l in DC for t in T],
        line_capacity = [dcline_capacity[l] for l in DC for t in T],
    ))

end

"""
Add network constraints for zonal market types using exchange model.
Returns the result of add_exchange.
"""
function add_network(sr::SubRun{ZonalMarket{XF},PS,RD,MS}) where {XF<:ExchangeFormulation,PS <:ProsumerSetup, RD <: RedispatchSetup,MS<:DayAhead}
    return add_exchange(sr, XF)
end 

"""
Add network constraints for zonal market types in TwoDayAhead basecase using DC load flow.
Returns the result of add_dclf with PhaseAngle formulation.
"""
function add_network(sr::SubRun{ZonalMarket{XF},PS,RD,MS}) where {XF<:ExchangeFormulation,PS <:ProsumerSetup, RD <: RedispatchSetup,MS<:TwoDayAhead}
    return add_dclf(sr, PhaseAngle) ## use PhaseAngle for basecase
end 


"""
Add exchange constraints to the model for zonal markets.
Defines variables, objective, and constraints for exchanges.
Updates results with NTC and exchange data.
"""
function add_exchange(sr::SubRun, ::Type{NTC})
    T = sr.market_state.Time
    @unpack Z, NTC = sr.modelrun.params.sets
    @unpack importing_ntcs, exporting_ntcs, ntc, fixed_exchange = sr.modelrun.params
    m = sr.network

    @variable(m, 0 <= EX[(z, zz) = NTC, t = T] <= ntc[z, zz])

    @expression(
        m,
        EXCHANGE[z = Z, t = T],
        0 +
        (
            if haskey(importing_ntcs, z)
                (sum(EX[(zz, z), t] for zz in importing_ntcs[z]))
            else
                0
            end
        ) +
        (
            if haskey(exporting_ntcs, z)
                (-sum(EX[(z, zz), t] for zz in exporting_ntcs[z]))
            else
                0
            end
        ) +
        (
            if haskey(fixed_exchange, z)
                fixed_exchange[z][t]
            else
                0
            end
        )
    )

    ### to dataframe
    df_ntc(sr.results)
    df_exchange(sr.results)

    append_results!(sr.results, :BIL_EXCHANGE, DataFrame(
        From = [z for (z, zz) in NTC for t in T],
        To = [zz for (z, zz) in NTC for t in T],
        Time = repeat(collect(T), outer = length(NTC)),
        BIL_EXCHANGE = [EX[(z, zz), t] for (z, zz) in NTC for t in T],
    ))

    append_results!(sr.results, :EXCHANGE, DataFrame(
        index = repeat(Z, inner = length(T)),
        Time = repeat(collect(T), outer = length(Z)),
        EXCHANGE = [EXCHANGE[z, t] for z in Z for t in T],
    ))
end


function add_exchange(sr::SubRun, ::Type{FlowBased})
    T = sr.market_state.Time
    @unpack Z, L , DC, N, NTCCCR, FBCCR = sr.modelrun.params.sets
    @unpack ntc,
    dcline_capacity, 
    dc_start, 
    dc_end, 
    nodes_in_zone,
    cne = sr.modelrun.params
    fbmc_params = sr.market_state.fbmc_params
    connected_zones_ac = find_connected_zones_ac(sr.modelrun.params)
    # Check if fbmc_params were calculated
    if isnothing(fbmc_params)
        error("FlowBased market requires fbmc_params but none were provided. Flow-based markets require RedispatchType setup to run the TwoDayAhead basecase.")
    end
        importing::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
        exporting::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    for z in Z
        imp = [zz for zz in Z if (zz, z) in connected_zones_ac]
        isempty(imp) || (importing[z] = imp)
        exp = [zz for zz in Z if (z, zz) in connected_zones_ac]
        isempty(exp) || (exporting[z] = exp)
    end

    dcincidence = Containers.DenseAxisArray(zeros(Int, length(DC), length(N)), DC, N)
    for dc in DC
        dcincidence[dc, dc_start[dc]] = -1
        dcincidence[dc, dc_end[dc]] = 1
    end
    m = sr.network

    @variable(m, 0 <= EX[(z, zz) = connected_zones_ac, t = T])

    # @variable(m, DELTA[N, T])
    @variable(m, 0 <= F_POS[T, dc = DC] <= dcline_capacity[dc])
    @variable(m, 0 <= F_NEG[T, dc = DC] <= dcline_capacity[dc])
    @expression(m, F[t = T, dc = DC], F_POS[t, dc] - F_NEG[t, dc])

    @expression(m, DCINJECTION[z = Z, t = T],
    sum(sum(dcincidence[dc, n] * F[t, dc] for dc in DC) for n in nodes_in_zone[z])
    )

    @expression(
        m,
        NP[z = FBCCR, t = T],
        0 +
        (
            if haskey(importing, z)
                (sum(EX[(zz, z), t] for zz in importing[z]))
            else
                0
            end
        ) +
        (
            if haskey(exporting, z)
                (-sum(EX[(z, zz), t] for zz in exporting[z]))
            else
                0
            end
        )
    )

    @constraint(m,
        ac_NTC[(z, zz) = connected_zones_ac, t = T; z in NTCCCR || zz in NTCCCR],
        EX[(z, zz), t] <= ntc[z, zz])

    @expression(m,
    NP_ntc[z = NTCCCR, t = T],
    0 +
    (
        if haskey(importing, z)
            (sum(EX[(zz, z), t] for zz in importing[z]))
        else
            0
        end
    ) +
    (
        if haskey(exporting, z)
            (-sum(EX[(z, zz), t] for zz in exporting[z]))
        else
            0
        end
    )
    )
    for z in NTCCCR, t in T
        if haskey(fixed_exchange, z)
            @constraint(m, NP_ntc[z, t] == fixed_exchange[z][t])
        end
    end


    # Flow-based constraints: for each line, the zonal exchange weighted by PTDF must respect RAM
    # Note: The sum of PTDFz[l,z] * NP[z,t] is multiplied by -1 because EXCHANGE is defined as positive for imports,
    # while the flow-based constraints are typically defined with positive for exports. 
    # This sign convention ensures that the constraints correctly represent the physical flow limits on the lines.
    # Infeasibility slack variables allow the model to find a solution even if fixed exchanges violate FBMC limits.
    @variable(m, 0 <= FBMC_INF_POS[l = cne, t = T])
    @variable(m, 0 <= FBMC_INF_NEG[l = cne, t = T])

    @objective(m, Min, 100000 * sum(FBMC_INF_POS[l, t] + FBMC_INF_NEG[l, t] for l in cne, t in T))

    # _ptdfz resolves the zonal PTDF for both static (l×z) and time-dependent
    # (l×z×t, e.g. GenLoadGSK) matrices
    @constraint(
        m,
        FBMC_pos[l = cne, t = T],
        -sum(_ptdfz(fbmc_params[:PTDFz], l, z, t) * NP[z, t] for z in FBCCR) <= fbmc_params[:RAM][l,t,"pos"] + FBMC_INF_POS[l, t]
    )

    @constraint(
        m,
        FBMC_neg[l = cne, t = T],
        fbmc_params[:RAM][l,t,"neg"] - FBMC_INF_NEG[l, t] <= -sum(_ptdfz(fbmc_params[:PTDFz], l, z, t) * NP[z, t] for z in FBCCR)
    )

    @expression(m, EXCHANGE[z = Z, t = T],
        (z in FBCCR ? NP[z, t] : NP_ntc[z, t]) + DCINJECTION[z, t]
    )

    ### to dataframe
    df_ntc(sr.results)
    df_exchange(sr.results)
    df_fbmc_inf(sr.results)

    append_results!(sr.results, :BIL_EXCHANGE, DataFrame(
        From = [z for (z, zz) in connected_zones_ac for t in T],
        To = [zz for (z, zz) in connected_zones_ac for t in T],
        Time = repeat(collect(T), outer = length(connected_zones_ac)),
        BIL_EXCHANGE = [EX[(z, zz), t] for (z, zz) in connected_zones_ac for t in T],
    ))

    append_results!(sr.results, :EXCHANGE, DataFrame(
        index = repeat(Z, inner = length(T)),
        Time = repeat(collect(T), outer = length(Z)),
        EXCHANGE = [EXCHANGE[z, t] for z in Z for t in T],
    ))

    append_results!(sr.results, :FBMC_INF, DataFrame(
        index = repeat(cne, inner = length(T)),
        Time = repeat(collect(T), outer = length(cne)),
        FBMC_INF_POS = [FBMC_INF_POS[l, t] for l in cne for t in T],
        FBMC_INF_NEG = [FBMC_INF_NEG[l, t] for l in cne for t in T],
    ))
end