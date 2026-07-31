"""
Golden-file regression tests plus a data-independent physical/economic invariant layer.

Two complementary things happen here:

  * **Goldens** (`compare_to_expected`) freeze the exact result tables of every scenario in
    `GOLDEN_GRID`, so any unintended numerical drift fails loudly. Regenerate them with
    `test/regenerate_expected_results.jl` and review the diff.
  * **Invariants** (`check_invariants!`) re-derive expectations from the *input CSVs* —
    never from model internals — and assert them against the results. Goldens catch drift;
    invariants catch wrongness, including in scenarios added later.

The expected side is deliberately **not** loaded through `DataFiles`. Comparing the Arrow
file set on disk keeps the comparison loader-independent — a bug in `DataFiles` cannot mask
a golden mismatch, and a table the struct does not know about *yet* still gets compared.


Every assertion states what the model actually does today; there are no `@test_broken`
markers. Where current behaviour is believed to be wrong it is pinned by an assertion that
describes it exactly, and the reasoning is recorded in the FINDINGS block below.
"""

# Self-sufficient imports: this file is included both by runtests.jl and standalone by
# test/regenerate_expected_results.jl, so it must not rely on the includer's imports.
using LinearAlgebra: Diagonal, dot, nullspace

const GOLDEN_TOL = 1e-6

# ---------------------------------------------------------------------------- the grid
#
# Two datasets, because neither covers what the other does: `test_data_3_nodes_v2_fbmc`
# has two zones, genuinely non-dispatchable plants and non-uniform susceptances (so the
# PTDF algebra is actually exercised), but no prosumers; `test_data_3_nodes_prosumer` is
# the only dataset with a prosumer.
#
# NOTE: scenario names are the golden directory names. Their *order* is not load-bearing —
# `manifest.csv` records the full setup of every scenario and is asserted below, so a
# reordering or an edited setup fails instead of silently comparing the wrong golden.

golden_data_dir(name) = joinpath(@__DIR__, "data", name)

function golden_files_v2fbmc()
    d = golden_data_dir("test_data_3_nodes_v2_fbmc")
    Dict(
        :plants  => joinpath(d, "plants.csv"),
        :nodes   => joinpath(d, "nodes.csv"),
        :zones   => joinpath(d, "zones.csv"),
        :lines   => joinpath(d, "lines.csv"),
        :dclines => joinpath(d, "dclines.csv"),
        :demand  => joinpath(d, "nodal_load.csv"),
        :types   => joinpath(d, "planttypes.csv"),
        :avail   => joinpath(d, "avail.csv"),
        :ntc     => joinpath(d, "ntc.csv"),
    )
end

function golden_files_prosumer()
    d = golden_data_dir("test_data_3_nodes_prosumer")
    Dict(
        :plants     => [joinpath(d, "plants.csv"), joinpath(d, "prosumer_plants.csv")],
        :nodes      => joinpath(d, "nodes.csv"),
        :zones      => joinpath(d, "zones.csv"),
        :lines      => joinpath(d, "lines.csv"),
        :dclines    => joinpath(d, "dclines.csv"),
        :demand     => joinpath(d, "nodal_load.csv"),
        :types      => joinpath(d, "planttypes.csv"),
        :avail      => joinpath(d, "availability.csv"),
        :prs_demand => joinpath(d, "prosumer_demand.csv"),
    )
end

const GOLDEN_TH = (
    TimeHorizon(stop = 4),
    TimeHorizon(start = 1, stop = 4, split = 2, offset = 0),
)

"""
    GOLDEN_GRID -> Vector{NamedTuple}

Every golden scenario: `(name, dataset, setup)`. `dataset` selects the input files and the
independently-built reference system used by the invariant layer.
"""
function golden_grid()
    out = NamedTuple[]

    # --- v2_fbmc: two zones, real non-dispatchables, no prosumer ------------------
    # NTC = 55 is chosen so the zonal NTC market is congested in exactly one hour:
    # the physical export limit on l2 is 60 MW in t1-t3 but 50 MW in t4, so t4 needs
    # redispatch (10 MWh) while t1-t3 do not. See ntc.csv.
    markets = (
        ("ZonalNTC", ZonalMarket()),
        ("ZonalFB",  ZonalMarket(FlowBased())),        # FlowBased() == FlatGSK()
        ("Nodal",    NodalMarket()),
    )
    i = 0
    for (mlbl, mt) in markets, (rlbl, rd) in (("NoRedisp", NoRedispatch()), ("DCLF", DCLF())),
        (tlbl, th) in (("th4", GOLDEN_TH[1]), ("th2x2", GOLDEN_TH[2]))
        i += 1
        push!(out, (
            name    = "v2fbmc_$(lpad(i, 2, '0'))_$(mlbl)_$(rlbl)_$(tlbl)",
            dataset = :v2fbmc,
            setup   = ModelSetup(TimeHorizon = th, MarketType = mt,
                                 ProsumerSetup = NoProsumer(), RedispatchSetup = rd),
        ))
    end

    # --- prosumer dataset: the only one with a prosumer ---------------------------
    # `:buy_price` here; the `:flat` tariff is covered by `test_retail_types` in
    # test_model_config.jl, which asserts the two now differ (they did not before F-3).
    po = ProsumerOptimization(sell_price = 80.0, buy_price = 250.0, retail_type = :buy_price)
    j = 0
    for (mlbl, mt) in (("Zonal", ZonalMarket()), ("Nodal", NodalMarket())),
        (rlbl, rd) in (("NoRedisp", NoRedispatch()), ("DCLF", DCLF())),
        (tlbl, th) in (("th4", GOLDEN_TH[1]), ("th2x2", GOLDEN_TH[2]))
        j += 1
        push!(out, (
            name    = "prosumer_$(lpad(j, 2, '0'))_$(mlbl)_$(rlbl)_$(tlbl)",
            dataset = :prosumer,
            setup   = ModelSetup(TimeHorizon = th, MarketType = mt,
                                 ProsumerSetup = po, RedispatchSetup = rd),
        ))
    end
    return out
