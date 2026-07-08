
zbase(voltage::Number) = (voltage * 1E3)^2 / (500 * 1E6)

function fetch_results(sr::SubRun)
    for k in keys(sr.results)
        # value-transform every column; plain data passes through unchanged. This also
        # covers result tables of user-defined components, which are not registered in
        # results_value_cols.
        getvalue(sr.results[k], propertynames(sr.results[k]), value_or_number)

        if haskey(results_dual_cols, k)
            getvalue(sr.results[k], results_dual_cols[k], dual_or_number)
        end
    end
end

function write_results(sr::SubRun; format = "arrow", prefix = "")
    scen_dir = sr.modelrun.scen_dir
    t1, tend = sr.market_state.Time[[1, end]]
    sr_dir = mkpath(joinpath(scen_dir, "subrun_t$(t1)-t$(tend)"))

    for (varname, df) in sr.results

        filename = joinpath(sr_dir, prefix * string(varname) * "." * format)

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

# Wrap a solver (factory or OptimizerWithAttributes) so it solves silently.
# Used instead of stdout redirection (`@suppress`), which is global state and not
# thread-safe — silencing via MOI.Silent is per-model and works under threading.
_silent_solver(s::MOI.OptimizerWithAttributes) =
    MOI.OptimizerWithAttributes(s.optimizer_constructor, (s.params..., MOI.Silent() => true)...)
_silent_solver(s) = MOI.OptimizerWithAttributes(s, MOI.Silent() => true)

function JuMP.optimize!(sr::SubRun)
    solver = sr.modelrun.verbose ? sr.modelrun.solver : _silent_solver(sr.modelrun.solver)
    set_optimizer(sr.optigraph, solver)
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


