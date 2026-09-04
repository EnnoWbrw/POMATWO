#!/usr/bin/env julia
#
# Old-vs-new equivalence oracle for the DATA LAYER of the Plotting extension.
#
# OPT-IN. Never run by CI and deliberately not wired into runtests.jl: the extension is
# gated on `[extensions] Plotting = ["Tyler", "GLMakie", "ColorSchemes", "Colors"]`, and
# GLMakie needs an OpenGL context that GitHub runners do not provide without an xvfb
# workaround. Run it by hand after touching the data layer:
#
#   julia test/verify_plotting_equivalence.jl [refday_results_dir]
#
# HiGHS and the four weakdeps live outside [deps], so this bootstraps a temporary
# environment when they are not already loadable (see CLAUDE.md). First run costs a
# minute or two.
#
# ---------------------------------------------------------------------------------------
# WHY THIS EXISTS
#
# The extension has no automated coverage at all. Its stacked-dispatch pipeline was
# rewritten from a `groupby`/`vcat` DataFrame pipeline into direct accumulation into
# `time x series` matrices, and two of the bugs that introduced were invisible in a
# rendered figure — the plot looked entirely plausible, the numbers were wrong:
#
#   * Routing each ROW by its sign breaks `Net injection`, whose importing and exporting
#     nodes must cancel into one bar instead of growing both halves of the stack.
#   * Summing ACROSS contributions before routing breaks `GEN` vs `CU`, which share a
#     plant type and must land on opposite sides.
#
# The correct rule — aggregate per contribution, then route that contribution's total by
# sign — is what the section below pins, by re-implementing the pre-refactor algorithms
# verbatim and asserting the current helpers still produce identical numbers.
#
# ---------------------------------------------------------------------------------------
# WHEN A CHANGE IS DELIBERATE
#
# The "old" side is a FROZEN copy of the pre-refactor code. It encodes behaviour as of the
# refactor, not current intent. When behaviour is changed on purpose, edit the old side to
# match and mark it `# deliberate change: ...` — see the two existing markers. That keeps
# the file a pin against accidental drift rather than a museum piece; a bare failure here
# always means "something moved that nobody decided to move".
#
# What it does NOT check: anything about rendering. No Figure, no Screen, no colours, no
# layout. Those are covered manually by examples/bench_plotting.jl.

_norm(p) = rstrip(normpath(p), ('/', '\\'))
const REPO = _norm(joinpath(@__DIR__, ".."))

# The active environment is only usable if it resolves POMATWO to THIS repository;
# comparing another checkout's code against this one's oracle is meaningless.
function _resolves_to_repo()
    id = Base.identify_package("POMATWO")
    id === nothing && return false
    src = Base.locate_package(id)
    src === nothing && return false
    found = _norm(dirname(dirname(src)))
    found == REPO && return true
    @warn "the active environment resolves POMATWO elsewhere — bootstrapping instead" found REPO
    return false
end

# Kept deliberately minimal. Every name here that the active environment does not export
# forces the bootstrap below, and bootstrapping means resolving and precompiling the whole
# Makie stack in a fresh environment — many minutes even with a warm depot. JuMP in
# particular is NOT needed (neither this file nor test_expected_results.jl calls it), and
# requiring it was enough to push a perfectly good environment onto the slow path.
const _DEPS = ["HiGHS", "DataFrames", "DataFramesMeta", "CSV",
               "GLMakie", "Tyler", "ColorSchemes", "Colors"]

function _load_deps()
    _resolves_to_repo() || return false
    try
        @eval using POMATWO, HiGHS, DataFrames, DataFramesMeta, CSV, Statistics,
                    Logging, LinearAlgebra, Test, GLMakie, Tyler, ColorSchemes, Colors
    catch
        return false
    end
    return true
end

