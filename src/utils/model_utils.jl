
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
                @error "Could not write Arrow file" filename exception = (typeof(e), e) preview = first(df, 25)
            end
        elseif format == "csv"
            CSV.write(filename, df)
        end
    end
end

function write_results_2DA(sr::SubRun; format = "arrow")
    scen_dir = sr.modelrun.scen_dir
    t1, tend = sr.market_state.Time[[1, end]]
    sr_dir = mkpath(joinpath(scen_dir, "subrun_t$(t1)-t$(tend)"))

    for (varname, df) in sr.results

        filename = joinpath(sr_dir, "2DA" * string(varname) * "." * format)

        if format == "arrow"
            try
                Arrow.write(filename, df)
            catch e
                @error "Could not write Arrow file" filename exception = (typeof(e), e) preview = first(df, 25)
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

function log_status(sr::SubRun, label::String="")
    status = termination_status(sr.optigraph)
    prefix = isempty(label) ? "" : "[$label] "
    if status == MOI.OPTIMAL
        @info "$(prefix)Optimization status: OPTIMAL (unique optimal solution)"
    elseif status == MOI.DUAL_INFEASIBLE
        @warn "$(prefix)Optimization status: DUAL_INFEASIBLE (model is unbounded — infinite optimal solutions possible)"
    elseif status == MOI.INFEASIBLE
        @warn "$(prefix)Optimization status: INFEASIBLE (no feasible solution exists)"
    elseif status == MOI.INFEASIBLE_OR_UNBOUNDED
        @warn "$(prefix)Optimization status: INFEASIBLE_OR_UNBOUNDED (model is either infeasible or unbounded)"
    else
        @warn "$(prefix)Optimization status: $status"
    end
end


