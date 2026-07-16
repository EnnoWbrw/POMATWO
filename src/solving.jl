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

# Flow-based zonal markets need a basecase to derive FBMC parameters. With the
# default OptimizationBasecase this is the TwoDayAhead optimization state; with
# ReferenceDayBasecase the basecase comes from a previous run's results, is
# built once before the split loop (see _prepare_refday_artifacts) and the
# TwoDayAhead state is skipped entirely.
_basecase_states(setup::ModelSetup{ZonalMarket{FlowBased}}) =
    setup.MarketType.exchange_formulation.basecase isa OptimizationBasecase ?
        DataType[TwoDayAhead] : DataType[]

state_sequence(setup::ModelSetup{ZonalMarket{FlowBased},PS,RD}) where {PS<:NoProsumer,RD<:NoRedispatch} =
    vcat(_basecase_states(setup), DataType[DayAhead])
state_sequence(setup::ModelSetup{ZonalMarket{FlowBased},PS,RD}) where {PS<:NoProsumer,RD<:RedispatchType} =
    vcat(_basecase_states(setup), DataType[DayAhead, Redispatch])
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
    record_carry!(sr::SubRun, ctx::Dict)

Store cross-split state from a solved subrun in `ctx` (e.g. end-of-split storage
levels under [`CarryOverStorage`](@ref)). Called after every solve; the keys listed
in `CARRY_KEYS` survive into the next time split's context.
"""
record_carry!(sr::SubRun, ctx::Dict) = record_carry!(sr.modelrun.setup.StorageBoundary, sr, ctx)
record_carry!(::StorageBoundary, sr::SubRun, ctx::Dict) = nothing

function record_carry!(
    ::CarryOverStorage, sr::SubRun{MT,PS,RD,MS}, ctx::Dict,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DayAhead}
    S = sr.modelrun.params.sets.S
    isempty(S) && return nothing
    STO_LVL = sr.vars[:sto][:STO_LVL]
    tend = sr.market_state.Time[end]
    ctx[:sto_lvl_start] = Dict(s => value(STO_LVL[s, tend]) for s in S)
    return nothing
end

function record_carry!(
    ::CarryOverStorage, sr::SubRun{MT,PS,RD,MS}, ctx::Dict,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:Redispatch}
    S = sr.modelrun.params.sets.S
    isempty(S) && return nothing
    STO_LVL = sr.vars[:sto][:STO_LVL_REDISP]
    tend = sr.market_state.Time[end]
    ctx[:sto_lvl_start_redisp] = Dict(s => value(STO_LVL[s, tend]) for s in S)
    return nothing
end

# context keys that survive from one time split into the next
const CARRY_KEYS = (:sto_lvl_start, :sto_lvl_start_redisp)

# Splits are independent unless storage levels are carried between them.
_parallel_splits_ok(mr::ModelRun) =
    !(mr.setup.StorageBoundary isa CarryOverStorage) || isempty(mr.params.sets.S)

"""
    _run(mr::ModelRun)

Runs the market simulation: for every time split, solves the setup's
[`state_sequence`](@ref) and stores results.

When Julia is started with multiple threads (`julia -t N`) and the splits are
independent, they are solved in parallel. Under [`CarryOverStorage`](@ref) (with a
non-empty storage set) splits depend on each other and are solved sequentially,
passing the cross-split state (`CARRY_KEYS`, e.g. carried storage levels) from each
split into the next.
"""
function _run(mr::ModelRun)
    seq = state_sequence(mr.setup)
    splits = split(mr.setup.TimeHorizon)
    refday_artifacts = _prepare_refday_artifacts(mr)

    if Threads.nthreads() > 1 && length(splits) > 1 && _parallel_splits_ok(mr)
        @info "Solving $(length(splits)) time splits in parallel on $(Threads.nthreads()) threads"
        Threads.@threads for i in eachindex(splits)
            ctx = Dict{Symbol,Any}()
            _seed_fbmc!(ctx, mr, splits[i], refday_artifacts)
            _run_states(mr, splits[i], ctx, seq; show_progress = false)
        end
    else
        carry = Dict{Symbol,Any}()
        for T in splits
            @info "Starting subrun for period from $(T[1]) to $(T[end])"
            ctx = Dict{Symbol,Any}(carry)
            _seed_fbmc!(ctx, mr, T, refday_artifacts)
            _run_states(mr, T, ctx, seq)
            for k in CARRY_KEYS
                haskey(ctx, k) && (carry[k] = ctx[k])
            end
        end
    end
end

"""
    _prepare_refday_artifacts(mr::ModelRun) -> Union{Dict,Nothing}

