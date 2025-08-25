# POMATWO.jl
POMATWO is an electricity market model designed to determine the cost-optimal electricity supply on an hourly basis. It incorporates market clearing conditions, grid topology, and network constraints. It supports solving predefined market stages such as the day-ahead market and redispatch.

### Inputs
To run POMATWO, the following input data is required:

- Definition of market zones, time steps, nodes, generation technologies (including solar and wind), storages, and transmission lines
- Power plant characteristics (availability, capacity, marginal production cost etc.)
- Grid configuration (topology and line capacities)
- Storage data (inflows, capacities, efficiencies)
- Marginal costs of generation technologies
- Electricity load data

### Outputs

POMATWO calculates the cost-optimal dispatch. Main outputs include:

- Generation per power plant and time step (MWh)
- Redispatch decisions (MWh)
- Node-level injections (MWh)
- Electricity Prices

These results are available per market stage (e.g., day-ahead, intraday gates).
## Installation
To install the package simply run the following lines of code in a .jl file.
```julia
import Pkg
Pkg.add(url="https://github.com/EnnoWbrw/POMATWO")
```
## Getting Started
Here's a minimal working example:
```julia
using POMATWO
using HiGHS
datapath = joinpath("examples", "test_data_3_nodes")

# define dictionary with all necessary data sets
dataCS = Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)

# load input data
params = load_data(dataCS)



# set scenario name 
scen_name = "3_nodes"

# define output path for data transfer
output_path = "results/"

### Defining a test setup for a model run that stops after 4 timesteps
setup = ModelSetup(;
    Scenario = "TestSetup",
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarketWithRedispatch(target_zone = "DE"),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = NoRedispatch()
)

solver = HiGHS.Optimizer

mr = ModelRun(params, setup, solver; scenarioname = scen_name, overwrite = true)

POMATWO.run(mr)

results_path = joinpath(output_path, scen_name)

### reading in the result files
results = DataFiles(results_path)

### Looking at specific results
results.GEN
results.LINEFLOW

### creating a graph to visualize day ahead generation levels over time
plot_DA_w_Redisp_interactive(results)

### create barplot to summarize generation by technology in the observed time horizon
plot_total_gen(results, :DA)
```