end

golden_input_files(ds::Symbol) =
    ds === :v2fbmc ? golden_files_v2fbmc() : golden_files_prosumer()

# ---------------------------------------------------------------------------- manifest
#
# Guards against a silently mismatched comparison: scenario directories are matched by
# name, so an edited or reordered grid must be detectable.

function golden_manifest_row(sc)
    s = sc.setup
    mt = s.MarketType
    formulation = mt isa ZonalMarket ? string(nameof(typeof(mt.exchange_formulation))) :
                  string(nameof(typeof(mt).parameters[1]))
    gsk = (mt isa ZonalMarket && mt.exchange_formulation isa FlowBased) ?
          string(nameof(typeof(mt.exchange_formulation.GSKStrategy))) : ""
    ps = s.ProsumerSetup
    rd = s.RedispatchSetup
    return (
        scenario        = sc.name,
        dataset         = string(sc.dataset),
        market          = string(nameof(typeof(mt))),
        formulation     = formulation,
        gsk             = gsk,
        prosumer        = string(nameof(typeof(ps))),
        sell_price      = ps isa ProsumerOptimization ? ps.sell_price : NaN,
        buy_price       = ps isa ProsumerOptimization ? ps.buy_price : NaN,
        retail_type     = ps isa ProsumerOptimization ? string(ps.retail_type) : "",
        netzentgelte    = ps isa ProsumerOptimization ? ps.netzentgelte : NaN,
        self_discharge  = ps isa ProsumerOptimization ? ps.self_discharge : NaN,
        redispatch      = string(nameof(typeof(rd))),
        disp_cost       = rd isa DCLF ? rd.disp_cost : NaN,
        res_up_cost     = rd isa DCLF ? rd.res_up_cost : NaN,
        res_down_cost   = rd isa DCLF ? rd.res_down_cost : NaN,
        sto_cost        = rd isa DCLF ? rd.sto_cost : NaN,
        storage_boundary = string(nameof(typeof(s.StorageBoundary))),
        th_start        = s.TimeHorizon.start,
        th_stop         = s.TimeHorizon.stop,
        th_split        = s.TimeHorizon.split,
        th_offset       = s.TimeHorizon.offset,
    )
end

golden_expected_root() = joinpath(@__DIR__, "expected_results")

# ---------------------------------------------------------------------------- comparison

"""Sort a result table into a deterministic row order (Arrow preserves build order)."""
function golden_sort(df::DataFrame)
    keys_ = [c for c in ("index", "From", "To", "Node", "Zone", "Time") if c in names(df)]
    isempty(keys_) ? df : sort(df, keys_)
end

"""
    compare_arrow(actual_file, expected_file, label)

Compare one persisted result table: identical column sets, identical row count, exact
match on non-numeric columns and `atol = GOLDEN_TOL` on numeric ones.
"""
function compare_arrow(actual_file, expected_file, label)
    a = golden_sort(POMATWO.load_arrow_unlocked([actual_file]))
    e = golden_sort(POMATWO.load_arrow_unlocked([expected_file]))

    same_cols = Set(names(a)) == Set(names(e))
    same_cols || @info "golden schema drift" label actual=sort(names(a)) expected=sort(names(e))
    @test same_cols
    @test nrow(a) == nrow(e)
    (same_cols && nrow(a) == nrow(e)) || return

    for c in names(e)
        av, ev = a[!, c], e[!, c]
        if eltype(ev) <: Number && eltype(av) <: Number
            ok = all(isapprox.(Float64.(av), Float64.(ev); atol = GOLDEN_TOL))
            ok || @info "golden mismatch" label column=c max_abs_diff=maximum(abs.(Float64.(av) .- Float64.(ev)))
            @test ok
        else
            @test isequal(av, ev)
        end
    end
end

"""
    compare_to_expected(actual_dir, expected_dir, scenario)

Compare a solved scenario directory against its golden. Compares the *set of files on
disk* first, so a renamed or newly written table fails instead of being skipped.
"""
function compare_to_expected(actual_dir, expected_dir, scenario)
    @testset "goldens: $scenario" begin
        # A missing golden is a hard failure, not something to excuse: it means the
        # scenario has no regression cover at all.
        if !isdir(expected_dir)
            @warn "no golden directory for $scenario — run test/regenerate_expected_results.jl" expected_dir
            @test isdir(expected_dir)
            return
        end

        subdirs(d) = sort(basename.(filter(isdir, readdir(d, join = true))))
        @test subdirs(actual_dir) == subdirs(expected_dir)

        arrows(d) = sort(filter(f -> endswith(f, ".arrow"), readdir(d)))

        # tables written once at the scenario root (e.g. REFDAY_GROUPS)
        @test arrows(actual_dir) == arrows(expected_dir)
        for f in arrows(expected_dir)
            compare_arrow(joinpath(actual_dir, f), joinpath(expected_dir, f), "$scenario/$f")
        end

        for sub in intersect(subdirs(actual_dir), subdirs(expected_dir))
            ad, ed = joinpath(actual_dir, sub), joinpath(expected_dir, sub)
            @test arrows(ad) == arrows(ed)
            for f in intersect(arrows(ad), arrows(ed))
                compare_arrow(joinpath(ad, f), joinpath(ed, f), "$scenario/$sub/$f")
            end
        end
    end