if !_load_deps()
    @warn """
    Bootstrapping a temporary environment — this resolves and precompiles GLMakie and can
    take many minutes. Much faster: run this from an environment that already has the
    plotting weakdeps, e.g.

        julia --project=examples test/verify_plotting_equivalence.jl

    after one-off `Pkg.add(["GLMakie","Tyler","ColorSchemes","Colors","HiGHS","DataFramesMeta","CSV"])`.
    """
    using Pkg
    Pkg.activate(mktempdir())
    Pkg.develop(path = REPO)
    Pkg.add(_DEPS)
    @eval using POMATWO, HiGHS, DataFrames, DataFramesMeta, CSV, Statistics,
                Logging, LinearAlgebra, Test, GLMakie, Tyler, ColorSchemes, Colors
    _norm(@eval pkgdir(POMATWO)) == REPO ||
        error("POMATWO still resolves to $(@eval pkgdir(POMATWO)) instead of $REPO")
end

# All four weakdeps are loaded above, so the extension is live.
const P = Base.get_extension(POMATWO, :Plotting)
P === nothing && error("Plotting extension did not load — are GLMakie/Tyler/ColorSchemes/Colors present?")

include(joinpath(@__DIR__, "test_cases", "test_expected_results.jl"))

# ---------------------------------------------------------------------------------------
# result harness
# ---------------------------------------------------------------------------------------
const FAILS = String[]
function check(name, cond)
    cond ? println("    PASS  $name") : (push!(FAILS, name); println("    FAIL  $name"))
    return cond
end

"""
Solve a handful of `golden_grid()` scenarios into `tmpdir`.

A subset, not the whole grid: these four cover every branch the dispatch pipeline has —
zonal NTC (an `EXCHANGE` column), flow-based, nodal (no `EXCHANGE`/`ZonalMarketBalance`,
so the empty-table paths are exercised), and one with a prosumer. All are 3-node / 4-hour,
so the whole thing solves in seconds.
"""
function solve_subset(tmpdir; solver = HiGHS.Optimizer)
    grid = golden_grid()
    picked = [sc for sc in grid if occursin("ZonalNTC_DCLF_th4", sc.name) ||
                                   occursin("ZonalFB_DCLF_th4", sc.name) ||
                                   occursin("Nodal_DCLF_th4", sc.name) ||
                                   (startswith(sc.name, "prosumer_") &&
                                    occursin("Zonal_DCLF_th4", sc.name))]
    isempty(picked) && error("no scenarios matched — has golden_grid() been renamed?")

    params = Dict(ds => with_logger(NullLogger()) do
                      load_data(golden_input_files(ds))
                  end for ds in unique(sc.dataset for sc in picked))
    out = Pair{String,Any}[]
    for sc in picked
        with_logger(NullLogger()) do
            mr = ModelRun(params[sc.dataset], sc.setup, solver;
                          resultdir = tmpdir, scenarioname = sc.name, overwrite = true)
            POMATWO.run(mr)
        end
        push!(out, sc.name => DataFiles(joinpath(tmpdir, sc.name)))
    end
    return out
end

# =======================================================================================
# FROZEN pre-refactor implementations — do not "clean up".
# Their only job is to be the algorithm as it was, so a difference is a real difference.
# =======================================================================================
old_value_at(profile, t) = try
    v = profile[t]
    ismissing(v) ? 0.0 : Float64(v)
catch
    0.0
end

function old_load_at(params, zone, t)
    nodes = get(params.nodes_in_zone, zone, String[])
    isempty(nodes) && return 0.0
    sum(old_value_at(params.nodal_load[n], t) / 1e3
        for n in nodes if haskey(params.nodal_load, n); init = 0.0)
end

old_load_by_zone(results, tv) = Dict(
    z => DataFrame(Time = tv, orig_load = [old_load_at(results.params, z, t) for t in tv])
    for z in results.params.sets.Z)

