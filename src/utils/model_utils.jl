
zbase(voltage::Number) = (voltage * 1E3)^2 / (500 * 1E6)

"""
    primal_cache(sr::SubRun) -> Dict{VariableRef,Float64}

Primal value of every variable in the subrun's optigraph, fetched in one pass.

`JuMP.value` on a Plasmo node variable is a round-trip into the solved optimizer
(`NodeBackend` -> `NodePointer` -> `MOI.get`, one variable at a time), and
`value(::AffExpr)` repeats that once per term. Result tables reuse the same variables
across many rows: the PTDF line-flow expressions of [`report_nodal_flows!`](@ref) carry
one term per plant, per line, per hour, so a single plant's value is re-fetched hundreds
of thousands of times per split. Fetching each variable once and evaluating the
expressions against this cache returns exactly the same numbers -- the terms and their
summation order are untouched -- for a fraction of the round-trips.
"""
function primal_cache(sr::SubRun)
    cache = Dict{VariableRef,Float64}()
    for node in all_nodes(sr.optigraph)
        vars = JuMP.all_variables(node)
        isempty(vars) && continue
        vals = MOI.get(JuMP.backend(node), MOI.VariablePrimal(), JuMP.index.(vars))
        for (v, val) in zip(vars, vals)
            cache[v] = val
        end
    end
    return cache
end

# Cached counterparts of `value_or_number`. The `get(f, cache, v)` fallback keeps a
# variable that is somehow absent from the cache working, at the old per-call cost,
# rather than throwing.
_cached_value(x, ::Dict{VariableRef,Float64}) = x
_cached_value(x::VariableRef, cache::Dict{VariableRef,Float64}) =
    get(() -> value(x), cache, x)
_cached_value(x::AffExpr, cache::Dict{VariableRef,Float64}) =
    value(v -> get(() -> value(v), cache, v), x)

function fetch_results(sr::SubRun)
    cache = primal_cache(sr)
    for k in keys(sr.results)
        # value-transform every column; plain data passes through unchanged. This also
        # covers result tables of user-defined components, which are not registered in
        # results_value_cols.
        getvalue(sr.results[k], propertynames(sr.results[k]), x -> _cached_value(x, cache))

        if haskey(results_dual_cols, k)
            getvalue(sr.results[k], results_dual_cols[k], dual_or_number)
        end
    end
end

"""
    write_results(sr::SubRun; format = "arrow", prefix = result_prefix(sr.market_state))

Persist the subrun's result tables as `<prefix>_<TABLE>.<format>` in the split's folder.
The prefix namespaces the market state (see [`result_prefix`](@ref)) so stages of the same
run cannot overwrite each other's tables.
"""
function write_results(sr::SubRun; format = "arrow", prefix = result_prefix(sr.market_state))
    scen_dir = sr.modelrun.scen_dir
    t1, tend = sr.market_state.Time[[1, end]]
    sr_dir = mkpath(joinpath(scen_dir, "subrun_t$(t1)-t$(tend)"))

    # Durable audit trail. The `@info`/`@warn` from `log_status` lives only in the console,
    # which is lost the moment an unattended run ends, so a finished result directory used to
    # carry no record of how its numbers were obtained. One line per stage, appended, lets any
    # result directory be audited long after the run.
    # `JuMP.solve_time` has no OptiGraph method, so query MOI directly. Wrapped because a
    # solver need not implement SolveTimeSec: the status is the point of this file, the
    # timing is a convenience.
    secs = try
        string(round(MOI.get(sr.optigraph, MOI.SolveTimeSec()), digits = 2), " s")
    catch
        "n/a"
    end
    open(joinpath(sr_dir, "SOLVE_STATUS.txt"), "a") do io
        println(io, prefix, "\t", termination_status(sr.optigraph),
                "\tt", t1, "-t", tend, "\t", secs)
    end

    for (varname, df) in sr.results

        stem = isempty(prefix) ? string(varname) : string(prefix, "_", varname)
        filename = joinpath(sr_dir, stem * "." * format)

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

"""
    log_status(sr::SubRun, label = "") -> MOI.TerminationStatusCode

Log the subrun's termination status and **return it**, so callers can gate on it.

Returning the status matters: a solver that stops at `TIME_LIMIT`, `SUBOPTIMAL` or
`NUMERICAL_ERROR` while holding an incumbent still lets `value()` succeed, so
`fetch_results`/`write_results` would persist that incumbent indistinguishably from a proven
optimum. Warning alone is not enough — nothing downstream could see it. See
[`assert_optimal`](@ref).
"""
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
    return status
end

"""
    assert_optimal(status, sr, label = "")

Refuse to persist a subrun whose solve did not prove optimality.

Without this, the only failure mode that surfaces is a solve with NO primal solution at all
(`value()` throws inside `fetch_results`). A solve that stopped early WITH an incumbent —
`TIME_LIMIT`, `SUBOPTIMAL`, `ITERATION_LIMIT`, `NUMERICAL_ERROR` — writes its Arrow tables
exactly like a proven optimum, and a driver that records success from the absence of an
exception then reports it as fine. Throwing here turns that silent case into the loud one
that existing `try`/`catch` scenario bookkeeping already handles correctly.
"""
function assert_optimal(status, sr::SubRun, label::String="")
    status == MOI.OPTIMAL && return nothing
    t1, tend = sr.market_state.Time[[1, end]]
    prefix = isempty(label) ? "" : "[$label] "
    error("$(prefix)subrun t$(t1)-t$(tend) did not solve to OPTIMAL (status = $status). " *
          "Refusing to persist results for this split: a solver that stops early with an " *
          "incumbent produces result tables indistinguishable from a proven optimum.")
end