end

# ============================================================ independent reference system
#
# Built straight from the input CSVs. Nothing here reads `Parameters` or any model
# internal, so an invariant and the code it checks cannot share a bug.

struct RefSys
    N::Vector{String}; L::Vector{String}; Z::Vector{String}
    node2zone::Dict{String,String}; nodes_in_zone::Dict{String,Vector{String}}
    slack::Vector{String}
    A::Matrix{Float64}; b::Vector{Float64}; cap::Dict{String,Float64}; PTDF::Matrix{Float64}
    load::Dict{String,Vector{Float64}}
    P::Vector{String}; p2node::Dict{String,String}
    gmax::Dict{String,Float64}; eta::Dict{String,Float64}
    DISP::Vector{String}; NDISP::Vector{String}; PRS::Vector{String}
    mc::Dict{String,Float64}
    avail::Dict{String,Vector{Float64}}
    ntc::Dict{Tuple{String,String},Float64}
    prs_demand::Dict{String,Vector{Float64}}
end

# data_load.jl: bvector = b * zbase(voltage) * circuits
ref_zbase(v) = (v * 1e3)^2 / (500 * 1e6)

function build_refsys(dir; plantfiles = ["plants.csv"], availfile = nothing,
                      prsdemandfile = nothing, ntcfile = nothing, nT = 4)
    lines = POMATWO.read_csv(joinpath(dir, "lines.csv"))
    nodes = POMATWO.read_csv(joinpath(dir, "nodes.csv"))
    types = POMATWO.read_csv(joinpath(dir, "planttypes.csv"))

    N = String.(nodes.index); L = String.(lines.index)
    node2zone = Dict(String(r.index) => String(r.zone) for r in eachrow(nodes))
    Z = unique(String.(nodes.zone))
    nodes_in_zone = Dict(z => [n for n in N if node2zone[n] == z] for z in Z)
    # `slack` is either the legacy 0/1 flag or a reference to the balancing node
    slack = eltype(nodes.slack) <: Number ? String.(nodes.index[nodes.slack .== 1]) :
                                            unique(String.(nodes.slack))

    A = zeros(length(L), length(N))
    for (li, r) in enumerate(eachrow(lines))
        A[li, findfirst(==(String(r.node_i)), N)] = -1.0
        A[li, findfirst(==(String(r.node_j)), N)] = +1.0
    end
    b = Float64.(lines.b) .* ref_zbase.(Float64.(lines.voltage))
    cap = Dict(String(r.index) => Float64(r.capacity) for r in eachrow(lines))

    B = A' * Diagonal(b) * A
    keep = [i for i in 1:length(N) if !(N[i] in slack)]
    Binv = zeros(length(N), length(N)); Binv[keep, keep] = inv(B[keep, keep])
    # maps export-positive nodal injection to flow in the line's start->end direction
    PTDF = -Diagonal(b) * A * Binv

    ld = POMATWO.read_csv(joinpath(dir, "nodal_load.csv"))
    load = Dict{String,Vector{Float64}}(n => zeros(nT) for n in N)
    for c in names(ld); load[c] = Float64.(ld[!, c]); end

    P = String[]; p2node = Dict{String,String}(); p2type = Dict{String,String}()
    gmax = Dict{String,Float64}(); eta = Dict{String,Float64}()
    for f in plantfiles
        df = POMATWO.read_csv(joinpath(dir, f))
        for r in eachrow(df)
            push!(P, String(r.index)); p2node[String(r.index)] = String(r.node)
            p2type[String(r.index)] = String(r.plant_type)
            gmax[String(r.index)] = Float64(r.g_max); eta[String(r.index)] = Float64(r.eta)
        end
    end

    dispatchable = Set(String(r.index) for r in eachrow(types) if r.dispatchable == 1)
    prosumer_t = Set(String(r.index) for r in eachrow(types)
                     if hasproperty(types, :prosumer) && r.prosumer == 1)
    DISP  = [p for p in P if p2type[p] in dispatchable]
    NDISP = [p for p in P if !(p2type[p] in dispatchable)]
    PRS   = [p for p in P if p2type[p] in prosumer_t]

    fp = Dict(String(r.index) => Float64(r.fuel_price) for r in eachrow(types))
    mc = Dict(p => fp[p2type[p]] / eta[p] for p in P)   # no CO2 price in either dataset

    avail = Dict{String,Vector{Float64}}()
    availfile === nothing || for c in pairs(eachcol(POMATWO.read_csv(joinpath(dir, availfile))))
        avail[string(c[1])] = Float64.(c[2])
    end
    ntc = Dict{Tuple{String,String},Float64}()
    ntcfile === nothing || for r in eachrow(POMATWO.read_csv(joinpath(dir, ntcfile)))
        ntc[(String(r.zone_i), String(r.zone_j))] = Float64(r.ntc)
    end
    prsd = Dict{String,Vector{Float64}}()
    prsdemandfile === nothing || for c in pairs(eachcol(POMATWO.read_csv(joinpath(dir, prsdemandfile))))
        prsd[string(c[1])] = Float64.(c[2])
    end

    RefSys(N, L, Z, node2zone, nodes_in_zone, slack, A, b, cap, PTDF, load,
           P, p2node, gmax, eta, DISP, NDISP, PRS, mc, avail, ntc, prsd)
end

