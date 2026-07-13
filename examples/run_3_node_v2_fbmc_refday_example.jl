# =============================================================================
# Reference-Day / Basecase methodology — worked example (companion to the docs)
#
# This script is the executable companion to the documentation page
# "Reference-Day Basecase" (docs/src/refday_methodology.md). It runs, on the small
# 3-node/2-zone `test_data_3_nodes_v2_fbmc` system, every sub-step the doc derives
# "on paper" and prints the model's own result next to it, so the two can be
# compared line by line.
#
# Run it top to bottom (needs POMATWO + a solver, here HiGHS) and follow along with
# the doc — no copy-pasting numbers required. Section headers below map 1:1 to the
# numbered sections of the doc page.
# =============================================================================
using POMATWO
using HiGHS
using Dates

# A few helpers used for the matching table are internal (not exported); we import
# them explicitly so the reference-day matching can be inspected step by step.
using POMATWO: dict_to_matrix, zone_to_zone_ptdf, define_cne!,
    add_planttype!, filter_powerplants!, add_nodecol!, add_time_cluster!,
    add_weekday!, match_by_cluster, match_by_scope, build_refday_basecase,
    calc_fbmc_params

pretty(x) = (show(stdout, "text/plain", x); println())

# -----------------------------------------------------------------------------
# 1. Load the v2 FBMC test system
# -----------------------------------------------------------------------------
datapath = joinpath("examples", "test_data_3_nodes_v2_fbmc")
data_files = Dict{Symbol,String}(
    :plants  => joinpath(datapath, "plants.csv"),
    :nodes   => joinpath(datapath, "nodes.csv"),
    :zones   => joinpath(datapath, "zones.csv"),
    :lines   => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand  => joinpath(datapath, "nodal_load.csv"),
    :types   => joinpath(datapath, "planttypes.csv"),
    :avail   => joinpath(datapath, "avail.csv"),
)
params, report = load_data_with_report(data_files)
print_report(report; show_notes = false)

println("\nnodes         = ", params.sets.N)
println("zones         = ", params.sets.Z)
println("lines         = ", params.sets.L)
println("dispatchable  = ", params.sets.DISP)   # p1 gas, p4 coal (wind/solar excluded)
println("slack         = ", params.slack)
println("nodes_in_zone = ", params.nodes_in_zone)

output_path = "results_v2_fbmc_refday"
solver = HiGHS.Optimizer

# -----------------------------------------------------------------------------
# 2. Nodal PTDF   (PTDFn = Bline * inv(Bbus_reduced))
# -----------------------------------------------------------------------------
PTDFn = dict_to_matrix(params.ptdf)
println("\n=== Nodal PTDF (l x n) ===")
pretty(PTDFn)

# -----------------------------------------------------------------------------
# 3. GSK & zonal PTDF — contrast: FlatGSK vs DispOnlyGSK
#    Zone Z2 = {n2 (wind), n3 (coal)}:
#      Flat     -> [0.5, 0.5]
#      DispOnly -> [0.0, 1.0]   (only dispatchable coal at n3 counts)
# -----------------------------------------------------------------------------
for strat in (FlatGSK(), DispOnlyGSK())
    println("\n=== GSK = ", strat, " ===")
    G = build_gsk(params, strat; normalize_empty = :flat)
    println("-- GSK (n x z) --");                  pretty(G)
    PTDFz = zonal_ptdf(PTDFn, G)
    println("-- zonal PTDF = PTDFn*GSK (l x z) --"); pretty(PTDFz)
    PTDFzz = zone_to_zone_ptdf(PTDFz; exclude_self = true)
    println("-- zone-to-zone PTDF (l x zonepairs) --"); pretty(PTDFzz)
end

# -----------------------------------------------------------------------------
# 4. Stage 1 — forecast run (optimization basecase; its 2DA tables are the
#    reference pool for the reference-day method)
# -----------------------------------------------------------------------------
setup_forecast = ModelSetup(;
    TimeHorizon     = TimeHorizon(stop = 4),
    MarketType      = ZonalMarket(FlowBased(DispOnlyGSK())),
    RedispatchSetup = DCLF(PhaseAngle),
)
mr_forecast = ModelRun(params, setup_forecast, solver;
    scenarioname = "forecast", resultdir = output_path, overwrite = true)
POMATWO.run(mr_forecast)

ref = DataFiles(joinpath(output_path, "forecast"); type = "2DA")
println("\n=== 2DA reference pool: nodal ACINJECTION ===");  pretty(ref.NETINPUT)

