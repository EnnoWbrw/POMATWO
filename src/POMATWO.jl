module POMATWO
import MathOptInterface as MOI
using JuMP,
    JuMP.Containers,
    DataFrames,
    DataFramesMeta,
    Dates,
    Plasmo,
    UnPack,
    TimerOutputs,
    Arrow,
    JLD2,
    Random,
    ProgressMeter,
    CSV,
    CategoricalArrays,
    Statistics,
    LinearAlgebra

# Fix for Plasmo 0.5.4 compatibility with JuMP 1.27+
# Tell JuMP what variable reference type to use for OptiNode
JuMP.variable_ref_type(::Type{Plasmo.OptiNode}) = JuMP.VariableRef

function plot_DA_w_Redisp_interactive end
function plot_market_interactive end
function plot_network end 
function plot_total_gen_interactive end
function create_lineplot end
function plot_market_statistics end

include("utils/GSK_strategies.jl")
include("market_definitions.jl")
include("components.jl")
include("model_structs.jl")
include("data_report.jl")
include("utils/fbmc_utils.jl")
include("utils/data_load_utils.jl")
include("utils/df_utils.jl")
include("utils/time_utils.jl")
include("utils/get_vals_utils.jl")
include("utils/model_utils.jl")
include("data_load.jl")
include("read_output.jl")
include("utils/refday_matching.jl")
include("utils/refday_basecase.jl")
include("energy_balances.jl")
include("technologies.jl")
include("prosumer.jl")
include("solving.jl")

export load_data,
    ModelSetup,
    ModelRun,
    run,
    DataFiles,
    TimeHorizon,
    MarketType,
    ZonalMarket,
    NodalMarket,
    ProsumerSetup,
    NoProsumer,
    ProsumerOptimization,
    RedispatchSetup,
    NoRedispatch,
    DCLF,
    StorageBoundary,
    CarryOverStorage,
    CyclicStorage,
    PhaseAngle,
    ExchangeFormulation,
    NTC,
    FlowBased,
    optimizer_with_attributes,
    MOI,
    summarize_result,
    transform_results_by_type,
    plot_DA_w_Redisp_interactive, 
    plot_market_interactive, 
    plot_network, 
    plot_total_gen_interactive,
    create_lineplot,
    DataReport,
    DataReportLevel,
    DataReportItem,
    print_report,
    export_report,
    load_data_with_report,
    get_errors,
    get_warnings,
    get_notes,
    get_redispatch_by_type_node,
    get_market_statistics,
    plot_market_statistics,
    build_gsk,
    zonal_ptdf,
    GSKStrategy,
    FlatGSK,
    GmaxGSK,
    DispOnlyGSK,
    CustomWeightsGSK,
    validate_params,
    check_infeasibility,
    # component extension interface
    ModelComponent,
    build!,
    injection,
    collect_results!,
    validate_component,
    BalanceScope,
    NodalScope,
    ZonalScope,
    balance_scope,
    # state pipeline
    MarketState,
    DayAhead,
    TwoDayAhead,
    ProsumerOptimizationState,
    Redispatch,
    state_sequence,
    # reference-day (D2CF-style) basecase
    BasecaseMethod,
    OptimizationBasecase,
    ReferenceDayBasecase,
    MatchingConfig,
    MatchScope,
    GlobalMatchScope,
    ZonalMatchScope,
    AreaMatchScope,
    ShiftMethod,
    ShareShift,
    RedistKey,
    GSKRedist,
    RefPropRedist,
    LoadPropRedist,
    match_by_cluster,
    match_by_scope,
    build_refday_basecase,
    calc_fbmc_params

end # module POMATWO