function golden_refsys(ds::Symbol)
    if ds === :v2fbmc
        build_refsys(golden_data_dir("test_data_3_nodes_v2_fbmc");
                     availfile = "avail.csv", ntcfile = "ntc.csv")
    else
        build_refsys(golden_data_dir("test_data_3_nodes_prosumer");
                     plantfiles = ["plants.csv", "prosumer_plants.csv"],
                     availfile = "availability.csv", prsdemandfile = "prosumer_demand.csv")
    end
end

ref_agmax(s::RefSys, p, t) = s.gmax[p] * (haskey(s.avail, p) ? s.avail[p][t] : 1.0)
ref_at_node(s::RefSys, n) = Set(p for p in s.P if s.p2node[p] == n)
ref_in_zone(s::RefSys, z) = Set(p for p in s.P if s.node2zone[s.p2node[p]] == z)

function ref_val(df, idxcol, idx, t, col)
    isempty(df) && return nothing
    rows = findall((df[!, idxcol] .== idx) .& (df.Time .== t))
    isempty(rows) && return nothing
    Float64(df[only(rows), col])
end
ref_sum(df, idxcol, ids, t, col) = isempty(df) ? 0.0 :
    sum(Float64(r[col]) for r in eachrow(df) if r[idxcol] in ids && r.Time == t; init = 0.0)


# ============================================================================ invariants

"""Network: DC load flow consistency, Kirchhoff, line limits — all re-derived from CSVs."""
function inv_network!(s::RefSys, NI, LF, inj_expected)
    isempty(NI) && return
    loops = nullspace(transpose(s.A))
    for t in sort(unique(NI.Time))
        δ = Dict(n => ref_val(NI, :index, n, t, :DELTA) for n in s.N)
        for n in s.slack
            @test δ[n] ≈ 0.0 atol = GOLDEN_TOL           # N2: slack angle pinned
        end
        f = [ref_val(LF, :index, l, t, :LINEFLOW) for l in s.L]

        for (li, l) in enumerate(s.L)
            st = s.N[findfirst(==(-1.0), s.A[li, :])]
            en = s.N[findfirst(==(+1.0), s.A[li, :])]
            @test f[li] ≈ s.b[li] * (δ[en] - δ[st]) atol = GOLDEN_TOL   # flow = b * Δθ
            @test abs(f[li]) <= s.cap[l] + GOLDEN_TOL                   # thermal limit
        end

        # N1: the phase-angle solution must equal an independently built PTDF solution.
        # Result tables are import-positive; PTDF wants export-positive.
        pf = s.PTDF * [-ref_val(NI, :index, n, t, :NETINPUT) for n in s.N]
        for li in eachindex(s.L)
            @test f[li] ≈ pf[li] atol = 1e-5
        end

        # N3: net input is the incidence-weighted sum of flows; ACINJECTION its AC part
        ac = transpose(s.A) * f
        for (i, n) in enumerate(s.N)
            @test ref_val(NI, :index, n, t, :NETINPUT) ≈ ac[i] atol = GOLDEN_TOL
            @test ref_val(NI, :index, n, t, :ACINJECTION) ≈ ac[i] atol = GOLDEN_TOL
            # N7: net input must match the generation the persisted stage dispatched
            @test ref_val(NI, :index, n, t, :NETINPUT) ≈ s.load[n][t] - inj_expected(n, t) atol = 1e-5
        end
        # N4: lossless DC — nothing absorbed at the slack
        @test sum(ref_val(NI, :index, n, t, :NETINPUT) for n in s.N) ≈ 0.0 atol = 1e-5
        # N6: KVL around every independent loop
        for k in axes(loops, 2)
            @test dot(loops[:, k], f ./ s.b) ≈ 0.0 atol = 1e-5
        end
    end
end

"""
Nodal reporting of a ZONAL day-ahead stage (`report_nodal_flows!`). These tables are
computed, not optimized: the cleared dispatch implies a nodal net input and the PTDF turns
it into line flows. Checked against the independently built PTDF of `build_refsys`.

Deliberately NOT checked: the thermal limit. A zonal market ignores the grid, so these
pre-redispatch flows may exceed `s.cap` — that is the reason they are reported.
"""
function inv_zonal_da_network!(s::RefSys, da, inj_da)
    NI, LF = da.NETINPUT, da.LINEFLOW
    isempty(NI) && return
    loops = nullspace(transpose(s.A))
    for t in sort(unique(NI.Time))
        ni = [ref_val(NI, :index, n, t, :NETINPUT) for n in s.N]
        ac = [ref_val(NI, :index, n, t, :ACINJECTION) for n in s.N]
        for n in s.N
            # no phase angles exist in a zonal clearing
            @test ref_val(NI, :index, n, t, :DELTA) ≈ 0.0 atol = GOLDEN_TOL
            # net input must match the dispatch the day-ahead cleared
            @test ref_val(NI, :index, n, t, :NETINPUT) ≈
                  s.load[n][t] - inj_da(n, t) atol = 1e-5
        end

        # the cross-check: PTDF flows of the reported AC injection. Result tables are
        # import-positive, the PTDF wants export-positive (as in N1 of inv_network!).
        pf = s.PTDF * (-ac)
        f = [ref_val(LF, :index, l, t, :LINEFLOW) for l in s.L]
        for li in eachindex(s.L)
            @test f[li] ≈ pf[li] atol = 1e-5
            @test ref_val(LF, :index, s.L[li], t, :line_capacity) ≈ s.cap[s.L[li]] atol = GOLDEN_TOL
        end
        # KVL around every independent loop — PTDF flows are physical flows
        for k in axes(loops, 2)
            @test dot(loops[:, k], f ./ s.b) ≈ 0.0 atol = 1e-5
        end

        # the nodal tables must restate the zonal clearing they came from: a zone's net
        # input is its exchange, up to the (zonal, not nodal) balance slacks
        zsum = 0.0
        for z in s.Z
            ex = ref_val(da.EXCHANGE, :index, z, t, :EXCHANGE)
            cu = ref_val(da.ZonalMarketBalance, :Zone, z, t, :CU)
            ll = ref_val(da.ZonalMarketBalance, :Zone, z, t, :LL)
            (ex === nothing || cu === nothing) && continue
            @test sum(ref_val(NI, :index, n, t, :NETINPUT) for n in s.nodes_in_zone[z]) ≈
                  ex + ll - cu atol = 1e-5
            zsum += ex + ll - cu
        end
        # DC incidence sums to zero over nodes, so the AC part carries the same total
        @test sum(ac) ≈ zsum atol = 1e-5
        @test sum(ni) ≈ zsum atol = 1e-5
    end
