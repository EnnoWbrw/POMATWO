using POMATWO
using HiGHS
datapath = joinpath("examples", "test_data_3_nodes")

# define dictionary with all necessary data sets
data_files= Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)

# to get an idea of network topology we can plot the grid layout.
#plot_network(dataCS)

# load input data
params, report = load_data_with_report(data_files)

print_report(report)

# set scenario name 
scen_name = "3_nodes"

# define output path for data transfer
output_path = "results_example"

### Defining a test setup for a model run that stops after 4 timesteps
setup = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

solver = HiGHS.Optimizer

mr = ModelRun(params, setup, solver; scenarioname = scen_name, resultdir = output_path)

POMATWO.run(mr)


results_path = joinpath(output_path, scen_name)

### reading in the result files
results = DataFiles(results_path) 

### Looking at specific results
results.GEN
results.REDISP
results.LINEFLOW

using GLMakie, ColorSchemes, Tyler
### creating a graph to visualize day ahead generation levels over time
plot_DA_w_Redisp_interactive(results)

### create barplot to summarize generation by technology in the observed time horizon
plot_total_gen_interactive(results)

