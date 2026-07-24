# import Pkg
# Pkg.develop is not needed when running from within the POMATWO package directory
# Pkg.develop(path =".../POMATWO_merged_main__zonal_ptdf")

using POMATWO
using HiGHS

# Load the 3-node intraday test data
# The loader expects one plant type per nodal availability file.
datapath = joinpath("examples", "test_data_3_nodes_intraday")

data_files = Dict{Symbol,String}(
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
print_report(report; show_notes = false, show_warnings = false)

scen_name = "test_intraday_example"
result_root = joinpath("examples", "results_intraday_example")
scen_dir = joinpath(result_root, scen_name)

setup = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(FlowBased(DispOnlyGSK())),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

solver = HiGHS.Optimizer
intraday = 1
mr = ModelRun(params, setup, solver; scenarioname = "DA", resultdir = scen_dir, overwrite = true)

if intraday == 1
    @info "Starting full DA-ID chain run"

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
    print_report(report_intraday; show_notes = false, show_warnings = false)

    setup_intraday = ModelSetup(;
        TimeHorizon = TimeHorizon(stop = 4),
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

    POMATWO._run_intraday(mr, mr_intraday)
    @info "DA-ID chain run complete"
else
    POMATWO.run(mr)
end

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

using GLMakie, ColorSchemes, Tyler

plot_DA_w_Redisp_interactive(results)
plot_total_gen_interactive(results)

if results_intraday !== nothing
    plot_DA_w_Redisp_interactive(results_intraday)
    plot_total_gen_interactive(results_intraday)
end