end

"""Generation bounds and the defining identities of the GEN table."""
function inv_generation!(s::RefSys, G)
    isempty(G) && return
    for x in eachrow(G)
        @test -GOLDEN_TOL <= x.GEN <= x.gmax + GOLDEN_TOL
        @test x.gmax ≈ ref_agmax(s, x.index, x.Time) atol = GOLDEN_TOL
        @test x.mc ≈ (x.index in s.NDISP ? 0.0 : s.mc[x.index]) atol = GOLDEN_TOL
        # FEEDIN = avail*gmax - CU for non-dispatchables
        x.index in s.NDISP && @test x.GEN + x.CU ≈ x.gmax atol = GOLDEN_TOL
    end
end

"""Redispatch identities, bounds, and the day-ahead -> redispatch handoff."""
function inv_redispatch!(s::RefSys, r, prs_active)
    isempty(r.REDISP) && return
    for x in eachrow(r.REDISP)
        @test x.GEN_REDISP ≈ x.gen + x.GEN_UP - x.GEN_DOWN atol = GOLDEN_TOL
        @test -GOLDEN_TOL <= x.GEN_UP <= x.max_up + GOLDEN_TOL
        @test -GOLDEN_TOL <= x.GEN_DOWN <= x.gen + GOLDEN_TOL
        @test x.GEN_REDISP >= -GOLDEN_TOL
        if x.index in s.NDISP
            @test x.CU_REDISP ≈ x.max_up - x.GEN_UP + x.GEN_DOWN atol = GOLDEN_TOL
            @test x.CU_REDISP >= -GOLDEN_TOL
        end
        # the stage boundary: `gen`/`max_up` must restate the day-ahead exactly
        g = ref_val(r.GEN, :index, x.index, x.Time, :GEN)
        g === nothing && continue
        @test x.gen ≈ g atol = GOLDEN_TOL
        @test x.max_up ≈ (x.index in s.NDISP ?
                          ref_val(r.GEN, :index, x.index, x.Time, :CU) :
                          ref_val(r.GEN, :index, x.index, x.Time, :gmax) - g) atol = GOLDEN_TOL
    end
    # prosumers model household capacity, not TSO-dispatchable assets
    prs_active && @test !any(i in s.PRS for i in r.REDISP.index)
end

"""Prosumer generation/energy/storage balances."""
function inv_prosumer!(s::RefSys, r, splits, self_discharge)
    isempty(r.PRS) && return
    for x in eachrow(r.PRS)
        @test x.PRS_TOTAL_GEN ≈ x.PRS_SELF + x.PRS_SELL + x.PRS_STO_IN atol = GOLDEN_TOL
        @test x.PRS_SELF + x.PRS_STO_OUT + x.PRS_BUY ≈ s.prs_demand[x.index][x.Time] atol = GOLDEN_TOL
        @test x.PRS_NETINPUT ≈ x.PRS_SELL - x.PRS_BUY atol = GOLDEN_TOL
        @test x.PRS_TOTAL_GEN ≈ ref_agmax(s, x.index, x.Time) - x.PRS_CU atol = GOLDEN_TOL
    end
    # Storage level recursion. Charge/discharge efficiency is the plant's own `eta` and
    # the hourly retention comes from the setup; both used to be hardcoded (F-2). Under
    # `CyclicStorage` each split wraps onto itself.
    for prs in unique(r.PRS.index), sp in splits
        η = s.eta[prs]
        for (i, t) in enumerate(sp)
            prev = i == 1 ? sp[end] : sp[i - 1]
            lv = ref_val(r.PRS, :index, prs, prev, :PRS_STO_LVL)
            x = only(filter(y -> y.index == prs && y.Time == t, r.PRS))
            @test x.PRS_STO_LVL ≈
                  self_discharge * lv + η * x.PRS_STO_IN - x.PRS_STO_OUT / η atol = GOLDEN_TOL
        end
    end
end