For flow-based zonal runs configured with a [`ReferenceDayBasecase`](@ref),
build the whole-horizon basecase (`:netinput_ac`, `:lineflows`) once before the
split loop. Returns `nothing` for every other setup (incl. the default
`OptimizationBasecase`, whose basecase is the solved `TwoDayAhead` state).
"""
_prepare_refday_artifacts(mr::ModelRun) = _prepare_refday_artifacts(mr.setup.MarketType, mr)
_prepare_refday_artifacts(::MarketType, mr::ModelRun) = nothing
function _prepare_refday_artifacts(mt::ZonalMarket{FlowBased}, mr::ModelRun)
    bc = mt.exchange_formulation.basecase
    bc isa ReferenceDayBasecase || return nothing
    src = bc.source isa DataFiles ? "preloaded DataFiles" : bc.source
    @info "Building reference-day FBMC basecase (source: $src)"
    artifacts = build_refday_basecase(bc, mr.params)
    # time-independent trace table: written once at the scenario root (like
    # params.jld2) so DataFiles' subrun vcat does not duplicate its rows
    haskey(artifacts, :trace) && Arrow.write(
        joinpath(mkpath(mr.scen_dir), "REFDAY_GROUPS.arrow"),
        artifacts[:trace][:REFDAY_GROUPS])
    return artifacts
end

"""
    _seed_fbmc!(ctx, mr, T, artifacts)

Seed `ctx[:fbmc_params]` for split `T` from precomputed reference-day basecase
artifacts (no-op when `artifacts === nothing`). Mirrors what
`postprocess!(::TwoDayAhead)` does for the optimization basecase. Also writes
the split's slice of the reference-day trace tables into the subrun folder
(see `_write_refday_trace`).
"""
function _seed_fbmc!(ctx::Dict{Symbol,Any}, mr::ModelRun, T, artifacts)
    artifacts === nothing && return nothing
    covered = Set(collect(axes(artifacts[:netinput_ac], 2)))
    all(t -> t in covered, T) || error(
        "ReferenceDayBasecase: split $(T) is not fully covered by the reference-day " *
        "basecase (source horizon: $(extrema(collect(covered)))). The current run's " *
        "TimeHorizon must lie inside the forecast run's time steps.")
    gsk = mr.setup.MarketType.exchange_formulation.GSKStrategy
    ctx[:fbmc_params] = calc_fbmc_params(gsk, mr.params, artifacts, T)
    _write_refday_trace(mr, T, artifacts)
    return nothing
end

"""
    _write_refday_trace(mr::ModelRun, T, artifacts)

Write the reference-day trace tables sliced to split `T` as Arrow files into
the split's subrun folder (`REFDAY_MATCH`, `REFDAY_SHIFT`; the time-independent
`REFDAY_GROUPS` lives at the scenario root). No-op when the artifacts carry no
`:trace`. Thread-safe under parallel splits: each split writes only into its
own folder and the shared trace frames are never mutated.
"""
function _write_refday_trace(mr::ModelRun, T, artifacts)
    trace = artifacts === nothing ? nothing : get(artifacts, :trace, nothing)
    trace === nothing && return nothing
    sr_dir = mkpath(joinpath(mr.scen_dir, "subrun_t$(T[1])-t$(T[end])"))
    Tset = Set(T)
    for (name, timecol) in ((:REFDAY_MATCH, :target_time), (:REFDAY_SHIFT, :Time))
        df = trace[name]
        isempty(df) || (df = filter(timecol => in(Tset), df))
        Arrow.write(joinpath(sr_dir, string(name) * ".arrow"), df)
    end
    return nothing
end

function _run_states(
    mr::ModelRun, T, ctx::Dict{Symbol,Any}, seq::Vector{DataType};
    show_progress::Bool = true,
)
    prog = show_progress ? ProgressUnknown(desc = state_label(seq[1]), spinner = true, dt = 0.1) : nothing
    for (i, ST) in enumerate(seq)
        lbl = state_label(ST)
        isnothing(prog) || ProgressMeter.update!(prog, desc = "$lbl -> Building Model")
        market_state = init_state(ST, mr, T, ctx)
        sr = SubRun(mr, market_state, ctx)
        isnothing(prog) || ProgressMeter.update!(prog, desc = "$lbl -> Optimizing")
        optimize!(sr)  # silent unless ModelRun(verbose = true); see _silent_solver
        log_status(sr, lbl)
        isnothing(prog) || ProgressMeter.update!(prog, desc = "$lbl -> Fetching Results")
        fetch_results(sr)
        write_results(sr; prefix = result_prefix(market_state))
        record_carry!(sr, ctx)
        i < length(seq) && postprocess!(sr, ctx)
    end
    isnothing(prog) || finish!(prog, desc = "Subrun -> Done")
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
    carry = Dict{Symbol,Any}()
    for T in split(mr.setup.TimeHorizon)
        @info "Starting intraday subrun for period from $(T[1]) to $(T[end])"
        ctx = Dict{Symbol,Any}(carry)
        ctx[:fbmc_params] = fbmc_params
        _run_states(mr, T, ctx, [DayAhead, Redispatch])
        for k in CARRY_KEYS
            haskey(ctx, k) && (carry[k] = ctx[k])
        end
    end
end
