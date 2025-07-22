using POMATWO
using HiGHS
datapath = joinpath("examples", "test_data_3_nodes_prosumer")

# define dictionary with all necessary data sets
data_files= Dict{Symbol, Union{String,Vector{String}}}(
    :plants => [joinpath(datapath, "plants.csv"),
                joinpath(datapath, "prosumer_plants.csv")],
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
    :prs_demand => joinpath(datapath, "prosumer_demand.csv"),
    :avail => joinpath(datapath, "availability.csv"),
)

# to get an idea of network topology we can plot the grid layout.
#plot_network(dataCS)

# load input data
params = load_data(data_files)

# set scenario name 
scen_name = "3_nodes_prosumer"

# define output path for data transfer
output_path = "results/"

### Defining a test setup for a model run that stops after 4 timesteps
setup = ModelSetup(
    "TestSetup",
    TimeHorizon(stop = 4),
    ZonalMarketWithRedispatch(),
    ProsumerOptimization(sell_price=0.12, buy_price=0.22)
)

solver = HiGHS.Optimizer

mr = ModelRun(params, setup, solver; scenarioname = scen_name,overwrite=true )

POMATWO.run(mr)


results_path = joinpath(output_path, scen_name)

### reading in the result files
results = DataFiles(results_path) 

### Looking at specific results
@show results.GEN
@show results.REDISP
results.LINEFLOW
results.PRS

using GLMakie, ColorSchemes, Tyler

### creating a graph to visualize day ahead generation levels over time
plot_DA_w_Redisp_interactive(results)

### create barplot to summarize generation by technology in the observed time horizon
plot_total_gen_interactive(results)