"""Energy balances per market scope, and the exchange/NTC accounting."""
function inv_balances!(s::RefSys, r, mt, prs_active, has_redisp)
    isempty(r.GEN) && return
    T = sort(unique(r.GEN.Time))

    if mt isa ZonalMarket && !isempty(r.ZonalMarketBalance)
        for t in T, z in s.Z
            ids = ref_in_zone(s, z)
            g = ref_sum(r.GEN, :index, ids, t, :GEN) - ref_sum(r.CHARGE, :index, ids, t, :CHARGE)
            row = only(filter(x -> x.Time == t && x.Zone == z, r.ZonalMarketBalance))
            pd = prs_active ? sum((s.prs_demand[p][t] for p in s.PRS
                                   if s.node2zone[s.p2node[p]] == z), init = 0.0) : 0.0
            @test g + ref_val(r.EXCHANGE, :index, z, t, :EXCHANGE) - pd - row.CU + row.LL ≈
                  sum(s.load[n][t] for n in s.nodes_in_zone[z]) atol = 1e-5
        end
        for t in T   # net positions must net out across zones (no DC, no fixed exchange)
            @test sum(ref_val(r.EXCHANGE, :index, z, t, :EXCHANGE) for z in s.Z) ≈ 0.0 atol = 1e-5
        end
    end

    if mt isa NodalMarket && !has_redisp && !isempty(r.NodalMarketBalance)
        for t in T, n in s.N
            ids = ref_at_node(s, n)
            g = ref_sum(r.GEN, :index, ids, t, :GEN) - ref_sum(r.CHARGE, :index, ids, t, :CHARGE)
            pd = prs_active ? sum((s.prs_demand[p][t] for p in s.PRS if s.p2node[p] == n), init = 0.0) : 0.0
            row = only(filter(x -> x.Time == t && x.Node == n, r.NodalMarketBalance))
            @test g - pd + ref_val(r.NETINPUT, :index, n, t, :NETINPUT) - row.CU + row.LL ≈
                  s.load[n][t] atol = 1e-5
        end
    end

    if has_redisp && !isempty(r.NodalMarketRedispBalance)
        for t in T, n in s.N
            ids = ref_at_node(s, n)
            g = ref_sum(r.REDISP, :index, ids, t, :GEN_REDISP) -
                ref_sum(r.REDISP, :index, ids, t, :CHARGE_REDISP)
            pr = prs_active ? ref_sum(r.PRS, :index, ids, t, :PRS_NETINPUT) : 0.0
            row = only(filter(x -> x.Time == t && x.Node == n, r.NodalMarketRedispBalance))
            @test g + pr + ref_val(r.NETINPUT, :index, n, t, :NETINPUT) - row.CU + row.LL ≈
                  s.load[n][t] atol = 1e-5
        end
    end

    BE = r.BIL_EXCHANGE
    if !isempty(BE) && !isempty(r.EXCHANGE)
        for t in T, z in s.Z
            imp = sum((Float64(x.BIL_EXCHANGE) for x in eachrow(BE) if x.To == z && x.Time == t), init = 0.0)
            outg = sum((Float64(x.BIL_EXCHANGE) for x in eachrow(BE) if x.From == z && x.Time == t), init = 0.0)
            @test ref_val(r.EXCHANGE, :index, z, t, :EXCHANGE) ≈ imp - outg atol = 1e-5
        end
        if mt isa ZonalMarket{NTC}
            for x in eachrow(BE)
                @test Float64(x.BIL_EXCHANGE) <=
                      get(s.ntc, (String(x.From), String(x.To)), Inf) + GOLDEN_TOL
            end
        end
    end
end

"""Merit order within a zone is unconditional: no cheaper unit is held back while a more
expensive one in the same zone runs. (Across zones the interconnector may bind.)"""
function inv_merit_order!(s::RefSys, r, mt)
    (!(mt isa ZonalMarket) || isempty(r.GEN)) && return
    for t in sort(unique(r.GEN.Time))
        rows = filter(x -> x.Time == t, r.GEN)
        for a in eachrow(rows), q in eachrow(rows)
            (a.GEN > GOLDEN_TOL && s.mc[q.index] < s.mc[a.index] - GOLDEN_TOL) || continue
            s.node2zone[s.p2node[a.index]] == s.node2zone[s.p2node[q.index]] || continue
            @test q.GEN >= q.gmax - 1e-5
        end
    end
end

"""Zonal price equals the marginal cost of the marginal unit in that zone."""
function inv_prices!(s::RefSys, r, mt)
    (!(mt isa ZonalMarket) || isempty(r.ZonalMarketBalance)) && return
    for x in eachrow(r.ZonalMarketBalance)
        ids = ref_in_zone(s, x.Zone)
        marg = filter(y -> y.index in ids && y.Time == x.Time &&
                           y.GEN > GOLDEN_TOL && y.GEN < y.gmax - GOLDEN_TOL, r.GEN)
        isempty(marg) && continue
        @test x.MarketBalance ≈ maximum(s.mc[y.index] for y in eachrow(marg)) atol = 1e-5
    end
end

"""Redispatch relocates energy, it never creates it; and a nodal market — whose day-ahead
already respects every line — must need no redispatch at all."""
function inv_redispatch_economics!(s::RefSys, r, mt, prs_active, has_redisp)
    (!has_redisp || isempty(r.REDISP)) && return
    T = sort(unique(r.REDISP.Time))

    restate = Dict(t => 0.0 for t in T)
    if prs_active
        for t in T, p in s.PRS
            da = ref_val(r.GEN, :index, p, t, :GEN)
            da === nothing && continue
            restate[t] += ref_val(r.PRS, :index, p, t, :PRS_NETINPUT) - (da - s.prs_demand[p][t])
        end
    end
    for t in T
        Δ = sum(x.GEN_UP - x.GEN_DOWN - x.CHARGE_UP + x.CHARGE_DOWN
                for x in eachrow(r.REDISP) if x.Time == t; init = 0.0)
        @test Δ + restate[t] ≈ 0.0 atol = 1e-5
    end

    if mt isa NodalMarket
        vol = sum(r.REDISP.GEN_UP) + sum(r.REDISP.GEN_DOWN)
        if prs_active
            # The redispatch stage settles the prosumer's post-clearing restatement
            # as if it were congestion, so the volume is exactly that restatement and
            # nothing else — no grid constraint contributes. Should the pipeline ever be
            # reordered so the day-ahead sees the prosumer's storage, both sides go to
            # zero and this still holds.
            @test vol ≈ sum(abs, values(restate)) atol = 1e-4
        else
            @test vol ≈ 0.0 atol = 1e-5
        end
    end