"""
Pre-refactor `_price_by_zone`, with one guard added.

A nodal market writes no `ZonalMarketBalance`, and `DataFiles` returns a 0-column empty
frame for it. The original chain then failed inside `@rsubset` because `:Time` does not
exist — i.e. `plot_market_interactive` raised on any nodal run. The rewrite handles it
(`_price_points_by_zone` returns an empty `Point2f` vector per zone), so the guard here is
not papering over a difference: it is what lets the two be compared at all on the nodal
scenarios. Marked as a fix rather than a deliberate behavioural change.
"""
function old_price_by_zone(results, time_set)
    df = results.ZonalMarketBalance
    if !(df isa DataFrame) || isempty(df) || !hasproperty(df, :MarketBalance)
        return Dict(z => DataFrame(Time = Int[], MarketBalance = Float64[])
                    for z in results.params.sets.Z)
    end
    return Dict(
        z => @chain df begin
            @rsubset :Time in time_set
            @rsubset :Zone == z
            @orderby :Time
        end for z in results.params.sets.Z)
end

function old_matrix_for_types(df, tv, types)
    mat = zeros(Float64, length(tv), length(types))
    tp = Dict(t => i for (i, t) in enumerate(types))
    timep = Dict(t => i for (i, t) in enumerate(tv))
    for row in eachrow(df)
        ti = get(timep, row.Time, nothing)
        ci = get(tp, row.plant_type, nothing)
        ti !== nothing && ci !== nothing && (mat[ti, ci] += row.value)
    end
    return mat
end

function old_dispatch_cache(df, tv)
    isempty(df) && return (time = tv, pos_types = String[],
        pos_mat = zeros(Float64, length(tv), 0), neg_types = String[],
        neg_mat = zeros(Float64, length(tv), 0))
    pos_df = filter(:value => >=(0), df)
    neg_df = filter(:value => <(0), df)
    # deliberate change: _TOP_SERIES ("CU") is pinned to the end of the stack, so that a
    # curtailment cap cannot sit mid-stack and make every band edge above it meaningless.
    ord(x) = (x in ("CU",) ? 1 : 0, x)
    pt = sort(unique(String.(pos_df.plant_type)); by = ord)
    nt = sort(unique(String.(neg_df.plant_type)); by = ord)
    return (time = tv, pos_types = pt, neg_types = nt,
            pos_mat = cumsum(old_matrix_for_types(pos_df, tv, pt), dims = 2),
            neg_mat = cumsum(old_matrix_for_types(neg_df, tv, nt), dims = 2))
end

function old_with_plant_metadata(df, params, time_set)
    isempty(df) && return DataFrame()
    f = filter(:Time => t -> t in time_set, df)
    isempty(f) && return DataFrame()
    e = transform(f, :index => ByRow(i -> get(params.plant2zone, i, missing)) => :zone,
                     :index => ByRow(i -> get(params.plant_type, i, "unknown")) => :plant_type)
    dropmissing!(e, :zone)
    return e
end

_empty_agg() = DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])

function old_agg_zone_type(df, col, sf; sign = 1.0, label = nothing)
    isempty(df) && return _empty_agg()
    d = df
    # deliberate change: curtailment is its own "CU" series instead of a downward bar
    # wearing the plant type's name and colour, which read as negative generation.
    if label !== nothing
        d = copy(df)
        d.plant_type .= label
    end
    combine(groupby(d, [:zone, :Time, :plant_type]), col => (x -> sign * sf * sum(x)) => :value)
end

function old_agg_exchange(results, sf, ts)
    isempty(results.EXCHANGE) && return _empty_agg()
    df = filter(:Time => t -> t in ts, results.EXCHANGE)
    isempty(df) && return _empty_agg()
    transform!(df, :index => :zone)
    df.plant_type .= "exchange"
    combine(groupby(df, [:zone, :Time, :plant_type]), :EXCHANGE => (x -> sf * sum(x)) => :value)
end

function old_agg_zonal_balance(results, sf, ts, col, pt; sign = 1.0)
    isempty(results.ZonalMarketBalance) && return _empty_agg()
    df = filter(:Time => t -> t in ts, results.ZonalMarketBalance)
    isempty(df) && return _empty_agg()
    transform!(df, :Zone => :zone)
    df.plant_type .= pt
    combine(groupby(df, [:zone, :Time, :plant_type]), col => (x -> sign * sf * sum(x)) => :value)