# -----------------------------------------------------------------------------
# 5. Reference-day matching (cluster_size = 2 -> 2 clusters over the 4-step horizon)
#    Renewable-only profile, weighted L1 distance, lookback = 1, per-zone scope.
# -----------------------------------------------------------------------------
cfg = MatchingConfig(cluster_size = 2, lookback = 1, exact_weekend = true,
                     scope = ZonalMatchScope())

gen_df = copy(ref.GEN)
add_planttype!(gen_df, ref.params)
filter_powerplants!(gen_df; type_in_planttype = cfg.res_tags)  # keep wind/solar
add_nodecol!(gen_df, ref.params)
add_time_cluster!(gen_df, cfg.cluster_size)
add_weekday!(gen_df, cfg.start_date)
println("\n=== renewable frame (the matching signal) ===")
pretty(gen_df[:, [:index, :plant_type, :node, :Time, :GEN, :Cluster]])

kw = (lookback = cfg.lookback, keycols = cfg.keycols, valuecols = [:GEN],
      value_methods = cfg.value_methods, weights = cfg.weights,
      exact_weekend = cfg.exact_weekend)
println("\n=== match_by_scope (per-zone reference days) ===")
pretty(match_by_scope(gen_df, cfg.scope, ref.params; kw...))
println("\n=== match_by_cluster (global fallback) ===")
pretty(match_by_cluster(gen_df; kw...))

# -----------------------------------------------------------------------------
# 6. Shift + basecase assembly — contrast: :zonal vs :nodal resolution
#    Both close the target zonal net position; :nodal reproduces the target nodal
#    injection exactly, :zonal keeps the reference-day texture reshaped to the NP.
# -----------------------------------------------------------------------------
shifts = Dict(
    :zonal => ShareShift(β_conv = 0.5, β_load = 0.5, β_RES = 0.0, β_NP = 0.0,
                         resolution = :zonal, res_prestep = true,
                         redist = GSKRedist(DispOnlyGSK())),
    :nodal => ShareShift(β_conv = 0.5, β_load = 0.5, β_RES = 0.0, β_NP = 0.0,
                         resolution = :nodal, res_prestep = true,
                         redist = GSKRedist(DispOnlyGSK())),
)
for res in (:zonal, :nodal)
    bc = ReferenceDayBasecase(source = joinpath(output_path, "forecast"),
        source_type = "2DA", matching = cfg, shift = shifts[res])
    base = build_refday_basecase(bc, params)
    println("\n=== BASECASE (", res, " shift) ===")
    println("-- :netinput_ac (n x t) --"); pretty(base[:netinput_ac])
    println("-- :lineflows  (l x t) --");  pretty(base[:lineflows])

    T = 1:size(base[:netinput_ac], 2)
    fp = calc_fbmc_params(DispOnlyGSK(), params, base, T; minRAM = 0.7, FRM = 0.1)
    println("-- CNE lines --");            println(params.cne)
    println("-- zonal PTDF on CNE --");    pretty(fp[:PTDFz])
    println("-- RAM (l x t x dir) --");    pretty(fp[:RAM])
end

# -----------------------------------------------------------------------------
# 7. Stage 2 — reference-day market clearing, for BOTH basecase resolutions.
#    The basecase design choice (zonal vs nodal) changes the RAM and therefore
#    the market dispatch at the congested hour.
# -----------------------------------------------------------------------------
for res in (:zonal, :nodal)
    setup = ModelSetup(;
        TimeHorizon     = TimeHorizon(stop = 4),
        MarketType      = ZonalMarket(FlowBased(
            GSKStrategy = DispOnlyGSK(),
            basecase    = ReferenceDayBasecase(
                source = joinpath(output_path, "forecast"), source_type = "2DA",
                matching = cfg, shift = shifts[res]),
        )),
        RedispatchSetup = DCLF(PhaseAngle),
    )
    mr = ModelRun(params, setup, solver;
        scenarioname = "refday_$(res)", resultdir = output_path, overwrite = true)
    POMATWO.run(mr)
    out = DataFiles(joinpath(output_path, "refday_$(res)"))
    println("\n=== refday market — ", res, " basecase: GEN ===");      pretty(out.GEN)
    println("=== refday market — ", res, " basecase: EXCHANGE ===");   pretty(out.EXCHANGE)
    println("state_sequence: ", state_sequence(setup))  # note: no TwoDayAhead
    check_infeasibility(out)

    # basecase traceability: which reference hour each group borrowed, and the
    # per-node shift deltas that turned it into the target hour
    println("\n=== trace: REFDAY_MATCH (group -> reference time) ===")
    pretty(out.REFDAY_MATCH)
    println("=== trace: per-node reference times (groups ⋈ match) ===")
    pretty(refday_reference_times(out))
    println("=== trace: REFDAY_SHIFT (nonzero injection deltas) ===")
    pretty(out.REFDAY_SHIFT)
end