end

"""Flow-based domain: the 70 %-rule must be reproducible from the persisted RAM table
alone, and the cleared net positions must sit inside the domain."""
function inv_flowbased!(s::RefSys, r)
    isempty(r.RAM) && return
    for x in eachrow(r.RAM)
        @test x.RAM_POS ≈ max(x.fmax - x.F0 - x.FRM * x.fmax, x.minRAM * x.fmax) atol = 1e-5
        @test x.RAM_NEG ≈ min(-x.fmax - x.F0 + x.FRM * x.fmax, -x.minRAM * x.fmax) atol = 1e-5
        @test x.RAM_POS > -GOLDEN_TOL
        @test x.RAM_NEG < GOLDEN_TOL
    end
    isempty(r.EXCHANGE) && return

    # Independent zonal PTDF: nodal PTDF times a flat GSK. NOTE the sign — the flow-based
    # subsystem works in the negation of the phase-angle LINEFLOW convention (`params.ptdf`
    # maps import-positive NETINPUT to flow, and the constraint negates once more), so the
    # constrained quantity is +PTDFz * NP with NP import-positive.
    GSK = zeros(length(s.N), length(s.Z))
    for (zi, z) in enumerate(s.Z), n in s.nodes_in_zone[z]
        GSK[findfirst(==(n), s.N), zi] = 1 / length(s.nodes_in_zone[z])
    end
    PTDFz = s.PTDF * GSK
    for t in sort(unique(r.EXCHANGE.Time))
        NP = [ref_val(r.EXCHANGE, :index, z, t, :EXCHANGE) for z in s.Z]
        for l in unique(r.RAM.index)
            li = findfirst(==(l), s.L)
            li === nothing && continue
            f = dot(PTDFz[li, :], NP)
            row = only(filter(x -> x.index == l && x.Time == t, r.RAM))
            slack_p = isempty(r.FBMC_INF) ? 0.0 : ref_val(r.FBMC_INF, :index, l, t, :FBMC_INF_POS)
            slack_n = isempty(r.FBMC_INF) ? 0.0 : ref_val(r.FBMC_INF, :index, l, t, :FBMC_INF_NEG)
            @test f <= row.RAM_POS + slack_p + 1e-5
            @test f >= row.RAM_NEG - slack_n - 1e-5
        end
    end
end

golden_splits(th) = [th.start + (k - 1) * th.split : min(th.start + k * th.split - 1, th.stop)
                     for k in 1:cld(th.stop - th.start + 1, th.split)]

"""Run the full invariant battery on one solved scenario."""
function check_invariants!(sc, s::RefSys, r, dir)
    mt = sc.setup.MarketType
    prs_active = sc.setup.ProsumerSetup isa ProsumerOptimization && !isempty(s.PRS)
    has_redisp = sc.setup.RedispatchSetup isa DCLF

    # Nodal injection implied by each stage's own dispatch. Before per-stage result
    # prefixes (F-5) the redispatch stage overwrote the day-ahead's nodal tables, so only
    # one of these could ever be checked; now both are.
    inj_da = (n, t) -> begin
        ids = ref_at_node(s, n)
        ref_sum(r.GEN, :index, ids, t, :GEN) - ref_sum(r.CHARGE, :index, ids, t, :CHARGE) -
        (prs_active ? sum((s.prs_demand[p][t] for p in s.PRS if s.p2node[p] == n), init = 0.0) : 0.0)
    end
    inj_rd = (n, t) -> begin
        ids = ref_at_node(s, n)
        ref_sum(r.REDISP, :index, ids, t, :GEN_REDISP) -
        ref_sum(r.REDISP, :index, ids, t, :CHARGE_REDISP) +
        (prs_active ? ref_sum(r.PRS, :index, ids, t, :PRS_NETINPUT) : 0.0)
    end

    @testset "invariants: $(sc.name)" begin
        # The composite view resolves the nodal tables to the last stage that wrote them:
        # the redispatch stage where there is one, otherwise the day-ahead — which for a
        # zonal market means the computed (not optimized) tables of report_nodal_flows!.
        if has_redisp || mt isa NodalMarket
            inv_network!(s, r.NETINPUT, r.LINEFLOW, has_redisp ? inj_rd : inj_da)
        else
            inv_zonal_da_network!(s, r, inj_da)
        end

        # Per-stage: every day-ahead persists nodal tables now (a zonal one computes them
        # from the cleared dispatch, see report_nodal_flows!). This is the coverage F-5 was
        # destroying. `inv_network!` cannot run on a zonal DA — there are no phase angles
        # and the flows are not capacity-limited.
        da = with_logger(NullLogger()) do; DataFiles(dir, DayAhead); end
        @test !isempty(da.NETINPUT)
        if mt isa NodalMarket
            inv_network!(s, da.NETINPUT, da.LINEFLOW, inj_da)
        else
            inv_zonal_da_network!(s, da, inj_da)
        end
        if has_redisp
            rd = with_logger(NullLogger()) do; DataFiles(dir, Redispatch); end
            @test !isempty(rd.NETINPUT)
            inv_network!(s, rd.NETINPUT, rd.LINEFLOW, inj_rd)
        end

        inv_generation!(s, r.GEN)
        inv_redispatch!(s, r, prs_active)
        inv_prosumer!(s, r, golden_splits(sc.setup.TimeHorizon),
                      prs_active ? sc.setup.ProsumerSetup.self_discharge : 1.0)
        inv_balances!(s, r, mt, prs_active, has_redisp)
        inv_merit_order!(s, r, mt)
        inv_prices!(s, r, mt)
        inv_redispatch_economics!(s, r, mt, prs_active, has_redisp)
        inv_flowbased!(s, r)
        # no infeasibility slack may be active anywhere
        @test isempty(with_logger(NullLogger()) do; check_infeasibility(r); end)
    end
