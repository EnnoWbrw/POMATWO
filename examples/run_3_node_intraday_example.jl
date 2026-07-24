# import Pkg
# Pkg.develop is not needed when running from within the POMATWO package directory
# Pkg.develop(path =".../POMATWO_merged_main__zonal_ptdf")

using POMATWO
using HiGHS
using DataFrames
using JLD2
using JuMP

# Resolve paths relative to this example file so it works from any working directory.
datapath = joinpath(@__DIR__, "test_data_3_nodes_intraday")

# define dictionary with all necessary data sets
data_files= Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
    :avail_planttype_nodal => joinpath(datapath, "nodal_availability_DA")
)

params, report = load_data_with_report(data_files)

print_report(report; show_notes = false, show_warnings=false)


# set scenario name 
scen_name = "test_intraday_example"

# define output path for data transfer
result_root = joinpath(@__DIR__, "results_intraday_example")
output_path = result_root

setup = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4), 
    MarketType = ZonalMarket(FlowBased(DispOnlyGSK())),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

solver = HiGHS.Optimizer

intraday = 1  # Set to 1 to run intraday market
scen_dir = joinpath(output_path, scen_name)
mr = ModelRun(params, setup, solver; scenarioname = "DA", resultdir = scen_dir, overwrite=true)

if intraday == 1
    @info "Starting full DA-ID chain run"

    # Load intraday data with updated nodal availability profiles
    data_files_intraday = Dict{Symbol,String}(
        :plants => joinpath(datapath, "plants.csv"),
        :nodes => joinpath(datapath, "nodes.csv"),
        :zones => joinpath(datapath, "zones.csv"),
        :lines => joinpath(datapath, "lines.csv"),
        :dclines => joinpath(datapath, "dclines.csv"),
        :demand => joinpath(datapath, "nodal_load.csv"),
        :types => joinpath(datapath, "planttypes.csv"),
        :avail_planttype_nodal => joinpath(datapath, "nodal_availability_ID")
   )

    params_intraday, report_intraday = load_data_with_report(data_files_intraday)
    print_report(report_intraday; show_notes=false, show_warnings=false)

    setup_intraday = ModelSetup(;
        TimeHorizon = TimeHorizon(stop=4),
        MarketType = ZonalMarket(FlowBased(DispOnlyGSK())),
        ProsumerSetup = NoProsumer(),
        RedispatchSetup = DCLF(PhaseAngle)
    )

    mr_intraday = ModelRun(
        params_intraday,
        setup_intraday,
        solver;
        scenarioname = "ID",
        resultdir = scen_dir,
        overwrite = true
    )

    # Run full daily chain: TwoDayAhead -> DayAhead -> Redispatch -> Intraday -> Redispatch
    POMATWO._run_intraday(mr, mr_intraday)
    @info "DA-ID chain run complete"
else
    POMATWO.run(mr)
end

# Check if results directory was created
result_dir = joinpath(result_root, scen_name, "DA")
if !isdir(result_dir)
    error("Results directory was not created: $result_dir")
end

@info "Loading DA results from $result_dir"
results = DataFiles(result_dir)

results_intraday = nothing
if intraday == 1
    intraday_result_dir = joinpath(result_root, scen_name, "ID")
    if isdir(intraday_result_dir)
        results_intraday = DataFiles(intraday_result_dir)
        @info "Loading intraday results from $intraday_result_dir"
    else
        @warn "Intraday results directory not found" intraday_result_dir
    end
end

### Export results to CSV
using CSV, DataFrames, DataFramesMeta, Statistics

function export_csv_results(results_data::DataFiles, output_dir::String)
     # 1. Calculate high utilization lines (>95% capacity)
    line_utilization = @chain results_data.LINEFLOW begin
        @rtransform :utilization = abs(:LINEFLOW) / :line_capacity
        @rtransform :high_util = :utilization >= 0.95
        @by :index begin
            :count_high_util = sum(:high_util)
            :avg_utilization = mean(:utilization)
            :max_utilization = maximum(:utilization)
        end
    end

    # 2. Hourly line flow per line
    hourly_lineflow = @chain results_data.LINEFLOW begin
        select(:index, :Time, :LINEFLOW)
        rename(:index => :Line)
        sort([:Line, :Time])
    end

    # 3. Hourly market price per zone
    hourly_prices = @chain results_data.ZonalMarketBalance begin
        select(:Zone, :Time, :MarketBalance)
        rename(:MarketBalance => :Price)
        sort([:Zone, :Time])
    end

    mkpath(output_dir)
    CSV.write(joinpath(output_dir, "line_utilization.csv"), line_utilization)
    CSV.write(joinpath(output_dir, "hourly_lineflow.csv"), hourly_lineflow)
    CSV.write(joinpath(output_dir, "hourly_prices.csv"), hourly_prices)
end

export_csv_results(results, joinpath(result_root, scen_name, "DA"))

if intraday == 1
    if results_intraday !== nothing
        export_csv_results(results_intraday, joinpath(result_root, scen_name, "ID"))
    end
end

using GLMakie, ColorSchemes, Tyler, Colors

## creating a graph to visualize day ahead generation levels over time
#intraday results
plot_DA_w_Redisp_interactive(results_intraday)
#dayahead results
plot_DA_w_Redisp_interactive(results)

### create barplot to summarize generation by technology in the observed time horizon
plot_total_gen_interactive(results)
