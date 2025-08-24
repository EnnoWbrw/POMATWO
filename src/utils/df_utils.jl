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
Initializes the :NTC DataFrame in the results dictionary if it does not exist.
Stores NTC results for each zone pair and time period.
"""
function df_ntc(dict)
    if !haskey(dict, :NTC)
        dict[:NTC] =
            DataFrame(; From = String[], To = String[], Time = Int[], NTC = VariableRef[])
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

read_csv(file) = CSV.read(file, DataFrame, stringtype = String)

function prev_results_for_redispatch(sr::SubRun)
    d = sr.vars

    return Dict(
        :disp_generation => value.(d[:disp][:GEN]),
        :ndisp_cu => value.(d[:ndisp][:CU]),
        :sto_generation => value.(d[:sto][:GEN]),
        :sto_charge => value.(d[:sto][:CHARGE]),
    )
end