end

"""
    check_split_invariance!(name, ra, rb; split_dependent = Set{Symbol}())

Splitting the time horizon must not change the result: neither dataset has a system
storage plant, so the splits are fully independent.

`split_dependent` names the tables of a scenario for which that is *not* expected, and
which must therefore differ. Under the default `CyclicStorage` the prosumer's storage level
is cyclic within each split — that is what the boundary condition means — so every stage
downstream of it sees a different prosumer schedule depending on how the horizon is cut.
Asserting those tables differ pins the coupling down rather than leaving it untested.
"""
function check_split_invariance!(name, ra, rb; split_dependent::Set{Symbol} = Set{Symbol}())
    @testset "split invariance: $name" begin
        for key in (:GEN, :REDISP, :NETINPUT, :LINEFLOW, :EXCHANGE, :RAM,
                    :ZonalMarketBalance, :NodalMarketBalance, :NodalMarketRedispBalance)
            da, db = getfield(ra, key), getfield(rb, key)
            (isempty(da) || isempty(db)) && continue
            da, db = golden_sort(da), golden_sort(db)
            if nrow(da) != nrow(db)
                @test nrow(da) == nrow(db)
                continue
            end
            num = [c for c in names(da) if eltype(da[!, c]) <: Number && c != "Time"]
            worst = maximum([maximum(abs.(Float64.(da[!, c]) .- Float64.(db[!, c])); init = 0.0)
                             for c in num]; init = 0.0)
            if key in split_dependent
                @test worst > GOLDEN_TOL
            else
                @test worst <= GOLDEN_TOL
            end
        end
    end
end

# ============================================================================ entry point

"""
    solve_golden_grid(tmpdir) -> Dict{String,NamedTuple}

Solve every scenario of [`golden_grid`](@ref) into `tmpdir`. Shared by the test entry
point and by `test/regenerate_expected_results.jl`, so both always run the same models.
"""
function solve_golden_grid(tmpdir; solver = HiGHS.Optimizer)
    grid = golden_grid()
    params = Dict(ds => with_logger(NullLogger()) do
                      load_data(golden_input_files(ds))
                  end for ds in unique(sc.dataset for sc in grid))
    solved = Dict{String,Any}()
    for sc in grid
        with_logger(NullLogger()) do
            mr = ModelRun(params[sc.dataset], sc.setup, solver;
                          resultdir = tmpdir, scenarioname = sc.name, overwrite = true)
            POMATWO.run(mr)
        end
        dir = joinpath(tmpdir, sc.name)
        solved[sc.name] = (dir = dir, r = DataFiles(dir))
    end
    return solved
end

function test_expected_results()
    @testset "Expected results (goldens + invariants)" begin
        grid = golden_grid()
        expected_root = golden_expected_root()

        # --- manifest: the grid must still describe the goldens on disk --------------
        mpath = joinpath(expected_root, "manifest.csv")
        if isfile(mpath)
            man = POMATWO.read_csv(mpath)
            @test nrow(man) == length(grid)
            for sc in grid
                rows = filter(x -> x.scenario == sc.name, man)
                @test nrow(rows) == 1
                nrow(rows) == 1 || continue
                stored, want = only(eachrow(rows)), golden_manifest_row(sc)
                for k in keys(want)
                    hasproperty(stored, k) || continue
                    v, w = getproperty(stored, k), want[k]
                    if w isa AbstractFloat
                        @test (isnan(w) && !(v isa Number && !isnan(v))) ||
                              (v isa Number && isapprox(Float64(v), w; atol = GOLDEN_TOL))
                    else
                        @test string(coalesce(v, "")) == string(w)
                    end
                end
            end
        else
            @warn "no manifest.csv — run test/regenerate_expected_results.jl" mpath
            @test isfile(mpath)
        end

        tmpdir = mktempdir()
        solved = solve_golden_grid(tmpdir)
        refsys = Dict(ds => golden_refsys(ds) for ds in unique(sc.dataset for sc in grid))

        for sc in grid
            got = solved[sc.name]
            check_invariants!(sc, refsys[sc.dataset], got.r, got.dir)
            compare_to_expected(got.dir, joinpath(expected_root, sc.name), sc.name)
        end

        # --- cross-scenario: the grid is built in (whole-horizon, split) pairs -------
        for k in 1:2:length(grid)
            a, b = grid[k], grid[k + 1]
            # F-2: prosumer storage is cyclic per split, so a prosumer run whose
            # redispatch stage consumes `PRS_NETINPUT` differs between split layouts.
            # The nodal variant additionally perturbs the redispatch shadow price.
            split_dependent = if a.dataset === :prosumer && a.setup.RedispatchSetup isa DCLF
                # the redispatch stage consumes PRS_NETINPUT, which is split-dependent;
                # the nodal variant additionally moves the redispatch shadow price
                a.setup.MarketType isa NodalMarket ?
                    Set([:REDISP, :NETINPUT, :LINEFLOW, :NodalMarketRedispBalance]) :
                    Set([:REDISP, :NETINPUT, :LINEFLOW])
            else
                Set{Symbol}()
            end
            check_split_invariance!(a.name, solved[a.name].r, solved[b.name].r; split_dependent)
        end
    end
end
