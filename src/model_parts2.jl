const AffOrVarOrFloatOrInt = Union{AffExpr,VariableRef,Float64,Int}

function df_gen(dict)
    if !haskey(dict, :GEN)
        dict[:GEN] = DataFrame(;
            index = String[],
            Time = Int[],
            GEN = AffOrVarOrFloatOrInt[],
            mc = Float64[],
            gmax = Float64[],
            CU = AffOrVarOrFloatOrInt[],
        )
    end
end

function add_disp_generators(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:DayAhead}
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

    for p in DISP, t in T
        push!(
            mr.results[:GEN],
            (
                index = p,
                Time = t,
                GEN = GEN[p, t],
                mc = mc[p][t],
                gmax = avail[p][t] * gmax[p],
                CU = 0,
            ),
        )
    end

    return m
end

function add_ndisp_generators(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:DayAhead}
    T = mr.market_state.Time
    @unpack NDISP = mr.modelrun.params.sets
    @unpack gmax, avail, historical_generation, min_generation = mr.modelrun.params
    m = mr.ndisp

    # generation variables
    @variable(m, 0 <= CU[p = NDISP, t = T] <= avail[p][t] * gmax[p])
    @expression(m, FEEDIN[p = NDISP, t = T], avail[p][t] * gmax[p] - CU[p, t])

    @objective(m, Min, 50 * sum(CU[p, t] for p in NDISP, t in T))

    if !isempty(historical_generation)
        fueltypes_historical_ndisp =
            intersect(mr.modelrun.params.nondispatchable, keys(historical_generation))

        @variable(m, HISTORICAL_INF[ft = fueltypes_historical_ndisp, t = T] >= 0)
        @objective(
            m,
            Min,
            1000 * sum(HISTORICAL_INF[ft, t] for ft in fueltypes_historical_ndisp, t in T)
        )

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
        @objective(
            m,
            Min,
            1000 * sum(MINGEN_INF[ft, t] for ft in fueltypes_mingen_ndisp, t in T)
        )

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

    df_gen(mr.results)

    for p in NDISP, t in T
        push!(
            mr.results[:GEN],
            (
                index = p,
                Time = t,
                GEN = FEEDIN[p, t],
                mc = 0,
                gmax = avail[p][t] * gmax[p],
                CU = CU[p, t],
            ),
        )
    end

    return m
end

function df_charge(dict)
    if !haskey(dict, :CHARGE)
        dict[:CHARGE] = DataFrame(;
            index = String[],
            Time = Int[],
            CHARGE = VariableRef[],
            gmax = Float64[],
        )
    end
end

function df_sto(dict)
    if !haskey(dict, :STO_LVL)
        dict[:STO_LVL] = DataFrame(;
            index = String[],
            Time = Int[],
            STO_LVL = VariableRef[],
            storage = Float64[],
            inf = AffOrVarOrFloatOrInt[],
        )
    end
end

function add_storage(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:DayAhead}
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
    # storage constraint
    # @constraint(m, StorageBalance[s=S, t=T],

    # 	STO_LVL[s, t]
    # 	==
    # 	STO_LVL[s, prev_period(T, t)]
    # 	- GEN[s, t] / eta[s]
    # 	+ CHARGE[s, t] * eta[s]
    # 	+ inflow[s, t]
    # 	+ INF[s, t]
    # )

    for s in S
        for t in T
            if t == 1
                @constraint(
                    m,
                    STO_LVL[s, t] ==
                    -(GEN[s, t]) / eta[s] +
                    CHARGE[s, t] * eta[s] +
                    inflow[s, t] +
                    INF[s, t]
                )
            else
                prev_t = prev_period(T, t)
                @constraint(
                    m,
                    STO_LVL[s, t] ==
                    (STO_LVL[s, prev_t] - GEN[s, t] / eta[s]) +
                    CHARGE[s, t] * eta[s] +
                    inflow[s, t] +
                    INF[s, t]
                )
            end
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

    for s in S, t in T
        push!(
            mr.results[:GEN],
            (
                index = s,
                Time = t,
                GEN = GEN[s, t],
                mc = mc[s][t],
                gmax = gmax_storage[s],
                CU = 0,
            ),
        )

        push!(
            mr.results[:CHARGE],
            (index = s, Time = t, CHARGE = CHARGE[s, t], gmax = gmax_storage[s]),
        )


        push!(
            mr.results[:STO_LVL],
            (
                index = s,
                Time = t,
                STO_LVL = STO_LVL[s, t],
                storage = storage[s],
                inf = INF[s, t],
            ),
        )
    end

    return m