end

function old_agg_node_table(df, params, ts, icol, vcol, pt, sf; sign = 1.0)
    isempty(df) && return _empty_agg()
    f = filter(:Time => t -> t in ts, df)
    isempty(f) && return _empty_agg()
    e = transform(f, icol => ByRow(n -> get(params.node2zone, n, missing)) => :zone)
    dropmissing!(e, :zone)
    isempty(e) && return _empty_agg()
    e.plant_type .= pt
    combine(groupby(e, [:zone, :Time, :plant_type]), vcol => (x -> sign * sf * sum(x)) => :value)
end

function old_dispatch_by_zone(results, merged, tv)
    out = Dict{String,NamedTuple}()
    g = isempty(merged) ? nothing : groupby(merged, :zone)
    for z in results.params.sets.Z
        zdf = (g === nothing || !haskey(g, (z,))) ? DataFrame() : g[(z,)]
        out[z] = old_dispatch_cache(zdf, tv)
    end
    return out
end

function old_prepare_disp(results, sf, th)
    tv = collect(th); ts = Set(tv)
    gen = old_with_plant_metadata(results.GEN, results.params, ts)
    chg = old_with_plant_metadata(results.CHARGE, results.params, ts)
    merged = reduce(vcat, [
        old_agg_zone_type(gen, :GEN, sf),
        old_agg_zone_type(chg, :CHARGE, sf; sign = -1.0),
        old_agg_zonal_balance(results, sf, ts, :LL, "LL"),
        # deliberate change: CU stacks upward as a pale cap, see `_TOP_SERIES`
        old_agg_zone_type(gen, :CU, sf; sign = 1.0, label = "CU"),
        old_agg_exchange(results, sf, ts)], cols = :union)
    return old_price_by_zone(results, ts), old_load_by_zone(results, tv),
           old_dispatch_by_zone(results, merged, tv)
end

function old_prepare_redisp(results, sf, th)
    tv = collect(th); ts = Set(tv)
    rd = old_with_plant_metadata(results.REDISP, results.params, ts)
    merged = reduce(vcat, [
        old_agg_zone_type(rd, :GEN_REDISP, sf),
        old_agg_zone_type(rd, :CHARGE_REDISP, sf; sign = -1.0),
        old_agg_node_table(results.NETINPUT, results.params, ts, :index, :NETINPUT, "Net injection", sf),
        old_agg_node_table(results.NodalMarketRedispBalance, results.params, ts, :Node, :LL, "LL", sf),
        # deliberate change: see above
        old_agg_zone_type(rd, :CU_REDISP, sf; sign = 1.0, label = "CU")], cols = :union)
    return old_price_by_zone(results, ts), old_load_by_zone(results, tv),
           old_dispatch_by_zone(results, merged, tv)
end

# deliberate change: ShareShift gained a :load pre-step, whose trace component
# "load_prestep" is a real nodal delta and stacks alongside "RES_prestep".
const _SC = ["RES_prestep", "load_prestep", "RES", "conv", "load", "sto", "balance"]

function old_shift_arrays(results)
    df = results.REFDAY_SHIFT
    is_un = String.(df.component) .== "np_relax"
    unab = DataFrame(Time = Int.(df.Time[is_un]), zone = String.(df.node[is_un]),
                     delta = Float64.(df.delta[is_un]))
    core = df[.!is_un, :]
    params = results.params
    times = sort(unique(Int.(core.Time)))
    nodes = [n for n in params.sets.N if P._has_coords(params.node_coords, n)]
    tpos = Dict(t => i for (i, t) in enumerate(times))
    npos = Dict(n => i for (i, n) in enumerate(nodes))
    comps = [c for c in _SC if c in unique(String.(core.component))]
    cm = Dict(c => zeros(length(nodes), length(times)) for c in comps)
    for row in eachrow(core)
        ni = get(npos, row.node, nothing)
        ti = get(tpos, Int(row.Time), nothing)
        (ni === nothing || ti === nothing) && continue
        haskey(cm, String(row.component)) || continue   # old code raised a KeyError here
        cm[String(row.component)][ni, ti] += Float64(row.delta)
    end
    total = zeros(length(nodes), length(times))
    for m in values(cm)
        total .+= m
    end
    return (; times, nodes, comp_mats = cm, total, unabsorbed = unab)
