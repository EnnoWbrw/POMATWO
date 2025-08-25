"""
    run(mr::ModelRun)

Executes the configured POMATWO model simulation for the given [`ModelRun`](@ref) object.

Saves input parameters to the results folder and runs the internal optimization routine.

# Arguments
- `mr::ModelRun`: The simulation object containing model configuration and input data.

# Side Effects
- Writes `params.jld2` to the scenario output directory.
- Stores simulation results in output files.
"""
function run(mr::ModelRun)
    @info "Saving parameters to results folder"
    save_object(joinpath(mr.scen_dir, "params.jld2"), mr.params)
    _run(mr)
end

"""
    _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:NoProsumer, RD<:NoRedispatch}

Runs the market simulation for zonal or nodal market types without prosumer optimization.
Performs day-ahead optimization and stores results for each time split.
"""
function _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:NoProsumer, RD<:NoRedispatch}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
   _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:ProsumerOptimization, RD<:NoRedispatch}

Runs the market simulation for zonal or nodal market types with prosumer optimization.
Performs day-ahead optimization, then prosumer optimization, and stores results for each time split.
"""
function _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:ProsumerOptimization, RD<:NoRedispatch}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        # Prosumer optimization
        ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
        da_results = prev_results_for_redispatch(sr)
        da_results[:price] = get_balance(mr.setup.MarketType, sr)
        market_state = ProsumerOptimizationState(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
        @suppress optimize!(sr)
        fetch_results(sr)
        write_results(sr)
        da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:NoProsumer, RD<:RedispatchType}

Runs the market simulation for nodal or zonal market types with redispatch and no prosumer optimization.
Performs day-ahead and redispatch optimization, storing results for each time split.
"""
function _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:NoProsumer, RD<:RedispatchType}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        da_results = prev_results_for_redispatch(sr)
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Redispatch -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        if termination_status(sr.optigraph) != MOI.OPTIMAL
            @show termination_status(sr.optigraph)
        end
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:ProsumerOptimization, RD<:RedispatchType}

Runs the market simulation for nodal or zonal market types with redispatch and prosumer optimization.
Performs day-ahead, prosumer, and redispatch optimization, storing results for each time split.
"""
function _run(mr::ModelRun{MT, PS, RD}) where {MT<:MarketType, PS<:ProsumerOptimization, RD<:RedispatchType}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        da_results = prev_results_for_redispatch(sr)
        # Prosumer optimization
        ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
        da_results = prev_results_for_redispatch(sr)
        da_results[:price] = get_balance(mr.setup.MarketType, sr)
        market_state = ProsumerOptimizationState(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
        @suppress optimize!(sr)
        fetch_results(sr)
        write_results(sr)
        da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Redispatch -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        if termination_status(sr.optigraph) != MOI.OPTIMAL
            @show termination_status(sr.optigraph)
        end
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end
