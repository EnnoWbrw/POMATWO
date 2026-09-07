# =============================================================================
# Benchmark / smoke harness for the Plotting extension.
#
# Not a test and never run by CI — GLMakie is a weakdep and is not in the
# package's test target. It exists so that changes to ext/plots/* have a
# before/after number instead of an opinion.
#
# It does two things:
#   1. renders every public entry point once against a result directory and
#      saves a PNG, so a visual diff of two revisions is possible, and
#   2. times each data-preparation step and one full interactive `redraw!`,
#      reporting time AND allocations (most of the wins are allocation wins).
#
# Run it in an environment that has POMATWO + GLMakie + Tyler + ColorSchemes +
# Colors. `examples/Project.toml` does NOT carry them by default:
#
#   julia --project=examples -e 'using Pkg; Pkg.add(["GLMakie","Tyler","ColorSchemes","Colors","BenchmarkTools"])'
#   julia --project=examples examples/bench_plotting.jl [results_dir] [out_dir]
#
# `background_map = false` everywhere: the Tyler tile fetch is network-bound and
# would dominate every measurement.
# =============================================================================

using POMATWO
# All four weakdeps must be loaded for the `Plotting` extension to trigger.
using GLMakie, Tyler, ColorSchemes, Colors
using DataFrames

const RESULTS_DIR = length(ARGS) >= 1 ? ARGS[1] :
    joinpath("C:\\Users\\ewi\\Documents\\Master_Arbeit\\Model_Run_claude\\results_test\\refday_gsk_redist_lb6")
const OUT_DIR = length(ARGS) >= 2 ? ARGS[2] : joinpath(@__DIR__, "..", "bench_out")

const PLOTTING = Base.get_extension(POMATWO, :Plotting)
PLOTTING === nothing && error("Plotting extension not loaded — is GLMakie in this project?")

GLMakie.activate!(inline = false)
isdir(OUT_DIR) || mkpath(OUT_DIR)

# -----------------------------------------------------------------------------
# reporting
# -----------------------------------------------------------------------------
const ROWS = NamedTuple{(:what, :ms, :alloc_mb, :allocs),
                        Tuple{String,Float64,Float64,Int}}[]

"""
Time `f()` after one warm-up call, recording ms / MiB / allocation count.

Tolerant of a missing helper so the same script can be run on an older revision to get a
before/after comparison — internal names differ across the refactor.
"""
function measure(what, f)
    try
        f()                               # warm up (compilation excluded)
        n = @allocations f()
        stats = @timed f()
        push!(ROWS, (what = what,
                     ms = stats.time * 1e3,
                     alloc_mb = stats.bytes / 2^20,
                     allocs = n))
    catch err
        println("  skip measure $what  ($(first(split(sprint(showerror, err), '\n'))))")
    end
    return nothing
end

function report()
    println("\n", "="^78)
    println(rpad("step", 44), lpad("ms", 10), lpad("MiB", 10), lpad("allocs", 12))
    println("-"^78)
    for r in ROWS
        println(rpad(r.what, 44),
                lpad(round(r.ms; digits = 2), 10),
                lpad(round(r.alloc_mb; digits = 2), 10),
                lpad(r.allocs, 12))
    end
    println("="^78)
end

"Render `f()` to `OUT_DIR/name.png`; report and continue if the input does not support it."
function render(name, f)
    try
        fig = f()
        save(joinpath(OUT_DIR, "$(name).png"), fig)
        println("  ok   $name")
    catch err
        println("  SKIP $name  ($(sprint(showerror, err) |> x -> first(split(x, '\n'))))")
    end
    return nothing
end

# -----------------------------------------------------------------------------
# load
# -----------------------------------------------------------------------------
println("results: ", abspath(RESULTS_DIR))
results = DataFiles(RESULTS_DIR)
horizon = 1:maximum(results.GEN.Time)
println("zones=$(length(results.params.sets.Z)) nodes=$(length(results.params.sets.N)) ",
        "lines=$(length(results.params.sets.L)) hours=$(length(horizon))")

