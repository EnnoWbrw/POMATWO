"""
Initializes the :GEN DataFrame in the results dictionary if it does not exist.
Stores generation results for each generator and time period.
"""
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

"""
Initializes the :CHARGE DataFrame in the results dictionary if it does not exist.
Stores charging results for each storage unit and time period.
"""
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

"""
Initializes the :STO_LVL DataFrame in the results dictionary if it does not exist.
Stores storage level results for each storage unit and time period.
"""
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

"""
Initializes the :REDISP DataFrame in the results dictionary if it does not exist.
Stores redispatch results for generators and storage units.
"""
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

"""
Initializes the :NETINPUT DataFrame in the results dictionary if it does not exist.
Stores net input results for each node and time period.
"""
function df_netinput(dict)
    if !haskey(dict, :NETINPUT)
        dict[:NETINPUT] = DataFrame(;
            index = String[],
            Time = Int[],
            NETINPUT = AffOrVarOrFloatOrInt[],
            ACINJECTION = AffOrVarOrFloatOrInt[],
            DELTA = AffOrVarOrFloatOrInt[],
        )
    end
end

"""
Initializes the :LINEFLOW and :DCLINEFLOW DataFrames in the results dictionary if they do not exist.
Stores line flow results for AC and DC lines.
"""
function df_lineflow(dict)
    if !haskey(dict, :LINEFLOW)
        dict[:LINEFLOW] = DataFrame(;
            index = String[],
            Time = Int[],
            LINEFLOW = AffOrVar[],
            line_capacity = Float64[],
        )
    end

    if !haskey(dict, :DCLINEFLOW)
        dict[:DCLINEFLOW] = DataFrame(;
            index = String[],
            Time = Int[],
            DCLINEFLOW = AffOrVarOrFloatOrInt[],
            line_capacity = Float64[],
        )
    end
end

"""
Initializes the :EXCHANGE DataFrame in the results dictionary if it does not exist.
Stores exchange results for each zone and time period.
"""
function df_exchange(dict)
    if !haskey(dict, :EXCHANGE)
        dict[:EXCHANGE] =
            DataFrame(; index = String[], Time = Int[], EXCHANGE = AffOrVarOrFloatOrInt[])
    end
end

"""
Initializes the :FBMC_INF DataFrame in the results dictionary if it does not exist.
Stores FBMC infeasibility slack values for each CNE line and time period.
"""
function df_fbmc_inf(dict)
    if !haskey(dict, :FBMC_INF)
        dict[:FBMC_INF] = DataFrame(;
            index = String[],
            Time = Int[],
            FBMC_INF_POS = VariableRef[],
            FBMC_INF_NEG = VariableRef[],
        )
    end
end

"""
Initializes the :RAM DataFrame in the results dictionary if it does not exist.
Stores the flow-based Remaining Available Margin per CNE line and time period, together
with the basecase reference flow `F0` it was derived from and the parameters of the
70 %-rule (`fmax`, `FRM`, `minRAM`). Plain floats — computed before the solve, not
model variables.
"""
function df_ram(dict)
    if !haskey(dict, :RAM)
        dict[:RAM] = DataFrame(;
            index = String[],
            Time = Int[],
            RAM_POS = Float64[],
            RAM_NEG = Float64[],
            F0 = Float64[],
            fmax = Float64[],
            FRM = Float64[],
            minRAM = Float64[],
        )
    end
end

"""
Initializes the :BIL_EXCHANGE DataFrame in the results dictionary if it does not exist.
Stores bilateral exchange results for each zone pair and time period.
"""
function df_ntc(dict)
    if !haskey(dict, :BIL_EXCHANGE)
        dict[:BIL_EXCHANGE] =
            DataFrame(; From = String[], To = String[], Time = Int[], BIL_EXCHANGE = VariableRef[])
    end
end

"""
Initializes the :NodalMarketBalance DataFrame in the results dictionary if it does not exist.
Stores nodal market balance results for each node and time period.
"""
function df_nodalmarketbalance(dict)
    if !haskey(dict, :NodalMarketBalance)
        dict[:NodalMarketBalance] = DataFrame(;
            Time = Int[],
            Node = String[],
            MarketBalance = LinkConstraintRef[],
            CU = VariableRef[],
            LL = VariableRef[],
        )
    end
