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
        @info "Validating parameters"
    validation_report = validate_params(mr.params, mr.setup)
    if has_issues(validation_report)
        print_report(validation_report; show_notes=false, show_warnings = false, show_errors = true)
    end
    if validation_report.has_errors
        error("Parameter validation failed. Use validate_params(params, setup) for detailed diagnostics.")
    end
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
        log_status(sr, "DayAhead")
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
        log_status(sr, "DayAhead")
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
        log_status(sr, "Prosumer")
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
        log_status(sr, "DayAhead")
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
        log_status(sr, "Redispatch")
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
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
        log_status(sr, "DayAhead")
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
        log_status(sr, "Prosumer")
        fetch_results(sr)
        write_results(sr)
        da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Redispatch -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "Redispatch")
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:RedispatchType}

Runs the market simulation for flow-based zonal markets with redispatch and no prosumer optimization.
Performs TwoDayAhead basecase optimization, calculates FBMC parameters, then day-ahead and redispatch optimization, storing results for each time split.
"""
function _run(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:RedispatchType}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        # Basecase / TwoDayAhead optimization
        prog = ProgressUnknown(desc = "TwoDayAhead - Basecase", spinner = true, dt = 0.1)
        market_state = TwoDayAhead(T)
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "TwoDayAhead")
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Fetching Results")
        fetch_results(sr)
        write_results_2DA(sr)
        TwoDayAhead_results = prev_results_for_fbmc(sr)
        # Calculate FBMC parameters from TwoDayAhead basecase
        fbmc_params = calc_fbmc_params(sr,mr.params, TwoDayAhead_results,T)
        # Zonal flow-based market optimization
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        market_state = DayAhead(T, fbmc_params)

        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "DayAhead")
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
        log_status(sr, "Redispatch")
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:NoRedispatch}

Runs the market simulation for flow-based zonal markets without redispatch and no prosumer optimization.
Performs TwoDayAhead basecase optimization, calculates FBMC parameters, then day-ahead optimization only, storing results for each time split.
"""
function _run(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:NoRedispatch}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        # Basecase / TwoDayAhead optimization
        prog = ProgressUnknown(desc = "TwoDayAhead - Basecase", spinner = true, dt = 0.1)
        market_state = TwoDayAhead(T)
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "TwoDayAhead")
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Fetching Results")
        fetch_results(sr)
        write_results_2DA(sr)
        TwoDayAhead_results = prev_results_for_fbmc(sr)
        # Calculate FBMC parameters from TwoDayAhead basecase
        fbmc_params = calc_fbmc_params(sr, mr.params, TwoDayAhead_results,T)
        # Zonal flow-based market optimization
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        market_state = DayAhead(T, fbmc_params)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "DayAhead")
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run_intraday(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}, fbmc_params::Dict) where {PS<:NoProsumer, RD<:RedispatchType}

Runs the intraday market simulation for flow-based zonal markets with redispatch.
Uses pre-calculated FBMC parameters (from redispatch results) and updated availability data.
Performs day-ahead and redispatch optimization for intraday market, storing results for each time split.

# Arguments
- `mr::ModelRun`: The intraday model run with updated parameters and availability data (including avail_plants_ID.csv)
- `fbmc_params::Dict`: Pre-calculated FBMC parameters (typically extracted from previous day's redispatch results)

# Example
```julia
# After DA + Redispatch run, get redispatch results:
# (sr is the SubRun object from the redispatch optimization)
redispatch_results = prev_results_for_fbmc(sr)
fbmc_params_intraday = calc_fbmc_params(sr, mr.params, redispatch_results)

# Create intraday ModelRun with updated availability and run
data_files_intraday = Dict(
    # ... other files ...
    :avail => "avail_plants_ID.csv",  # Updated to ID version
)
params_intraday, _ = load_data_with_report(data_files_intraday)
mr_intraday = ModelRun(params_intraday, setup_intraday, solver;
                       scenarioname="intraday", resultdir=output_path, overwrite=true)
_run_intraday(mr_intraday, fbmc_params_intraday)
```
"""
function _run_intraday(mr::ModelRun{ZonalMarket{FlowBased}, PS, RD}, fbmc_params::Dict) where {PS<:NoProsumer, RD<:RedispatchType}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting intraday subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "Intraday - DayAhead", spinner = true, dt = 0.1)
        
        # Zonal flow-based market optimization with updated FBMC params and availability
        ProgressMeter.update!(prog, desc = "Intraday DayAhead -> Building Model")
        market_state = DayAhead(T, fbmc_params)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Intraday DayAhead -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "Intraday DayAhead")
        ProgressMeter.update!(prog, desc = "Intraday DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        da_results = prev_results_for_redispatch(sr)
        
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Intraday Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Intraday Redispatch -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, "Intraday Redispatch")
        ProgressMeter.update!(prog, desc = "Intraday Redispatch -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Intraday Subrun -> Done")
    end
end