end

function old_shift_by_zone(variant)
    params = variant.params
    out = Dict{String,Dict{Int,Dict{String,Float64}}}()
    for row in eachrow(variant.REFDAY_SHIFT)
        comp = String(row.component)
        z = comp == "np_relax" ? String(row.node) : get(params.node2zone, row.node, missing)
        ismissing(z) && continue
        d = get!(get!(out, String(z), Dict{Int,Dict{String,Float64}}()),
                 Int(row.Time), Dict{String,Float64}())
        d[comp] = get(d, comp, 0.0) + Float64(row.delta)
    end
    return out
end

function old_gen_by_zone_type(res, time_set)
    df = old_with_plant_metadata(res.GEN, res.params, time_set)
    out = Dict{String,Dict{Int,Dict{String,Float64}}}()
    isempty(df) && return out
    agg = combine(groupby(df, [:zone, :Time, :plant_type]),
                  :GEN => (x -> sum(skipmissing(Float64.(x)))) => :GEN)
    for row in eachrow(agg)
        d = get!(get!(out, String(row.zone), Dict{Int,Dict{String,Float64}}()),
                 Int(row.Time), Dict{String,Float64}())
        d[String(row.plant_type)] = get(d, String(row.plant_type), 0.0) + Float64(row.GEN)
    end
    return out
end

function old_charge_by_zone(res, time_set)
    out = Dict{String,Dict{Int,Float64}}()
    hasproperty(res, :CHARGE) || return out
    df = res.CHARGE
    (df isa DataFrame && !isempty(df)) || return out
    p2z = res.params.plant2zone
    for row in eachrow(df)
        t = Int(row.Time)
        t in time_set || continue
        z = get(p2z, String(row.index), missing)
        ismissing(z) && continue
        d = get!(out, String(z), Dict{Int,Float64}())
        d[t] = get(d, t, 0.0) + Float64(coalesce(row.CHARGE, 0.0))
    end
    return out
end

function old_refday_zone_load(params, zone, t)
    nodes = get(params.nodes_in_zone, zone, String[])
    isempty(nodes) && return 0.0
    sum(old_value_at(params.nodal_load[n], t)
        for n in nodes if haskey(params.nodal_load, n); init = 0.0)
end

function old_slack(results)
    df = results.NodalMarketRedispBalance
    (df isa DataFrame && !isempty(df)) || return 0.0
    total = 0.0
    for c in (:CU, :LL)
        hasproperty(df, c) || continue
        total += sum(abs, Float64.(coalesce.(df[!, c], 0.0)); init = 0.0)
    end
    return total
end

# =======================================================================================
# comparisons
# =======================================================================================

"De-cumulate a stacked matrix so per-(time, series) values can be matched by name."
_decum(m) = size(m, 2) == 0 ? m :
    hcat([j == 1 ? m[:, 1] : m[:, j] - m[:, j-1] for j = 1:size(m, 2)]...)

# Values are in GW after the 1/1000 scale factor, so this is 1 W — far below anything the
# plot could render, and far above the floating-point noise discussed below.
const _ZERO_TOL = 1e-9
_significant(col) = any(x -> abs(x) > _ZERO_TOL, col)

"""
Series names that carry a visible contribution on one side of the stack.

Which side a series lands on is decided by the SIGN of its aggregate, and an aggregate that
is mathematically exactly zero has a floating-point residual whose sign depends on
summation order. A nodal market is the case in point: a zone's `NETINPUT` sums to zero by
construction (the closed nodal balance), leaving ~1e-19, and DataFrames' `groupby`/`sum`
and a plain accumulation loop do not agree on its sign. Comparing raw side-membership
therefore reports a difference where none exists, so negligible series are dropped from
both sides before the sets are compared.
"""
_signif_names(types, mat) =
    [ty for (k, ty) in enumerate(types) if _significant(view(mat, :, k))]

