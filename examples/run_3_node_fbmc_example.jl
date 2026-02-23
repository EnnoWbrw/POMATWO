# import Pkg
# Pkg.develop is not needed when running from within the POMATWO package directory
# Pkg.develop(path =".../POMATWO_merged_main__zonal_ptdf")
using POMATWO
using HiGHS

datapath = joinpath("examples", "test_data_3_nodes_fbmc")


# define dictionary with all necessary data sets
data_files= Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
    :avail => joinpath(datapath, "avail.csv"),
    #:avail_planttype_zonal => joinpath(datapath, "avail_planttype_zonal_PL.csv"),
    #:avail_planttype_zonal => joinpath(datapath, "avail_planttype_zonal_DE.csv"),
    #:ntc => joinpath(datapath, "ntc.csv")
)


params, report = load_data_with_report(data_files)

print_report(report; show_notes = false)



# set scenario name 
scen_name = "test_fbmc_example"

# define output path for data transfer
output_path = "results_fbmc_example"


setup = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(FlowBased(DispOnlyGSK())),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

solver = HiGHS.Optimizer

mr = ModelRun(params, setup, solver; scenarioname = scen_name, resultdir = output_path,  overwrite=true)

POMATWO.run(mr)

results = DataFiles(joinpath(output_path, scen_name))

using GLMakie, ColorSchemes, Tyler
### creating a graph to visualize day ahead generation levels over time
plot_DA_w_Redisp_interactive(results)

### create barplot to summarize generation by technology in the observed time horizon
plot_total_gen_interactive(results)
