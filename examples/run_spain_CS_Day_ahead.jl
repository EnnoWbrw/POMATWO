using PkgTemplates
using Revise
using POMATWO
using Gurobi
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


setup = ModelSetup(
    "TestSetup",
    TimeHorizon(; offset = 0, split = 24, stop = 24),
    ZonalMarket(target_zone = "ES"),
    NoProsumer(),
)

solver = optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => 0)

mr = ModelRun(params, setup, solver; scenarioname = "$(scen_name)_DA", overwrite = true)

POMATWO.run(mr)

name = "$(scen_name)_DA"
results_path = joinpath("results", name)
results = DataFiles(results_path)

scalefactor = 1 / 1e3  #### scales MW up to GW, as the default generation unit is MW and Plot Unit is GW
f = plot_DA_interactive(results, scalefactor, 1:24)

f2 = plot_total_gen(results, :DA)


# ##############################################
# ##########     Intraday         ##############
# ##############################################

# run_intraday(datapath, 26, params, scen_name) ###  run_intraday(datapath, NumberOfGates::Int, params, scen_name)


# name = "$(scen_name)_ID_1"
# results_path = joinpath("results", name)
# results = DataFiles(results_path)
# scalefactor = 1 / 1e3  #### scales MW up to GW, as the default generation unit is MW and Plot Unit is GW

# f_id = plot_DA_interactive(results, scalefactor, 1:24)
# save(joinpath("results", date, "intraday", "$(name).png"), f_id)

# results_gen_id = select(results.GEN, [:index, :Time, :GEN, :CU])
# results_charge_id = select(results.CHARGE, Not(:gmax))

# # save results
# CSV.write(
#     joinpath("results", date, "intraday", "pomatwo_ID_results_GEN.csv"),
#     results_gen_id,
# )
# CSV.write(
#     joinpath("results", date, "intraday", "pomatwo_ID_results_CHARGE.csv"),
#     results_charge_id,
# )

# # transfer results to plan4res
# if trans_results == 1
#     CSV.write(
#         joinpath(output_path, "intraday", "pomatwo_ID_results_GEN.csv"),
#         results_gen_id,
#     )
#     CSV.write(
#         joinpath(output_path, "intraday", "pomatwo_ID_results_CHARGE.csv"),
#         results_charge_id,
#     )
# end