function compare_stage(label, results, oldf, partsf, tv)
    params = results.params
    _, old_load, old_disp = oldf(results, 1 / 1000, tv)
    new_disp = P._dispatch_data(results, partsf(results, 1 / 1000), tv)

    ok_names, ok_vals = true, true
    for z in params.sets.Z
        o, n = old_disp[z], new_disp.zones[z]
        for (om, ot, nm, nt, used) in
                ((o.pos_mat, o.pos_types, n.pos_mat, new_disp.pos_types, n.pos_used),
                 (o.neg_mat, o.neg_types, n.neg_mat, new_disp.neg_types, n.neg_used))
            od, nd = _decum(om), _decum(nm)
            new_used = [nt[i] for i in eachindex(nt) if used[i]]
            ok_names &= _signif_names(ot, od) ==
                        _signif_names(new_used, nd[:, [i for i in eachindex(nt) if used[i]]])

            for (k, ty) in enumerate(ot)
                j = findfirst(==(ty), nt)
                if j === nothing
                    # only acceptable if the old side was negligible there too
                    ok_vals &= !_significant(view(od, :, k))
                else
                    ok_vals &= isapprox(od[:, k], nd[:, j]; atol = 1e-10)
                end
            end
            # a series the old side never had must be negligible for this zone
            for (j, ty) in enumerate(nt)
                ty in ot && continue
                ok_vals &= !_significant(view(nd, :, j))
            end
        end
    end
    check("$label series names", ok_names)
    check("$label stack values", ok_vals)

    old_price = old_price_by_zone(results, Set(tv))
    new_price = P._price_points_by_zone(results, Dict{Int,Int}(Int(t) => i for (i, t) in enumerate(tv)))
    check("$label zonal prices", all(params.sets.Z) do z
        o = old_price[z]
        length(new_price[z]) == nrow(o) &&
            all(Float32(o.Time[i]) == new_price[z][i][1] for i = 1:nrow(o)) &&
            all(isapprox(Float32(o.MarketBalance[i]), new_price[z][i][2]; rtol = 1e-6) for i = 1:nrow(o))
    end)

    new_load = P._load_by_zone(results, tv)
    check("$label zonal load",
          all(z -> isapprox(old_load[z].orig_load, new_load[z].orig_load; atol = 1e-12),
              params.sets.Z))
    return nothing
end

function verify_scenario(name, results)
    println("\n  scenario: $name")
    tv = collect(1:maximum(results.GEN.Time))
    compare_stage("DA", results, old_prepare_disp, P._disp_parts, tv)
    if results.REDISP isa DataFrame && !isempty(results.REDISP)
        compare_stage("REDISP", results, old_prepare_redisp, P._redisp_parts, tv)
    end
    check("_redisp_slack_volume",
          isapprox(old_slack(results), P._redisp_slack_volume(results); atol = 1e-9))
    return nothing
end