end

# ### Redispatch ###
function df_redispatch(dict)
    if !haskey(dict, :REDISP)
        dict[:REDISP] = DataFrame(;
            index = String[],
            Time = Int[],
            GEN_REDISP = AffExpr[],
            GEN_UP = AffOrVarOrFloatOrInt[],
            GEN_DOWN = AffOrVarOrFloatOrInt[],
            gen = Float64[],
            CU_REDISP = AffOrVarOrFloatOrInt[],
            CHARGE_REDISP = AffOrVarOrFloatOrInt[],
            CHARGE_UP = AffOrVarOrFloatOrInt[],
            CHARGE_DOWN = AffOrVarOrFloatOrInt[],
            max_up = Float64[],
        )
    end
end


function add_disp_generators(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack DISP = mr.modelrun.params.sets
    @unpack gmax, mc, avail = mr.modelrun.params
    m = mr.disp

    redispatch_cost = 150
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

    for p in DISP, t in T
        push!(
            mr.results[:REDISP],
            (
                index = p,
                Time = t,
                GEN_REDISP = GEN_REDISP[p, t],
                GEN_UP = GEN_UP[p, t],
                GEN_DOWN = GEN_DOWN[p, t],
                gen = g[p, t],
                CU_REDISP = 0,
                CHARGE_REDISP = 0,
                CHARGE_UP = 0,
                CHARGE_DOWN = 0,
                max_up = avail[p][t] * gmax[p] - g[p, t],
            ),
        )

    end

    return m
end

function add_ndisp_generators(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack NDISP, PRS = mr.modelrun.params.sets
    @unpack gmax, avail = mr.modelrun.params
    m = mr.ndisp

    #NDISP = setdiff(NDISP, PRS)

    cu = mr.market_state.da_market_result[:ndisp_cu]

    # generation variables
    @variable(m, cu[p, t] <= CU[p = NDISP, t = T] <= avail[p][t] * gmax[p])
    @expression(m, FEEDIN_REDISP[p = NDISP, t = T], avail[p][t] * gmax[p] - CU[p, t])
    @objective(m, Min, 1000 * sum(CU[p, t] - cu[p, t] for p in NDISP, t in T))

    df_redispatch(mr.results)

    for p in NDISP, t in T
        push!(
            mr.results[:REDISP],
            (
                index = p,
                Time = t,
                GEN_REDISP = FEEDIN_REDISP[p, t],
                GEN_UP = 0, #todo
                GEN_DOWN = 0,
                gen = 0,
                CU_REDISP = CU[p, t],
                CHARGE_REDISP = 0,
                CHARGE_UP = 0,
                CHARGE_DOWN = 0,
                max_up = 0,
            ),
        )
    end

    return m
end

function add_storage(mr::SubRun{MT,MS}) where {MT<:MarketType,MS<:Redispatch}
    T = mr.market_state.Time
    @unpack S = mr.modelrun.params.sets
    @unpack gmax, gmax_storage, eta, storage, mc, inflow = mr.modelrun.params
    m = mr.sto

    inflow = Dict((s, t) => haskey(inflow, s) ? inflow[s][t] : 0 for s in S, t in T)

    g = mr.market_state.da_market_result[:sto_generation]
    charge = mr.market_state.da_market_result[:sto_charge]

    redispatch_cost = 150

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
    # storage constraint
    # @constraint(m, StorageBalance[s=S, t=T],

    # 	STO_LVL_REDISP[s, t] ==
    # 	STO_LVL_REDISP[s, prev_period(T, t)]
    # 	- GEN_REDISP[s, t] * 1 / eta[s]
    # 	+ CHARGE_REDISP[s, t] * eta[s]
    # 	+ inflow[s, t]
    # 	+ INF[s,t]
    # )

    #	for s in S
    #		for t in T
    #			if t == 1
    #				@constraint(m, STO_LVL[s, t] == -(GEN[s, t]) / eta[s] + CHARGE[s, t] * eta[s] + inflow[s, t] + INF[s, t])
    #			elseif t < T
    #				prev_t = prev_period(T, t)
    #				@constraint(m, STO_LVL[s, t] == (STO_LVL[s, prev_t] - GEN[s, t] / eta[s]) + CHARGE[s, t] * eta[s] + inflow[s, t] + INF[s, t])
    #			else
    #				prev_t = prev_period(T, t)
    #				@constraint(m, STO_LVL[s, t] == (STO_LVL[s, prev_t] - GEN[s, t] / eta[s]) + CHARGE[s, t] * eta[s] + INF[s, t])
    #				@constraint(m, STO_LVL[s, t] == inflow[s,t] )
    #			end
    #		end
    #	end

    for s in S
        for t in T
            if t == 1
                @constraint(
                    m,
                    STO_LVL[s, t] ==
                    -(GEN[s, t]) / eta[s] +
                    CHARGE[s, t] * eta[s] +
                    inflow[s, t] +
                    INF[s, t]
                )
            else
                prev_t = prev_period(T, t)
                @constraint(
                    m,
                    STO_LVL[s, t] ==
                    (STO_LVL[s, prev_t] - GEN[s, t] / eta[s]) +
                    CHARGE[s, t] * eta[s] +
                    inflow[s, t] +
                    INF[s, t]
                )
            end
        end
    end

    ### to dataframe
    df_redispatch(mr.results)

    for s in S, t in T
        push!(
            mr.results[:REDISP],
            (
                index = s,
                Time = t,
                GEN_REDISP = GEN_REDISP[s, t],
                GEN_UP = GEN_UP[s, t],
                GEN_DOWN = GEN_DOWN[s, t],
                gen = g[s, t],
                CU_REDISP = 0,
                CHARGE_REDISP = CHARGE_REDISP[s, t],
                CHARGE_UP = CHARGE_UP[s, t],
                CHARGE_DOWN = CHARGE_DOWN[s, t],
                max_up = gmax_storage[s] - g[s, t],
            ),
        )
    end

    return m
end

function add_network(sr::SubRun{MT,MS}) where {MT<:NodalMarketType,MS<:MarketState}
    return add_dclf(sr)
end  # function _add_network

function add_network(sr::SubRun{MT,MS}) where {MT<:ZonalMarketWithRedispatch,MS<:Redispatch}
    return add_dclf(sr)
end  # function _add_network

function df_netinput(dict)
    if !haskey(dict, :NETINPUT)
        dict[:NETINPUT] = DataFrame(;
            index = String[],
            Time = Int[],
            NETINPUT = AffOrVarOrFloatOrInt[],
            DELTA = AffOrVarOrFloatOrInt[],
        )
    end
end

function df_lineflow(dict)
    if !haskey(dict, :LINEFLOW)
        dict[:LINEFLOW] = DataFrame(;
            index = String[],
            Time = Int[],
            LINEFLOW = AffOrVar[],
            line_capacity = Float64[],
            lineinf = VariableRef[],
        )
    end

    if !haskey(dict, :DCLINEFLOW)
        dict[:DCLINEFLOW] = DataFrame(;
            index = String[],
            Time = Int[],
            DCLINEFLOW = AffOrVarOrFloatOrInt[],
            line_capacity = Float64[],
            lineinf = VariableRef[],
        )
    end
end

function add_dclf(sr::SubRun)
    T = sr.market_state.Time
    @unpack N, DC, L = sr.modelrun.params.sets
    @unpack b,
    h,
    slack,
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

    dcincidence = Containers.DenseAxisArray(zeros(Int, length(L), length(N)), DC, N)
    for dc in DC
        dcincidence[dc, dc_start[dc]] = -1
        dcincidence[dc, dc_end[dc]] = 1
    end

    # @variable(m, DELTA[N, T])
    @variable(m, 0 <= F_POS[T, dc = DC] <= dcline_capacity[dc])
    @variable(m, 0 <= F_NEG[T, dc = DC] <= dcline_capacity[dc])
    @expression(m, F[t = T, dc = DC], F_POS[t, dc] - F_NEG[t, dc])
    @variable(m, 0 <= LINEINF[T, union(DC, L)])

    ##pomato version
    # https://github.com/richard-weinhold/MarketModel/blob/main/src/model_functions.jl

    @variable(m, THETA[T, N])

    @objective(m, Min, 1000 * sum(LINEINF[t, l] for t in T, l in union(DC, L)))

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

    for n in slack, t in T
        JuMP.fix(THETA[t, n], 0)
    end

    # @expression(
    # 	m,
    # 	NETINPUT[n=N, t=T],

    # 	sum(b[n, nn] * DELTA[nn, t] for nn in N)
    # 	+ sum(F[t, dc] for dc in DC if dc_end[dc] == n)
    # 	- sum(F[t, dc] for dc in DC if dc_start[dc] == n)
    # )

    # @expression(
    # 	m, LINEFLOW[l=L, t=T], sum(h[l, n] * DELTA[n, t] for n in N)
    # )


    @constraint(m, LineLimitPos[l = L, t = T], LINEFLOW[l, t] <= acline_capacity[l])

    @constraint(m, LineLimitNeg[l = L, t = T], -acline_capacity[l] <= LINEFLOW[l, t])

    # for n in slack, t in T
    # 	JuMP.fix(DELTA[n, t], 0)
    # end

    ### to dataframe
    df_netinput(sr.results)
    df_lineflow(sr.results)

    for n in N, t in T
        push!(
            sr.results[:NETINPUT],
            (index = n, Time = t, NETINPUT = NETINPUT[n, t], DELTA = THETA[t, n]),
        )
    end

    for l in L, t in T
        push!(
            sr.results[:LINEFLOW],
            (
                index = l,
                Time = t,
                LINEFLOW = LINEFLOW[l, t],
                line_capacity = acline_capacity[l],
                lineinf = LINEINF[t, l],
            ),
        )
    end

    for l in DC, t in T
        push!(
            sr.results[:DCLINEFLOW],
            (
                index = l,
                Time = t,
                DCLINEFLOW = F[t, l],
                line_capacity = dcline_capacity[l],
                lineinf = LINEINF[t, l],
            ),
        )
    end

end

function add_network(sr::SubRun{MT,MS}) where {MT<:ZonalMarketType,MS<:DayAhead}
    return add_exchange(sr)
end  # function _add_network

function df_exchange(dict)
    if !haskey(dict, :EXCHANGE)
        dict[:EXCHANGE] =
            DataFrame(; index = String[], Time = Int[], EXCHANGE = AffOrVarOrFloatOrInt[])
    end
end

function df_ntc(dict)
    if !haskey(dict, :NTC)
        dict[:NTC] =
            DataFrame(; From = String[], To = String[], Time = Int[], NTC = VariableRef[])
    end
end

function add_exchange(sr::SubRun)
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

    for (z, zz) in NTC, t in T
        push!(sr.results[:NTC], (From = z, To = zz, Time = t, NTC = EX[(z, zz), t]))
    end

    for z in Z, t in T
        push!(sr.results[:EXCHANGE], (index = z, Time = t, EXCHANGE = EXCHANGE[z, t]))
    end
end