# -----------------------------------------------------------------------------
# 1. data preparation
# -----------------------------------------------------------------------------
measure("prepare_disp_plot_data", () -> PLOTTING.prepare_disp_plot_data(results, 1/1000, horizon))
measure("prepare_redisp_plot_data", () -> PLOTTING.prepare_redisp_plot_data(results, 1/1000, horizon))
measure("_plot_colors", () -> PLOTTING._plot_colors(results))
measure("_zone_load_series", () -> PLOTTING._zone_load_series(results.params, collect(horizon)))
measure("_load_by_zone", () -> PLOTTING._load_by_zone(results, collect(horizon)))
measure("_line_util_matrix", () -> PLOTTING._line_util_matrix(results, false))
measure("_line_utilization_table", () -> PLOTTING._line_utilization_table(results, false, 0.95))
let nodes = sort(unique(String.(results.NETINPUT.index))),
    times = sort(unique(Int.(results.NETINPUT.Time)))
    measure("_net_injection_matrix",
            () -> PLOTTING._net_injection_matrix(results, nodes, times))
end

# -----------------------------------------------------------------------------
# 2. figures (also the visual-diff artefacts)
# -----------------------------------------------------------------------------
println("\nrendering to ", abspath(OUT_DIR))
render("market_DA", () -> plot_market_interactive(results; time_horizon = horizon))
render("market_REDISP", () -> plot_market_interactive(results; time_horizon = horizon, kind = :REDISP))
render("da_w_redisp", () -> plot_DA_w_Redisp_interactive(results; time_horizon = horizon))
render("total_gen", () -> plot_total_gen_interactive(results))
render("market_stats", () -> plot_market_statistics(results, first(results.params.sets.Z)))
render("lineplot_max", () -> PLOTTING.create_lineplot(RESULTS_DIR, "max", false, 0.95;
                                                     background_map = false))
render("lineplot_avg", () -> PLOTTING.create_lineplot(RESULTS_DIR, "avg", false, 0.95;
                                                     background_map = false))
render("line_utils", () -> plot_line_utils_interactive(RESULTS_DIR; background_map = false))

# `plot_capacity_network` is the one entry point that reads no results at all, so it needs
# an input data directory rather than `RESULTS_DIR`.
const DATA_DIR = length(ARGS) >= 3 ? ARGS[3] :
    get(ENV, "POMATWO_DATA_DIR", joinpath(@__DIR__, "test_data_3_nodes_v2"))
if isdir(DATA_DIR)
    println("input data: ", abspath(DATA_DIR))
    inputs = Dict{Symbol,String}(
        :nodes => joinpath(DATA_DIR, "nodes.csv"),
        :lines => joinpath(DATA_DIR, "lines.csv"),
        :dclines => joinpath(DATA_DIR, "dclines.csv"),
        :plants => joinpath(DATA_DIR, "plants.csv"),
        :types => joinpath(DATA_DIR, "planttypes.csv"),
    )
    measure("_node_positions_from_csv", () -> PLOTTING._node_positions_from_csv(inputs[:nodes]))
    render("capacity_network",
           () -> plot_capacity_network(inputs; background_map = false))
end

# -----------------------------------------------------------------------------
# 3. reference-day plots — only a ReferenceDayBasecase run carries the traces
# -----------------------------------------------------------------------------
const REFDAY_DIR = get(ENV, "POMATWO_REFDAY_DIR",
    joinpath(@__DIR__, "..", "results", "8node_shareshift", "refday_GSK_nodal"))
if isdir(REFDAY_DIR)
    println("refday: ", abspath(REFDAY_DIR))
    variant = DataFiles(REFDAY_DIR)
    measure("_shift_arrays", () -> PLOTTING._shift_arrays(variant))
    render("shift_map", () -> plot_shift_map_interactive(variant; background_map = false))
    render("shift_map_util", () -> plot_shift_map_interactive(
        variant; background_map = false, line_value = :utilization))
    render("shift_map_f0", () -> plot_shift_map_interactive(
        variant; background_map = false, line_value = :f0_utilization))
    render("refday_dispatch", () -> plot_refday_dispatch_interactive(variant, results))
end

report()
println("\nPNGs in $(abspath(OUT_DIR)) — diff them against the pre-change revision.")