"""
Sign invariants of the interactive line map.

These are NOT old-vs-new comparisons — the arrows and direction heads have no pre-refactor
counterpart. They are the checks that catch the one class of bug that produces a perfectly
plausible figure: an orientation that is exactly backwards. Both conventions they pin are
stated in the `CLAUDE.md` NETINPUT block.

- `_net_injection_matrix` must be the **negated** `NETINPUT` column. `NETINPUT` is
  import-positive (`load + charge − gen`), the arrows are export-positive.
- `ACINJECTION[n,t] == Σ_l incidence[l,n] · LINEFLOW[l,t]` with
  `incidence[l, line_start] = -1`, `incidence[l, line_end] = +1`. This is what makes a
  positive `LINEFLOW` mean "flow from `line_start` to `line_end`", i.e. it pins which way
  the per-line arrowheads point. It holds exactly on a stage built by `add_dclf`; every
  scenario in `solve_subset` has a `DCLF` redispatch, so the composite view is one.
"""
function verify_map_signs(name, results)
    println("\n  map signs: $name")
    params = results.params

    _, times, _, F, S = P._line_util_matrix(results, false)
    check("signed flow magnitude matches |flow|", isapprox(abs.(S), F; atol = 1e-9))

    nodes = sort(unique(String.(results.NETINPUT.index)))
    tpos = Dict(t => i for (i, t) in enumerate(times))
    npos = Dict(n => i for (i, n) in enumerate(nodes))

    expected = zeros(Float64, length(nodes), length(times))
    for r in eachrow(results.NETINPUT)
        expected[npos[String(r.index)], tpos[Int(r.Time)]] = -Float64(r.NETINPUT)
    end
    NI = P._net_injection_matrix(results, nodes, times)
    # `NI` is Float32 (it feeds a plot buffer), the reference is Float64, so the comparison
    # has to be relative: at a few hundred MW, Float32 resolution alone is ~1e-4.
    if NI === nothing
        check("_net_injection_matrix is the negated NETINPUT", false)
    else
        d = maximum(abs.(Float64.(NI) .- expected); init = 0.0)
        scale = maximum(abs.(expected); init = 0.0)
        println("      max |NI - (-NETINPUT)| = $d over values up to $scale")
        check("_net_injection_matrix is the negated NETINPUT",
              isapprox(NI, expected; rtol = 1e-5, atol = 1e-6))
    end

    # `ACINJECTION` is the AC-only part, so the sum runs over AC lines alone.
    acinj = zeros(Float64, length(nodes), length(times))
    for r in eachrow(results.LINEFLOW)
        l, j, f = String(r.index), tpos[Int(r.Time)], Float64(r.LINEFLOW)
        s, e = params.line_start[l], params.line_end[l]
        haskey(npos, s) && (acinj[npos[s], j] -= f)
        haskey(npos, e) && (acinj[npos[e], j] += f)
    end
    reported = zeros(Float64, length(nodes), length(times))
    for r in eachrow(results.NETINPUT)
        reported[npos[String(r.index)], tpos[Int(r.Time)]] = Float64(r.ACINJECTION)
    end
    check("positive LINEFLOW runs line_start -> line_end",
          isapprox(acinj, reported; atol = 1e-6))
    return nothing
end

