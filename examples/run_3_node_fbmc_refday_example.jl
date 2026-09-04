# Flow-based market run with a reference-day (D2CF-style) basecase.
#
# Two stages:
#   1. "Forecast" run: a regular flow-based run whose DayAhead basecase
#      results serve as the reference pool + target forecast.
#   2. Reference-day run: same setup, but the FBMC basecase is built by
#      matching + shifting reference days from stage 1 instead of solving
#      the TwoDayAhead optimization (state_sequence drops TwoDayAhead).
using POMATWO
using HiGHS
using Dates

Pkgdir = pkgdir(POMATWO)
datapath = joinpath(Pkgdir, "examples", "test_data_3_nodes_fbmc")

data_files = Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
    :avail => joinpath(datapath, "avail.csv"),
)

params, report = load_data_with_report(data_files)
print_report(report; show_notes = false)

output_path = "results_fbmc_refday_example"
solver = HiGHS.Optimizer

# ---- Stage 1: forecast run (default optimization basecase) ----
setup_forecast = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(FlowBased(DispOnlyGSK())),
    RedispatchSetup = DCLF(PhaseAngle),
)
mr_forecast = ModelRun(params, setup_forecast, solver;
                       scenarioname = "forecast", resultdir = output_path, overwrite = true)
POMATWO.run(mr_forecast)

# ---- Stage 2: reference-day basecase sourced from the forecast run ----
setup_refday = ModelSetup(;
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(FlowBased(
        GSKStrategy = DispOnlyGSK(),
        basecase = ReferenceDayBasecase(
            source = joinpath(output_path, "forecast"),   # forecast run results
            source_type = "DA",                          # its DayAhead tables
            matching = MatchingConfig(
                cluster_size = 2,          # 2-step "days" so the 4-step horizon has 2 clusters
                lookback = 1,
                exact_weekend = true,      # auto-relaxes when no same-type candidate exists
                scope = ZonalMatchScope(), # per-TSO matching: each zone borrows its own reference day
            ),
            shift = ShareShift(
                β_conv = 0.5, β_load = 0.5, β_RES = 0.0,
                resolution = :zonal,
                prestep = [:res, :load],   # hard-align RES and load to the target first
                redist = GSKRedist(DispOnlyGSK()),
            ),
        ),
    )),
    RedispatchSetup = DCLF(PhaseAngle),
)
mr_refday = ModelRun(params, setup_refday, solver;
                     scenarioname = "DoD", resultdir = output_path, overwrite = true)
POMATWO.run(mr_refday)   # note: no TwoDayAhead solve — basecase comes from the reference days

# ---- Compare ----
results_forecast = DataFiles(joinpath(output_path, "forecast"))
results_Day_of_Delivery  = DataFiles(joinpath(output_path, "DoD"))