end

"""
Initializes the :NodalMarketRedispBalance DataFrame in the results dictionary if it does not exist.
Stores nodal market redispatch balance results for each node and time period.
"""
function df_nodalmarketredispbalance(dict)
    if !haskey(dict, :NodalMarketRedispBalance)
        dict[:NodalMarketRedispBalance] = DataFrame(;
            Time = Int[],
            Node = String[],
            MarketBalance = LinkConstraintRef[],
            CU = VariableRef[],
            LL = VariableRef[],
        )
    end
end

"""
Initializes the :ZonalMarketBalance DataFrame in the results dictionary if it does not exist.
Stores zonal market balance results for each zone and time period.
"""
function df_zonalmarketbalance(dict)
    if !haskey(dict, :ZonalMarketBalance)
        dict[:ZonalMarketBalance] = DataFrame(;
            Time = Int[],
            Zone = String[],
            MarketBalance = LinkConstraintRef[],
            CU = VariableRef[],
            LL = VariableRef[],
        )
    end
end

"""
Initializes the :PRS DataFrame in the results dictionary if it does not exist.
Stores prosumer results for each prosumer and time period.
"""
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

"""
    append_results!(results, key, tbl)

Add a block of result rows (built column-wise, see the builders in technologies.jl)
to the result table `key`. Replaces the empty schema-seeded table on first append so
columns keep their concrete types; later appends promote column types as needed.
"""
function append_results!(results::Dict{Symbol,DataFrame}, key::Symbol, tbl::DataFrame)
    isempty(tbl) && return get(results, key, tbl)
    if haskey(results, key) && !isempty(results[key])
        append!(results[key], tbl; promote = true)
    else
        results[key] = tbl
    end
    return results[key]
end

read_csv(file) = CSV.read(file, DataFrame, stringtype = String)

"""
    zonal_net_position(sr::SubRun) -> DenseAxisArray

Cleared zonal net position (import-positive) of a day-ahead `SubRun`, indexed `[z, t]`
with `z::String` and `t::Int`. Dispatches on the market type:
- `ZonalMarket`: the day-ahead stage already has an `:EXCHANGE` container (variable under
  `NTC`, expression under `FlowBased`) on the `:network` node — read it directly.
- `NodalMarket`: there is no `EXCHANGE`; the zonal aggregate is rebuilt by summing the
  nodal `NETINPUT` expression over each zone's nodes.

Used to seed `:zonal_net_position` in [`prev_results_for_redispatch`](@ref), which feeds
[`fix_net_positions!`](@ref) when `DCLF.fix_net_positions` is opted in.
"""
function zonal_net_position(sr::SubRun{MT}) where {MT<:ZonalMarketType}
    return value.(sr.vars[:network][:EXCHANGE])
end

function zonal_net_position(sr::SubRun{MT}) where {MT<:NodalMarketType}
    params = sr.modelrun.params
    @unpack Z = params.sets
    @unpack nodes_in_zone = params
    T = collect(sr.market_state.Time)
    NETINPUT = sr.vars[:network][:NETINPUT]

    data = [
        sum(value(NETINPUT[n, t]) for n in get(nodes_in_zone, z, String[]); init = 0.0)
        for z in Z, t in T
    ]
    return Containers.DenseAxisArray(data, Z, T)
end

function prev_results_for_redispatch(sr::SubRun)
    d = sr.vars

    return Dict(
        :disp_generation => value.(d[:disp][:GEN]),
        :ndisp_cu => value.(d[:ndisp][:CU]),
        :sto_generation => value.(d[:sto][:GEN]),
        :sto_charge => value.(d[:sto][:CHARGE]),
        :zonal_net_position => zonal_net_position(sr),
    )
end

function prev_results_for_fbmc(sr::SubRun)
    d = sr.vars

    return Dict(
        :disp_generation => value.(d[:disp][:GEN]),
        :ndisp_cu => value.(d[:ndisp][:CU]),
        :sto_generation => value.(d[:sto][:GEN]),
        :sto_charge => value.(d[:sto][:CHARGE]),
        :lineflows => value.(d[:network][:LINEFLOW]),
        :netinput_ac => value.(d[:network][:ACINJECTION]),
    )
end