"""
Reference-day checks. The golden grid has no `ReferenceDayBasecase` scenario, so these
need a result directory from such a run, passed on the command line or via
`POMATWO_REFDAY_DIR`. Skipped with a note when none is available.
"""
function verify_refday(dir, source)
    println("\n  refday: $dir")
    variant = DataFiles(dir)
    if !(variant.REFDAY_SHIFT isa DataFrame) || isempty(variant.REFDAY_SHIFT)
        println("    SKIP  no REFDAY_SHIFT trace in $dir")
        return nothing
    end
    vparams = variant.params

    old_sa = old_shift_arrays(variant)
    new_sa = P._shift_arrays(variant)
    check("shift times", old_sa.times == new_sa.times)
    check("shift nodes", old_sa.nodes == new_sa.nodes)
    check("shift comp_mats",
          all(k -> isapprox(old_sa.comp_mats[k], new_sa.comp_mats[k]; atol = 1e-9),
              keys(old_sa.comp_mats)))
    check("shift total", isapprox(old_sa.total, new_sa.total; atol = 1e-9))
    oldu = Dict{Int,Float64}()
    for r in eachrow(old_sa.unabsorbed)
        oldu[r.Time] = get(oldu, r.Time, 0.0) + abs(r.delta)
    end
    check("shift np_relax per time",
          all(t -> isapprox(oldu[t], get(new_sa.unabsorbed, t, 0.0); atol = 1e-9), keys(oldu)))

    refmap, _ = P._refday_zone_ref_times(variant)
    target_times = sort(unique(Int.(variant.GEN.Time)))
    ref_times = Set{Int}()
    for d in values(refmap), r in values(d)
        push!(ref_times, r)
    end
    times = sort!(collect(union(ref_times, Set(target_times))))
    timepos = Dict(t => i for (i, t) in enumerate(times))
    zones = sort(collect(keys(refmap)))

    new_src = P._build_zone_key_table(zones, timepos) do f
        P._emit_plant_column(f, source.GEN, :GEN, vparams.plant2zone, vparams.plant_type, nothing)
    end
    old_src = old_gen_by_zone_type(source, Set(times))
    ok = Ref(true)
    for z in zones, t in times, k in new_src.keys
        o = get(get(old_src, z, Dict{Int,Dict{String,Float64}}()), t, Dict{String,Float64}())
        ok[] &= isapprox(get(o, k, 0.0), P._zk_value(new_src, z, k, timepos[t]); atol = 1e-9)
    end
    check("_ZoneKeyTable GEN vs nested dict", ok[])

    new_shift = P._build_zone_key_table(zones, timepos) do f
        P._emit_shift_rows(f, variant.REFDAY_SHIFT, vparams.node2zone)
    end
    old_sh = old_shift_by_zone(variant)
    ok = Ref(true)
    for z in zones, t in times, k in new_shift.keys
        o = get(get(old_sh, z, Dict{Int,Dict{String,Float64}}()), t, Dict{String,Float64}())
        ok[] &= isapprox(get(o, k, 0.0), P._zk_value(new_shift, z, k, timepos[t]); atol = 1e-9)
    end
    check("_ZoneKeyTable REFDAY_SHIFT vs nested dict", ok[])

    new_chg = P._build_zone_key_table(zones, timepos) do f
        P._emit_plant_column(f, hasproperty(source, :CHARGE) ? source.CHARGE : nothing,
                             :CHARGE, vparams.plant2zone, vparams.plant_type, P._CHARGE_KEY)
    end
    old_ch = old_charge_by_zone(source, Set(times))
    check("_ZoneKeyTable CHARGE vs nested dict",
          all(isapprox(get(get(old_ch, z, Dict{Int,Float64}()), t, 0.0),
                       P._zk_value(new_chg, z, P._CHARGE_KEY, timepos[t]); atol = 1e-9)
              for z in zones, t in times))

    nzl = P._zone_load_series(vparams, times)
    check("_zone_load_series vs _refday_zone_load",
          all(isapprox(old_refday_zone_load(vparams, z, t), nzl[z][timepos[t]]; atol = 1e-9)
              for z in zones if haskey(nzl, z) for t in times))
    return nothing
end

function main()
    println("Plotting extension — old-vs-new equivalence oracle")
    tmpdir = mktempdir()
    @info "Solving a subset of golden_grid() into $tmpdir"
    for (name, results) in solve_subset(tmpdir)
        verify_scenario(name, results)
        verify_map_signs(name, results)
    end

    refday_dir = length(ARGS) >= 1 ? ARGS[1] : get(ENV, "POMATWO_REFDAY_DIR", "")
    if isempty(refday_dir)
        println("\n  refday checks SKIPPED — golden_grid() has no ReferenceDayBasecase scenario.")
        println("  Pass a result directory from such a run to include them:")
        println("      julia test/verify_plotting_equivalence.jl <refday_results_dir>")
    elseif !isdir(refday_dir)
        println("\n  refday directory not found: $refday_dir")
        push!(FAILS, "refday dir missing")
    else
        # `source` is the basecase run the shift started from; the sibling "forecast"
        # directory when there is one, else the variant itself.
        sib = joinpath(dirname(refday_dir), "forecast")
        source = DataFiles(isdir(sib) ? sib : refday_dir)
        verify_refday(refday_dir, source)
    end

    println("\n", "="^70)
    if isempty(FAILS)
        println("ALL EQUIVALENCE CHECKS PASSED")
    else
        println("FAILURES (", length(FAILS), "): ", join(FAILS, ", "))
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main()
end
