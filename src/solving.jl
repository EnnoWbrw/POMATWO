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
    calc_intraday_fbmc_params(sr_redispatch::SubRun, intraday_params::Parameters, T::UnitRange{Int}; minRAM::Float64=0.7, FRM::Float64=0.1)

Calculates intraday FBMC parameters from the latest redispatch results of the day-ahead chain.
This recalculates GSK/PTDF/RAM for the intraday model using the intraday availability setup
and redispatch network state of the same day chunk.
"""
function calc_intraday_fbmc_params(sr_redispatch::SubRun, intraday_params::Parameters, T::UnitRange{Int}; minRAM::Float64=0.7, FRM::Float64=0.1)
    market_type = sr_redispatch.modelrun.setup.MarketType
    gsk_strategy = market_type.exchange_formulation.GSKStrategy

    gsk = build_gsk(intraday_params, gsk_strategy)
    ptdf_nodal = dict_to_matrix(intraday_params.ptdf)
    ptdf_zonal = zonal_ptdf(ptdf_nodal, gsk)
    ptdf_zz = zone_to_zone_ptdf(ptdf_zonal; exclude_self=true)
    define_cne!(intraday_params, ptdf_zz; threshold=0.05)

    cne = intraday_params.cne
    ptdf_zonal = ptdf_zonal[cne, :]
    ptdf_zz = ptdf_zz[cne, :]

    redispatch_results = prev_results_for_fbmc(sr_redispatch)
    ram = calc_ram(intraday_params, redispatch_results, ptdf_zonal, ptdf_zz, ptdf_nodal, T; minRAM=minRAM, FRM=FRM)

    return Dict(
        :GSK => gsk,
        :PTDFn => ptdf_nodal,
        :PTDFz => ptdf_zonal,
        :PTDFzz => ptdf_zz,
        :RAM => ram,
    )
end


"""
    _run_intraday(mr_dayahead::ModelRun{ZonalMarket{FlowBased}, PS, RD}, mr_intraday::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:RedispatchType}

Runs the full daily chain for flow-based markets:
TwoDayAhead -> DayAhead -> Redispatch -> Intraday(DayAhead equations) -> Redispatch.

Use `mr_dayahead` with day-ahead availability input and `mr_intraday` with intraday availability input.
Both model runs must share the same horizon split.
"""
function _run_intraday(mr_dayahead::ModelRun{ZonalMarket{FlowBased}, PS, RD}, mr_intraday::ModelRun{ZonalMarket{FlowBased}, PS, RD}) where {PS<:NoProsumer, RD<:RedispatchType}
    if split(mr_dayahead.setup.TimeHorizon) != split(mr_intraday.setup.TimeHorizon)
        error("DayAhead and Intraday time splits must be identical.")
    end

    validation_report_da = validate_params(mr_dayahead.params, mr_dayahead.setup)
    if has_issues(validation_report_da)
        print_report(validation_report_da; show_notes=false, show_warnings=false, show_errors=true)
    end
    if validation_report_da.has_errors
        error("DayAhead parameter validation failed.")
    end

    validation_report_id = validate_params(mr_intraday.params, mr_intraday.setup)
    if has_issues(validation_report_id)
        print_report(validation_report_id; show_notes=false, show_warnings=false, show_errors=true)
    end
    if validation_report_id.has_errors
        error("Intraday parameter validation failed.")
    end

    save_object(joinpath(mr_dayahead.scen_dir, "params.jld2"), mr_dayahead.params)
    save_object(joinpath(mr_intraday.scen_dir, "params.jld2"), mr_intraday.params)

    for T in split(mr_dayahead.setup.TimeHorizon)
        @info "Starting DA-ID chain subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DA-ID Chain", spinner = true, dt = 0.1)

        # 1) TwoDayAhead basecase on day-ahead setup
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Building Model")
        market_state = TwoDayAhead(T)
        sr_2da = SubRun(mr_dayahead, market_state)
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Optimizing")
        @suppress optimize!(sr_2da)
        log_status(sr_2da, "TwoDayAhead")
        ProgressMeter.update!(prog, desc = "TwoDayAhead -> Fetching Results")
        fetch_results(sr_2da)
        write_results_2DA(sr_2da)

        # 2) DayAhead with FBMC from TwoDayAhead
        fbmc_params_dayahead = calc_fbmc_params(sr_2da, mr_dayahead.params, prev_results_for_fbmc(sr_2da), T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr_da = SubRun(mr_dayahead, DayAhead(T, fbmc_params_dayahead))
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr_da)
        log_status(sr_da, "DayAhead")
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr_da)
        write_results(sr_da)

        # 3) Redispatch after DayAhead
        ProgressMeter.update!(prog, desc = "Redispatch(DA) -> Building Model")
        sr_redisp_da = SubRun(mr_dayahead, Redispatch(T, prev_results_for_redispatch(sr_da)))
        ProgressMeter.update!(prog, desc = "Redispatch(DA) -> Optimizing")
        @suppress optimize!(sr_redisp_da)
        log_status(sr_redisp_da, "Redispatch(DA)")
        ProgressMeter.update!(prog, desc = "Redispatch(DA) -> Fetching Results")
        fetch_results(sr_redisp_da)
        write_results(sr_redisp_da)

        # 4) Intraday DayAhead with updated intraday availability + FBMC from DA redispatch
        fbmc_params_intraday = calc_intraday_fbmc_params(sr_redisp_da, mr_intraday.params, T)
        ProgressMeter.update!(prog, desc = "Intraday -> Building Model")
        sr_id = SubRun(mr_intraday, DayAhead(T, fbmc_params_intraday))
        ProgressMeter.update!(prog, desc = "Intraday -> Optimizing")
        @suppress optimize!(sr_id)
        log_status(sr_id, "Intraday")
        ProgressMeter.update!(prog, desc = "Intraday -> Fetching Results")
        fetch_results(sr_id)
        write_results(sr_id)

        # 5) Redispatch after Intraday
        ProgressMeter.update!(prog, desc = "Redispatch(ID) -> Building Model")
        sr_redisp_id = SubRun(mr_intraday, Redispatch(T, prev_results_for_redispatch(sr_id)))
        ProgressMeter.update!(prog, desc = "Redispatch(ID) -> Optimizing")
        @suppress optimize!(sr_redisp_id)
        log_status(sr_redisp_id, "Redispatch(ID)")
        ProgressMeter.update!(prog, desc = "Redispatch(ID) -> Fetching Results")
        fetch_results(sr_redisp_id)
        write_results(sr_redisp_id)

        finish!(prog, desc = "Subrun -> Done")
    end
end

