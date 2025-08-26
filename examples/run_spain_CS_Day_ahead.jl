using POMATWO
using HiGHS
datapath = joinpath("examples", "CS_15_01")

# define dictionary with all necessary data sets
dataCS = Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "plant_type.csv"),
    :avail => joinpath(datapath, "avail.csv"),
    :fixed_exchange => joinpath(datapath, "exchange.csv"),
    :inflow => joinpath(datapath, "inflow.csv"),
    :min_generation => joinpath(datapath, "min_generation.csv"),
    # :historical_generation => joinpath(datapath, "historical_values_pumped_only.csv")
)

# load input data
params = load_data(dataCS)



# set scenario name 
scen_name = "CS_spain_Intraday_15_01"

# define output path for data transfer
output_path = joinpath("..", "POMATWO", "results")

##############################################
##########     Day-Ahead        ##############
##############################################


setup = ModelSetup(;
    Scenario = "TestSetup",
    TimeHorizon = TimeHorizon(; offset = 0, split = 24, stop = 24),
    MarketType = ZonalMarket()
)

solver = HiGHS.Optimizer

mr = ModelRun(params, setup, solver; scenarioname = "$(scen_name)_DA", overwrite = true)

POMATWO.run(mr)

name = "$(scen_name)_DA"
results_path = joinpath("results", name)
results = DataFiles(results_path)
