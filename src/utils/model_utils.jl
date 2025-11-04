
zbase(voltage::Number) = (voltage * 1E3)^2 / (500 * 1E6)

function fetch_results(sr::SubRun)
    for k in keys(sr.results)

        if haskey(results_value_cols, k)
            col = results_value_cols[k]
            getvalue(sr.results[k], propertynames(sr.results[k]), value_or_number)
        end

        if haskey(results_dual_cols, k)
            col = results_dual_cols[k]
            getvalue(sr.results[k], col, dual_or_number)
        end
    end
end

function write_results(sr::SubRun; format = "arrow")
    scen_dir = sr.modelrun.scen_dir
    t1, tend = sr.market_state.Time[[1, end]]
    sr_dir = mkpath(joinpath(scen_dir, "subrun_t$(t1)-t$(tend)"))

    for (varname, df) in sr.results

        filename = joinpath(sr_dir, string(varname) * "." * format)

        if format == "arrow"
            try
                Arrow.write(filename, df)
            catch e
                @error "Could not write Arrow file" first(df, 25)
            end
        elseif format == "csv"
            CSV.write(filename, df)
        end
    end
end


function add_module!(m::OptiGraph, label::String)
    n = OptiNode()
    Plasmo.set_label(n, label)
    add_node!(m, n)
    return n
end

function JuMP.optimize!(sr::SubRun)
    set_optimizer(sr.optigraph, sr.modelrun.solver)
    optimize!(sr.optigraph)
end


