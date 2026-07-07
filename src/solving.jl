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
    for c in mr.setup.components
        errs = validate_component(c, mr.params, mr.setup)
        if !isempty(errs)
            error("Validation of component :$(label(c)) failed:\n" * join(errs, "\n"))
        end
    end
    @info "Saving parameters to results folder"
    save_object(joinpath(mr.scen_dir, "params.jld2"), mr.params)
    _run(mr)
end

### State pipeline
#
# A model run is an ordered sequence of MarketStates per time split. The sequence is
# a function of the setup (`state_sequence`); each state is constructed from the
# running context (`init_state`), solved, and feeds the context for later states
# (`postprocess!`). This replaces the former per-setup `_run` methods.

"""
    state_sequence(setup::ModelSetup) -> Vector{DataType}

Ordered `MarketState` types solved per time split for the given setup.
"""
state_sequence(::ModelSetup{MT,PS,RD}) where {MT<:MarketType,PS<:NoProsumer,RD<:NoRedispatch} =
    [DayAhead]
state_sequence(::ModelSetup{MT,PS,RD}) where {MT<:MarketType,PS<:ProsumerOptimization,RD<:NoRedispatch} =
    [DayAhead, ProsumerOptimizationState]
state_sequence(::ModelSetup{MT,PS,RD}) where {MT<:MarketType,PS<:NoProsumer,RD<:RedispatchType} =
    [DayAhead, Redispatch]
state_sequence(::ModelSetup{MT,PS,RD}) where {MT<:MarketType,PS<:ProsumerOptimization,RD<:RedispatchType} =
    [DayAhead, ProsumerOptimizationState, Redispatch]

# Flow-based zonal markets need the TwoDayAhead basecase to derive FBMC parameters.
state_sequence(::ModelSetup{ZonalMarket{FlowBased},PS,RD}) where {PS<:NoProsumer,RD<:NoRedispatch} =
    [TwoDayAhead, DayAhead]
state_sequence(::ModelSetup{ZonalMarket{FlowBased},PS,RD}) where {PS<:NoProsumer,RD<:RedispatchType} =
    [TwoDayAhead, DayAhead, Redispatch]
state_sequence(::ModelSetup{ZonalMarket{FlowBased},PS,RD}) where {PS<:ProsumerOptimization,RD<:RedispatchSetup} =
    error("Flow-based zonal markets with prosumer optimization are not supported yet.")

"""
    init_state(::Type{<:MarketState}, mr::ModelRun, T, ctx::Dict) -> MarketState

Construct the next market state for time range `T` from the running context `ctx`
(results of previously solved states in the same split).
"""
init_state(::Type{TwoDayAhead}, mr::ModelRun, T, ctx::Dict) = TwoDayAhead(T)
init_state(::Type{DayAhead}, mr::ModelRun, T, ctx::Dict) = DayAhead(T, get(ctx, :fbmc_params, nothing))
init_state(::Type{ProsumerOptimizationState}, mr::ModelRun, T, ctx::Dict) =
    ProsumerOptimizationState(T, ctx[:da_results])
init_state(::Type{Redispatch}, mr::ModelRun, T, ctx::Dict) = Redispatch(T, ctx[:da_results])

"""
    postprocess!(sr::SubRun, ctx::Dict)

Extract the solved subrun's results that later states in the same split need and
store them in `ctx`. Called after every solve except the last state of a split.
"""
postprocess!(sr::SubRun, ctx::Dict) = nothing

# NOTE: the type variables MT/PS/RD must carry their upper bounds explicitly here.
# With unbounded variables Julia's method-specificity ranking does not consider these
# methods more specific than the `sr::SubRun` fallback above, and the fallback wins.

function postprocess!(
    sr::SubRun{MT,PS,RD,MS}, ctx::Dict,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:TwoDayAhead}
    basecase_results = prev_results_for_fbmc(sr)
    ctx[:fbmc_params] =
        calc_fbmc_params(sr, sr.modelrun.params, basecase_results, sr.market_state.Time)
    return nothing
end

function postprocess!(
    sr::SubRun{MT,PS,RD,MS}, ctx::Dict,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DayAhead}
    da_results = prev_results_for_redispatch(sr)
    da_results[:price] = get_balance(sr.modelrun.setup.MarketType, sr)
    ctx[:da_results] = da_results
    return nothing
end

function postprocess!(
    sr::SubRun{MT,PS,RD,MS}, ctx::Dict,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:ProsumerOptimizationState}
    # fix optimized prosumer behaviour for the subsequent redispatch stage
    ctx[:da_results][:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
    return nothing
end

# filename prefix for result files of a state (TwoDayAhead results are prefixed "2DA")
result_prefix(::MarketState) = ""
result_prefix(::TwoDayAhead) = "2DA"

# progress/log label of a state
state_label(::Type{TwoDayAhead}) = "TwoDayAhead"
state_label(::Type{DayAhead}) = "DayAhead"
state_label(::Type{ProsumerOptimizationState}) = "Prosumer"
state_label(::Type{Redispatch}) = "Redispatch"
state_label(::Type{MS}) where {MS<:MarketState} = string(nameof(MS))

"""
    _run(mr::ModelRun)

Runs the market simulation: for every time split, solves the setup's
[`state_sequence`](@ref) and stores results.
"""
function _run(mr::ModelRun)
    seq = state_sequence(mr.setup)
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        _run_states(mr, T, Dict{Symbol,Any}(), seq)
    end
end

function _run_states(mr::ModelRun, T, ctx::Dict{Symbol,Any}, seq::Vector{DataType})
    prog = ProgressUnknown(desc = state_label(seq[1]), spinner = true, dt = 0.1)
    for (i, ST) in enumerate(seq)
        lbl = state_label(ST)
        ProgressMeter.update!(prog, desc = "$lbl -> Building Model")
        market_state = init_state(ST, mr, T, ctx)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "$lbl -> Optimizing")
        @suppress optimize!(sr)
        log_status(sr, lbl)
        ProgressMeter.update!(prog, desc = "$lbl -> Fetching Results")
        fetch_results(sr)
        write_results(sr; prefix = result_prefix(market_state))
        i < length(seq) && postprocess!(sr, ctx)
    end
    finish!(prog, desc = "Subrun -> Done")
    return ctx
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
        ctx = Dict{Symbol,Any}(:fbmc_params => fbmc_params)
        _run_states(mr, T, ctx, [DayAhead, Redispatch])
    end
end
