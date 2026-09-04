using Test
using DataFrames
using Dates
using Logging
using Statistics

# Helper: minimal params for scope / shift tests
function create_refday_test_params()
    nodes = ["n1", "n2", "n3"]
    sets = POMATWO.Sets(N = nodes, Z = ["z1", "z2"])
    return POMATWO.Parameters(
        sets = sets,
        node2zone = Dict("n1" => "z1", "n2" => "z1", "n3" => "z2"),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
        nodal_load = Dict{String,POMATWO.ConcreteProfile}(
            "n1" => POMATWO.FixedProfile(3.0),
            "n2" => POMATWO.FixedProfile(6.0),
            "n3" => POMATWO.FixedProfile(5.0),
        ),
    )
end

# Helper: hand-built nodal data (3 nodes, 2 zones, 2 times) for shift tests
function create_refday_test_nd()
    return (
        nodes = ["n1", "n2", "n3"],
        times = [1, 2],
        RES  = Dict(("n1",1)=>4.0, ("n2",1)=>1.0, ("n3",1)=>8.0,
                    ("n1",2)=>6.0, ("n2",2)=>2.0, ("n3",2)=>5.0),
        CONV = Dict(("n1",1)=>8.0, ("n2",1)=>2.0, ("n3",1)=>15.0),
        # no storage dispatch on the reference day → the :sto lever's bounds are the
        # full installed power (they are incremental to STO, see _comp_bounds).
        STO  = Dict{Tuple{String,Int},Float64}(),
        # conv/RES caps are per-(node, time) (availability-weighted in the real
        # precompute_nodal); constant over time here so time-agnostic assertions hold.
        gmax_conv = Dict(("n1",1)=>20.0, ("n2",1)=>10.0, ("n3",1)=>30.0,
                         ("n1",2)=>20.0, ("n2",2)=>10.0, ("n3",2)=>30.0),
        gmax_res  = Dict(("n1",1)=>10.0, ("n2",1)=>5.0,  ("n3",1)=>12.0,
                         ("n1",2)=>10.0, ("n2",2)=>5.0,  ("n3",2)=>12.0),
        # storage inert here (zero power) → :sto bounds (0,0), cascade unchanged.
        gmax_sto_dis = Dict("n1"=>0.0, "n2"=>0.0, "n3"=>0.0),
        gmax_sto_chg = Dict("n1"=>0.0, "n2"=>0.0, "n3"=>0.0),
        P    = Dict(("n1",1)=>10.0, ("n2",1)=>-5.0, ("n3",1)=>20.0,
                    ("n1",2)=>14.0, ("n2",2)=>0.0,  ("n3",2)=>15.0),
        LOAD = Dict(("n1",1)=>3.0, ("n2",1)=>6.0, ("n3",1)=>5.0,
                    ("n1",2)=>3.0, ("n2",2)=>6.0, ("n3",2)=>5.0),
        load_max = Dict("n1"=>3.0, "n2"=>6.0, "n3"=>5.0),
        load_min = Dict("n1"=>3.0, "n2"=>6.0, "n3"=>5.0),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
    )
end

# Helper: an all-zero nodal fixture (no conv/RES/storage headroom anywhere) whose only
# lever is load — used to pin the load cap of F4 and the REFDAY_DIAG numbers of F6.
# z1 = [n1,n2] has a −8 gap at t2, z2 = [n3] a +3 gap, every node carries 10 MW load.
function create_refday_load_nd()
    nodes = ["n1", "n2", "n3"]; times = [1, 2]
    z0() = Dict((n, t) => 0.0 for n in nodes, t in times)
    return (
        nodes = nodes, times = times,
        RES = z0(), CONV = z0(), STO = z0(), gmax_conv = z0(), gmax_res = z0(),
        gmax_sto_dis = Dict(n => 0.0 for n in nodes),
        gmax_sto_chg = Dict(n => 0.0 for n in nodes),
        P = Dict(("n1",1)=>0.0, ("n2",1)=>0.0, ("n3",1)=>0.0,
                 ("n1",2)=>-4.0, ("n2",2)=>-4.0, ("n3",2)=>3.0),
        LOAD = Dict((n, t) => 10.0 for n in nodes, t in times),
        load_max = Dict(n => 10.0 for n in nodes),
        load_min = Dict(n => 10.0 for n in nodes),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
    )
end

# Helper: a fixture whose LOAD *and* RES differ between the reference hour (t=1) and
# the target hour (t=2) — the two other fixtures hold load constant over time, which
# makes a load pre-step a silent no-op. `P(n,1) = RES + CONV − LOAD` (export-positive),
# so the reference seed is internally consistent; `P(n,2)` is a free target used only
# for the net-position gap. gmax_conv equals CONV, so the conventional lever has no
# room UP — a γ test can then attribute everything it sees to the load lever.
function create_refday_prestep_nd()
    nodes = ["n1", "n2", "n3"]; times = [1, 2]
    return (
        nodes = nodes, times = times,
        RES  = Dict(("n1",1)=>4.0, ("n2",1)=>1.0, ("n3",1)=>8.0,
                    ("n1",2)=>6.0, ("n2",2)=>2.0, ("n3",2)=>5.0),
        CONV = Dict(("n1",1)=>8.0, ("n2",1)=>2.0, ("n3",1)=>15.0,
                    ("n1",2)=>8.0, ("n2",2)=>2.0, ("n3",2)=>15.0),
        STO  = Dict{Tuple{String,Int},Float64}(),
        gmax_conv = Dict(("n1",1)=>8.0, ("n2",1)=>2.0, ("n3",1)=>15.0,
                         ("n1",2)=>8.0, ("n2",2)=>2.0, ("n3",2)=>15.0),
        gmax_res  = Dict(("n1",1)=>4.0, ("n2",1)=>1.0, ("n3",1)=>8.0,
                         ("n1",2)=>6.0, ("n2",2)=>2.0, ("n3",2)=>8.0),
        gmax_sto_dis = Dict(n => 0.0 for n in nodes),
        gmax_sto_chg = Dict(n => 0.0 for n in nodes),
        P    = Dict(("n1",1)=>8.0,  ("n2",1)=>-3.0, ("n3",1)=>18.0,
                    ("n1",2)=>20.0, ("n2",2)=>-10.0, ("n3",2)=>18.0),
        LOAD = Dict(("n1",1)=>4.0, ("n2",1)=>6.0, ("n3",1)=>5.0,
                    ("n1",2)=>7.0, ("n2",2)=>3.0, ("n3",2)=>5.0),
        load_max = Dict("n1"=>7.0, "n2"=>6.0, "n3"=>5.0),
        load_min = Dict("n1"=>4.0, "n2"=>3.0, "n3"=>5.0),
        nodes_in_zone = Dict("z1" => ["n1", "n2"], "z2" => ["n3"]),
    )
end

# Helper: lever state seeded from `nd` at a single reference hour. γ = 1.0 keeps the
# load lever's UPWARD bound at the reference load, i.e. the pre-F4 behaviour, so tests
# about the cascade itself are not entangled with the load cap (which F4's own tests pin).
refday_levers(nd, t_ref; γ = 1.0) =
    POMATWO.ShiftLevers(nd, Dict(n => t_ref for n in nd.nodes), γ)

# Helper: toy matchable generation frame (cluster_size = 1 → clusters 1..3)
# z1 (n1) profile [5,1,5]: cluster 3 ≡ cluster 1. z2 (n3) [2,7,7]: cluster 3 ≡ cluster 2.
function create_refday_test_genframe()
    toy = DataFrame(
        Time = [1,2,3, 1,2,3],
        GEN  = [5.0,1.0,5.0, 2.0,7.0,7.0],
        index = ["p1","p1","p1","p3","p3","p3"],
        node = ["n1","n1","n1","n3","n3","n3"],
        plant_type = fill("onwind", 6),
    )
    toy[!, :Cluster] = toy.Time
    toy[!, :IsWeekend] = fill(false, 6)
    return toy
end

function test_refday_basecase()
    params = create_refday_test_params()
    nd = create_refday_test_nd()
    NP_tgt(z) = sum(nd.P[(n, 2)] for n in nd.nodes_in_zone[z])

    check_np(p_new) = all(
        isapprox(sum(p_new[n] for n in znodes), NP_tgt(z); atol = 1e-6)
        for (z, znodes) in nd.nodes_in_zone
    )

    @testset "FlowBased config + basecase method selection" begin
        fb0 = FlowBased()
        fb1 = FlowBased(DispOnlyGSK())
        @test fb0.basecase isa OptimizationBasecase
        @test fb1.GSKStrategy isa DispOnlyGSK && fb1.basecase isa OptimizationBasecase

        rd = ReferenceDayBasecase(
            source = "results/forecast",
            matching = MatchingConfig(lookback = 4, scope = ZonalMatchScope()),
            shift = ShareShift(β_conv = 0.5, β_load = 0.5, prestep = :res),
        )
        fb2 = FlowBased(GSKStrategy = DispOnlyGSK(), basecase = rd)
        @test fb2.basecase isa ReferenceDayBasecase
        @test fb2.basecase.source_type == ""   # default: regular market result tables
        @test fb2.basecase.matching.scope isa ZonalMatchScope

        mk(fb; kw...) = ModelSetup(TimeHorizon = TimeHorizon(stop = 24),
                                   MarketType = ZonalMarket(fb); kw...)
        @test state_sequence(mk(fb1)) == [TwoDayAhead, DayAhead]
        @test state_sequence(mk(fb2)) == [DayAhead]
        @test state_sequence(mk(fb1; RedispatchSetup = DCLF())) == [TwoDayAhead, DayAhead, Redispatch]
        @test state_sequence(mk(fb2; RedispatchSetup = DCLF())) == [DayAhead, Redispatch]
        # non-FBMC sequences untouched
        @test state_sequence(ModelSetup(TimeHorizon = TimeHorizon(stop = 24))) == [DayAhead]
    end

    @testset "source_type -> RefdaySourceState mapping" begin
        @test POMATWO._source_state("")       isa POMATWO.DayAheadSource
        @test POMATWO._source_state("DA")     isa POMATWO.DayAheadSource
        @test POMATWO._source_state("2DA")    isa POMATWO.TwoDayAheadSource
        @test POMATWO._source_state("REDISP") isa POMATWO.RedispatchSource
        @test_throws ErrorException POMATWO._source_state("bogus")
        # table prefix DataFiles needs per state. Each stage now writes under its own
        # namespace, so DayAhead and Redispatch are no longer both "" (which used to work
        # only because the redispatch stage overwrote the day-ahead's files).
        @test POMATWO._datafiles_type(POMATWO.TwoDayAheadSource()) == "TwoDayAhead"
        @test POMATWO._datafiles_type(POMATWO.DayAheadSource())    == "DayAhead"
        @test POMATWO._datafiles_type(POMATWO.RedispatchSource())  == "Redispatch"
    end

    @testset "redist keys evaluate at the hour their meaning calls for" begin
        # Every key sees the target hour (2 here) AND the per-node reference map.
        # Reference-day-texture keys must read the REFERENCE hour (1), target-day keys
        # the target hour — reading the target hour for RefProp/time-dependent GSK was
        # the bug F1 fixes.
        ref1 = Dict("n1" => 1, "n2" => 1)

        # GenLoadGSK: gen = P + load, weight |gen| + |load|, at the REFERENCE hour
        # n1: P=10, load=3 → |13|+|3| = 16 ; n2: P=-5, load=6 → |1|+|6| = 7
        # (the target hour would give 20 / 12 — the wrong day's texture)
        @test POMATWO._key_weights(GSKRedist(GenLoadGSK()), nd, params, ["n1","n2"], 2, ref1) ==
              Dict("n1" => 16.0, "n2" => 7.0)

        # RefProp is PER-LEVER: each component is weighted by the reference day's own
        # texture of that component, read at the node's REFERENCE hour.
        refw(c, rmap = ref1, d = nd) =
            POMATWO._key_weights(RefPropRedist(), d, params, ["n1","n2"], 2, rmap; comp = c)
        @test refw(:RES)  == Dict("n1" => 4.0, "n2" => 1.0)   # nd.RES  at t=1
        @test refw(:conv) == Dict("n1" => 8.0, "n2" => 2.0)   # nd.CONV at t=1
        @test refw(:load) == Dict("n1" => 3.0, "n2" => 6.0)   # nd.LOAD at t=1
        # the levers really disagree — this is what the per-component key buys
        @test refw(:RES) != refw(:conv) != refw(:load)
        # a patchwork reference map is honoured node by node: n1 reads RES at t=2
        @test refw(:RES, Dict("n1" => 2, "n2" => 1)) == Dict("n1" => 6.0, "n2" => 1.0)

        # :sto weights by INSTALLED power (discharge + charge), not by a reference-day
        # quantity — ref-day storage is idle often enough that a ref-day key would
        # collapse to the flat fallback exactly when the :sto lever is reached.
        nd_sto_w = merge(nd, (gmax_sto_dis = Dict("n1"=>2.0, "n2"=>0.0, "n3"=>0.0),
                              gmax_sto_chg = Dict("n1"=>3.0, "n2"=>1.0, "n3"=>0.0)))
        @test refw(:sto, ref1, nd_sto_w) == Dict("n1" => 5.0, "n2" => 1.0)
        # nd itself has no storage power → zero sum → flat fallback (in _redist_weights)
        @test POMATWO._redist_weights(RefPropRedist(), nd, params, ["n1","n2"], 2, ref1;
                                      comp = :sto) == Dict("n1" => 1.0, "n2" => 1.0)

        # without a lever RefProp has no meaning and says so instead of guessing
        @test_throws ErrorException POMATWO._key_weights(RefPropRedist(), nd, params,
                                                         ["n1","n2"], 2, ref1)
        @test_throws ErrorException refw(:bogus)

        # LoadProp is a TARGET-day key: the delivery day's nodal load forecast
        ndL = merge(nd, (LOAD = Dict(("n1",1)=>3.0,  ("n2",1)=>6.0,  ("n3",1)=>5.0,
                                     ("n1",2)=>30.0, ("n2",2)=>60.0, ("n3",2)=>50.0),))
        @test POMATWO._key_weights(LoadPropRedist(), ndL, params, ["n1","n2"], 2, ref1) ==
              Dict("n1" => 30.0, "n2" => 60.0)

        # static strategies keep using the (optionally cached) GSK column — time-independent
        wf = POMATWO._key_weights(GSKRedist(FlatGSK()), nd, params, ["n1","n2"], 2, ref1)
        @test wf["n1"] ≈ 0.5 && wf["n2"] ≈ 0.5

        # RandomRedist keeps seeding on the TARGET hour (reproducibility)
        @test POMATWO._key_weights(POMATWO.RandomRedist(7), nd, params, ["n1","n2"], 2, ref1) ==
              POMATWO._key_weights(POMATWO.RandomRedist(7), nd, params, ["n1","n2"], 2,
                                   Dict("n1" => 2, "n2" => 2))
    end

    @testset "RefPropRedist: each lever splits by its own reference-day texture" begin
        # One zone of two nodes, ample headroom on every lever, gap D = +4 at t=2.
        # Reference hour t=1 carries opposite textures: conv (9,3) vs load (2,6), so the
        # :conv lever must split 3/1 and the :load lever 1/3. Both nodes sit at P = 0 on
        # the reference day, so the pre-F5 |P| key would have gone flat (2/2) for both.
        nd_lev = (
            nodes = ["n1", "n2"],
            times = [1, 2],
            RES  = Dict(("n1",1)=>0.0, ("n2",1)=>0.0, ("n1",2)=>0.0, ("n2",2)=>0.0),
            CONV = Dict(("n1",1)=>9.0, ("n2",1)=>3.0, ("n1",2)=>0.0, ("n2",2)=>0.0),
            STO  = Dict{Tuple{String,Int},Float64}(),
            gmax_conv = Dict(("n1",1)=>100.0, ("n2",1)=>100.0,
                             ("n1",2)=>100.0, ("n2",2)=>100.0),
            gmax_res  = Dict(("n1",1)=>0.0, ("n2",1)=>0.0, ("n1",2)=>0.0, ("n2",2)=>0.0),
            gmax_sto_dis = Dict("n1"=>0.0, "n2"=>0.0),
            gmax_sto_chg = Dict("n1"=>0.0, "n2"=>0.0),
            # target NP = 4, split 4/0 — neither lever's split copies it, so the numbers
            # below can only come from the key
            P    = Dict(("n1",1)=>0.0, ("n2",1)=>0.0, ("n1",2)=>4.0, ("n2",2)=>0.0),
            LOAD = Dict(("n1",1)=>2.0, ("n2",1)=>6.0, ("n1",2)=>2.0, ("n2",2)=>6.0),
            load_max = Dict("n1"=>2.0, "n2"=>6.0),
            load_min = Dict("n1"=>2.0, "n2"=>6.0),
            nodes_in_zone = Dict("z1" => ["n1", "n2"]),
        )
        mlev(comp) = ShareShift(β_RES = 0.0, load_shift_share = 1.0, resolution = :zonal,
                                redist = RefPropRedist(), enforce_balance = false,
                                β_conv = comp === :conv ? 1.0 : 0.0,
                                β_load = comp === :load ? 1.0 : 0.0)
        function levsplit(comp)
            tr = POMATWO.ShiftTraceCollector()
            p = POMATWO.shift_single(nd_lev, params, 2, 1, mlev(comp); trace = tr)
            df = filter(:component => ==(string(comp)), POMATWO.shift_trace_df(tr))
            return p, Dict(n => sum(df.delta[df.node .== n]; init = 0.0) for n in nd_lev.nodes)
        end

        p_conv, d_conv = levsplit(:conv)
        @test isapprox(d_conv["n1"], 3.0; atol = 1e-9)   # 4 · 9/12
        @test isapprox(d_conv["n2"], 1.0; atol = 1e-9)   # 4 · 3/12

        p_load, d_load = levsplit(:load)
        @test isapprox(d_load["n1"], 1.0; atol = 1e-9)   # 4 · 2/8
        @test isapprox(d_load["n2"], 3.0; atol = 1e-9)   # 4 · 6/8

        # same zonal net position either way — only the intra-zone split differs
        for p in (p_conv, p_load)
            @test isapprox(p["n1"] + p["n2"], 4.0; atol = 1e-9)
        end
    end

    @testset "MatchScope node partitions" begin
        gG = POMATWO.node_groups(GlobalMatchScope(), params)
        @test collect(keys(gG)) == ["ALL"] && gG["ALL"] == ["n1", "n2", "n3"]
        gZ = POMATWO.node_groups(ZonalMatchScope(), params)
        @test gZ["z1"] == ["n1", "n2"] && gZ["z2"] == ["n3"]
        gA = POMATWO.node_groups(AreaMatchScope(Dict("n1"=>"A","n2"=>"A","n3"=>"A")), params)
        @test length(gA) == 1 && gA["A"] == ["n1", "n2", "n3"]
        @test_throws ErrorException POMATWO.node_groups(AreaMatchScope(Dict("n1"=>"A")), params)
    end

    @testset "match_by_scope: independent per-zone matching" begin
        toy = create_refday_test_genframe()
        kw = (lookback = 2, keycols = [:plant_type], valuecols = [:GEN],
              value_methods = [median], weights = Dict{Symbol,Float64}(),
              exact_weekend = false)
        mz = match_by_scope(toy, ZonalMatchScope(), params; kw...)
        @test "group" in names(mz)
        r1 = only(filter(r -> r.group == "z1" && r.target_cluster == 3, mz)).matched_cluster
        r2 = only(filter(r -> r.group == "z2" && r.target_cluster == 3, mz)).matched_cluster
        @test r1 == 1   # z1's day 3 resembles day 1
        @test r2 == 2   # z2's day 3 resembles day 2
        # GlobalMatchScope reproduces plain global matching
        mg = match_by_scope(toy, GlobalMatchScope(), params; kw...)
        mc = match_by_cluster(toy; kw...)
        @test mg[:, [:target_time, :matched_time]] == mc[:, [:target_time, :matched_time]]
    end

    @testset "add_zonecol!: node -> zone column" begin
        df = DataFrame(node = ["n3", "n1", "n2"])
        POMATWO.add_zonecol!(df, params)
        @test df.zone == ["z2", "z1", "z1"]
        df2 = DataFrame(node = ["n1"])
        out = POMATWO.add_zonecol(df2, params)   # out-of-place leaves input untouched
        @test out.zone == ["z1"] && !("zone" in names(df2))
    end

    @testset "LOAD/NP match rows: tags, resolution, zero-fill" begin
        # nodal load rows: one per node × time, real node, zone from node2zone
        ln = POMATWO._load_match_rows(params, [1, 2]; nodal = true)
        @test names(ln) == string.(POMATWO._MATCH_FRAME_COLS)
        @test nrow(ln) == 6 && all(ln.plant_type .== POMATWO._LOAD_MATCH_TAG)
        @test all(ln.GEN .== 0.0) && all(ln.NP .== 0.0)
        r = only(filter(x -> x.node == "n2" && x.Time == 1, ln))
        @test r.LOAD == 6.0 && r.zone == "z1"

        # zonal load rows: one per zone × time, load summed, representative node
        lz = POMATWO._load_match_rows(params, [1]; nodal = false)
        @test nrow(lz) == 2
        z1 = only(filter(x -> x.zone == "z1", lz))
        @test z1.LOAD == 9.0 && z1.node == "n1"   # 3 + 6, min-id node
        z2 = only(filter(x -> x.zone == "z2", lz))
        @test z2.LOAD == 5.0 && z2.node == "n3"

        # NP rows from an export-positive injection baseline P
        P = Dict(("n1", 1) => 10.0, ("n2", 1) => -5.0, ("n3", 1) => 20.0)
        np = POMATWO._np_match_rows(params, P, [1])
        @test nrow(np) == 2 && all(np.plant_type .== POMATWO._NP_MATCH_TAG)
        @test all(np.GEN .== 0.0) && all(np.LOAD .== 0.0)
        @test only(filter(x -> x.zone == "z1", np)).NP == 5.0    # 10 + (-5)
        @test only(filter(x -> x.zone == "z2", np)).NP == 20.0

        # normalize zero-fills any absent value column and pins the schema
        part = DataFrame(index = ["p1"], Time = [1], plant_type = ["onwind"],
                         node = ["n1"], zone = ["z1"], GEN = [5.0])
        norm = POMATWO._normalize_match_part(part)
        @test names(norm) == string.(POMATWO._MATCH_FRAME_COLS)
        @test norm.LOAD == [0.0] && norm.NP == [0.0] && norm.GEN == [5.0]
    end

    @testset "match_valuecols: LOAD signal steers the reference day" begin
        # One node, cluster_size=1. GEN makes cluster 3 ≡ cluster 1; LOAD ≡ cluster 2.
        frame = DataFrame(
            Time       = [1, 2, 3, 1, 2, 3],
            plant_type = ["onwind","onwind","onwind",
                          POMATWO._LOAD_MATCH_TAG, POMATWO._LOAD_MATCH_TAG, POMATWO._LOAD_MATCH_TAG],
            node       = fill("n1", 6),
            GEN        = [5.0, 1.0, 5.0, 0.0, 0.0, 0.0],
            LOAD       = [0.0, 0.0, 0.0, 1.0, 9.0, 9.0],
        )
        frame[!, :Cluster]   = frame.Time
        frame[!, :IsWeekend] = fill(false, 6)
        base = (lookback = 2, keycols = [:plant_type, :node], value_methods = [median],
                weights = Dict{Symbol,Float64}(), exact_weekend = false)

        gen_only = match_by_cluster(frame; valuecols = [:GEN], base...)
        @test only(filter(r -> r.target_cluster == 3, gen_only)).matched_cluster == 1

        with_load = match_by_cluster(frame; valuecols = [:GEN, :LOAD], base...)
        @test only(filter(r -> r.target_cluster == 3, with_load)).matched_cluster == 2
    end

    @testset "match_by_cluster: weekend relax fallback keeps coverage" begin
        toy = create_refday_test_genframe()
        toy[!, :IsWeekend] = [false, false, true, false, false, true]  # cluster 3 weekend, no weekend candidate
        m = @test_logs (:warn, r"relaxing exact_weekend") match_by_cluster(
            toy; lookback = 2, keycols = [:plant_type], valuecols = [:GEN],
            value_methods = [median], weights = Dict{Symbol,Float64}(), exact_weekend = true)
        @test 3 in m.target_cluster   # weekend cluster still matched
    end

    @testset "resolve_ref_times: group map, fallback, skip" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1])
        fb = DataFrame(target_time = [3], matched_time = [2])
        refmap, skipped = POMATWO.resolve_ref_times(sm, ZonalMatchScope(), params, [3];
                                                    fallback_matches = fb)
        @test refmap[("n1", 3)] == 1 && refmap[("n2", 3)] == 1
        @test refmap[("n3", 3)] == 2          # z2 unmatched → global fallback
        @test isempty(skipped)
        _, skipped2 = POMATWO.resolve_ref_times(sm, ZonalMatchScope(), params, [3])
        @test skipped2 == [3]                 # no fallback → hour skipped
    end

    @testset "shift_single: physical closure (enforce_balance=false)" begin
        # Without the global balance pass, the physical levers close each zone's gap
        # exactly when headroom suffices (β sum to 1, no phantom :NP).
        # load_shift_share=1.0 throughout this testset: it keeps the load lever's upward
        # bound at the reference load (the pre-F4 cap) so these cascade assertions stay
        # about the cascade; the γ cap itself is pinned by its own testset below.
        for m in (
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                       resolution=:zonal, redist=RefPropRedist(), enforce_balance=false),
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                       resolution=:zonal, prestep=:res, redist=RefPropRedist(), enforce_balance=false),
            ShareShift(β_conv=0.5, β_load=0.5, β_RES=0.0, load_shift_share=1.0,
                       resolution=:zonal, redist=LoadPropRedist(), enforce_balance=false),
        )
            @test check_np(POMATWO.shift_single(nd, params, 2, 1, m))
        end

        # all physical shares 0 ⇒ leftover fraction 1-β_RES-β_conv-β_load = 1: shifts
        # nothing, p_new stays at the reference seed, and the gap is recorded as np_relax.
        mNP = ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                         resolution=:zonal, redist=RefPropRedist(), enforce_balance=false)
        trNP = POMATWO.ShiftTraceCollector()
        pNP = POMATWO.shift_single(nd, params, 2, 1, mNP; trace = trNP)
        @test all(isapprox(pNP[n], nd.P[(n, 1)]; atol = 1e-9) for n in nd.nodes)   # seed unchanged
        dfNP = POMATWO.shift_trace_df(trNP)
        @test Set(dfNP.component) == Set(["np_relax"])
        for (z, znodes) in nd.nodes_in_zone
            gap = NP_tgt(z) - sum(nd.P[(n, 1)] for n in znodes)
            @test isapprox(sum(dfNP.delta[dfNP.node .== z]; init = 0.0), gap; atol = 1e-6)
        end

        # nodal resolution reproduces the target nodal injection exactly (feasible here)
        mD = ShareShift(β_conv=0.5, β_load=0.5, load_shift_share=1.0,
                        resolution=:nodal, redist=RefPropRedist(), enforce_balance=false)
        pD = POMATWO.shift_single(nd, params, 2, 1, mD)
        @test all(isapprox(pD[n], nd.P[(n, 2)]; atol = 1e-6) for n in nd.nodes)

        # tight conv headroom: conv saturates at both nodes of z1 and the gap still
        # closes because the cascade hands the remainder to load, whose room the key
        # can reach at both nodes.
        nd_tight = merge(nd, (gmax_conv = Dict(("n1",1)=>9.0, ("n2",1)=>3.0, ("n3",1)=>16.0,
                                               ("n1",2)=>9.0, ("n2",2)=>3.0, ("n3",2)=>16.0),))
        mE = ShareShift(β_conv=1.0, β_load=0.0, load_shift_share=1.0,
                        resolution=:zonal, redist=LoadPropRedist(), enforce_balance=false)
        p_tight = POMATWO.shift_single(nd_tight, params, 2, 1, mE)
        @test all(isapprox(sum(p_tight[n] for n in znodes), NP_tgt(z); atol=1e-6)
                  for (z, znodes) in nd.nodes_in_zone)

        # per-node reference map (patchwork) — closure holds; map==scalar when constant
        mC = ShareShift(β_conv=0.5, β_load=0.5, load_shift_share=1.0,
                        resolution=:zonal, redist=LoadPropRedist(), enforce_balance=false)
        p_map = POMATWO.shift_single(nd, params, 2, Dict("n1"=>1,"n2"=>1,"n3"=>2), mC)
        @test check_np(p_map)
        p_s = POMATWO.shift_single(nd, params, 2, 1, mC)
        p_m = POMATWO.shift_single(nd, params, 2, Dict(n=>1 for n in nd.nodes), mC)
        @test all(isapprox(p_s[n], p_m[n]; atol=1e-12) for n in nd.nodes)
    end

    @testset "RES pre-step recreates the TARGET day's intra-zone shares" begin
        # z1 = [n1,n2]: reference RES (4,1) → shares 0.8/0.2; target (6,2) → 0.75/0.25.
        # The pre-step inserts the delivery day's RES FORECAST, so afterwards the
        # intra-zone distribution must be the target's, at both resolutions. The old
        # zonal branch scaled the zonal total while keeping the REFERENCE shares
        # (n1 += 2.4, n2 += 0.6) — that is what F2 fixed.
        for res in (:zonal, :nodal)
            m = ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                           resolution=res, prestep=:res, redist=RefPropRedist(),
                           enforce_balance=false)
            tr = POMATWO.ShiftTraceCollector()
            POMATWO.shift_single(nd, params, 2, 1, m; trace = tr)
            df = filter(:component => ==("RES_prestep"), POMATWO.shift_trace_df(tr))
            for n in nd.nodes
                res_new = nd.RES[(n, 1)] + sum(df.delta[df.node .== n]; init = 0.0)
                @test isapprox(res_new, nd.RES[(n, 2)]; atol = 1e-9)
            end
            # per-node hard-set ⇒ the zonal total is the target's too
            for (z, znodes) in nd.nodes_in_zone
                @test isapprox(sum(nd.RES[(n,1)] + sum(df.delta[df.node .== n]; init=0.0)
                                   for n in znodes),
                               sum(nd.RES[(n,2)] for n in znodes); atol = 1e-9)
            end
        end

        # a zone whose reference RES is zero is no longer a special case (no redist
        # fallback): the target's own nodal RES is written in directly.
        nd0 = merge(nd, (RES = Dict(("n1",1)=>0.0, ("n2",1)=>0.0, ("n3",1)=>0.0,
                                    ("n1",2)=>6.0, ("n2",2)=>2.0, ("n3",2)=>5.0),))
        m0 = ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                        resolution=:zonal, prestep=:res, redist=RefPropRedist(),
                        enforce_balance=false)
        tr0 = POMATWO.ShiftTraceCollector()
        POMATWO.shift_single(nd0, params, 2, 1, m0; trace = tr0)
        df0 = filter(:component => ==("RES_prestep"), POMATWO.shift_trace_df(tr0))
        for n in nd0.nodes
            @test isapprox(sum(df0.delta[df0.node .== n]; init = 0.0), nd0.RES[(n, 2)];
                           atol = 1e-9)
        end
    end

    @testset "prestep components: :res, :load and both" begin
        # ndP is the only fixture whose load moves between the reference and the target
        # hour, so a load pre-step is observable at all.
        ndP = create_refday_prestep_nd()
        # every β = 0 ⇒ the gap cascade shifts nothing and the whole net-position gap is
        # left as np_relax; whatever p_new differs from the seed by IS the pre-step.
        mP(pre) = ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                             resolution=:zonal, prestep=pre, redist=RefPropRedist(),
                             enforce_balance=false)
        seed(n)  = ndP.P[(n, 1)]
        dres(n)  = ndP.RES[(n, 2)] - ndP.RES[(n, 1)]     # +injection
        dload(n) = ndP.LOAD[(n, 1)] - ndP.LOAD[(n, 2)]   # load down ⇒ +injection

        # :load alone — nodal injection moves by the load forecast difference only
        trL = POMATWO.ShiftTraceCollector()
        pL = POMATWO.shift_single(ndP, params, 2, 1, mP(:load); trace = trL)
        for n in ndP.nodes
            @test isapprox(pL[n], seed(n) + dload(n); atol = 1e-9)
        end
        dfL = POMATWO.shift_trace_df(trL)
        @test "RES_prestep" ∉ dfL.component
        for n in ndP.nodes
            traced = sum(dfL.delta[(dfL.node .== n) .& (dfL.component .== "load_prestep")];
                         init = 0.0)
            @test isapprox(traced, dload(n); atol = 1e-9)
        end

        # :res alone — unchanged behaviour, and no load_prestep rows
        pR = POMATWO.shift_single(ndP, params, 2, 1, mP(:res))
        for n in ndP.nodes
            @test isapprox(pR[n], seed(n) + dres(n); atol = 1e-9)
        end

        # both, as a vector — the two hard-sets are independent and add up
        trB = POMATWO.ShiftTraceCollector()
        pB = POMATWO.shift_single(ndP, params, 2, 1, mP([:res, :load]); trace = trB)
        for n in ndP.nodes
            @test isapprox(pB[n], seed(n) + dres(n) + dload(n); atol = 1e-9)
        end
        dfB = POMATWO.shift_trace_df(trB)
        @test Set(["RES_prestep", "load_prestep"]) ⊆ Set(dfB.component)

        # a bare symbol and a one-element vector are the same configuration
        @test POMATWO.prestep_components(mP(:load)) == [:load]
        @test POMATWO.prestep_components(mP([:load])) == [:load]
        @test POMATWO.prestep_components(mP(Symbol[])) == Symbol[]
        # default: no pre-step at all
        @test POMATWO.prestep_components(ShareShift()) == Symbol[]
        pN = POMATWO.shift_single(ndP, params, 2, 1, mP(Symbol[]))
        @test all(isapprox(pN[n], seed(n); atol = 1e-9) for n in ndP.nodes)
    end

    @testset "load pre-step re-anchors the γ budget to the target day" begin
        # The pre-step is a hard-set, outside the γ budget (exactly as the RES pre-step
        # is outside β_RES). Afterwards `load0` is the TARGET hour's load, so γ caps the
        # deviation from the delivery-day forecast — not from the reference day.
        ndP = create_refday_prestep_nd()
        γ = 0.1
        m = ShareShift(β_conv=0.0, β_load=1.0, β_RES=0.0, load_shift_share=γ,
                       resolution=:nodal, prestep=:load, redist=RefPropRedist(),
                       enforce_balance=false)
        p = POMATWO.shift_single(ndP, params, 2, 1, m)

        for n in ndP.nodes
            after_prestep = ndP.P[(n, 1)] + ndP.LOAD[(n, 1)] - ndP.LOAD[(n, 2)]
            D  = ndP.P[(n, 2)] - after_prestep          # :nodal ⇒ per-node gap
            lo = -γ * ndP.load_max[n]                   # budget re-anchored: spent = 0
            hi = min(γ * ndP.load_min[n], ndP.LOAD[(n, 2)])
            @test isapprox(p[n], after_prestep + clamp(D, lo, hi); atol = 1e-9)
        end
        # n1 needs load UP and n2 load DOWN, so both bounds are exercised and the
        # not-re-anchored reading (spent = load_ref − load_tgt ≠ 0) is excluded
        @test isapprox(p["n1"], 5.0 + 0.4; atol = 1e-9)
        @test isapprox(p["n2"], 0.0 - 0.6; atol = 1e-9)
    end

    @testset "storage lever + availability-weighted cap" begin
        # z2 = [n3]: target gap 15 exceeds conv headroom (1) + load headroom (5);
        # the 9-MW remainder must be absorbed by storage. z1 = [n1,n2] has zero gap →
        # untouched. gmax_conv is (node,time)-keyed and differs across time (30 at t=1,
        # 16 at t=2) to exercise the availability cap. enforce_balance is off here to
        # isolate the physical cascade (the nd is not globally balanced).
        nd_sto = (
            nodes = ["n1", "n2", "n3"],
            times = [1, 2],
            RES  = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>0.0,
                        ("n1",2)=>0.0,("n2",2)=>0.0,("n3",2)=>0.0),
            CONV = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>15.0),
            STO  = Dict{Tuple{String,Int},Float64}(),   # storage idle on the reference day
            gmax_conv = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>30.0,
                             ("n1",2)=>0.0,("n2",2)=>0.0,("n3",2)=>16.0),
            gmax_res  = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>0.0,
                             ("n1",2)=>0.0,("n2",2)=>0.0,("n3",2)=>0.0),
            gmax_sto_dis = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>10.0),
            gmax_sto_chg = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>10.0),
            P    = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>20.0,
                        ("n1",2)=>0.0,("n2",2)=>0.0,("n3",2)=>35.0),
            LOAD = Dict(("n1",1)=>0.0,("n2",1)=>0.0,("n3",1)=>5.0,
                        ("n1",2)=>0.0,("n2",2)=>0.0,("n3",2)=>5.0),
            load_max = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>5.0),
            load_min = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>5.0),
            nodes_in_zone = Dict("z1"=>["n1","n2"], "z2"=>["n3"]),
        )

        # availability-weighted conv cap depends on t (30−15 vs 16−15); storage
        # bounds are ±installed power when the reference day left storage idle.
        lev = refday_levers(nd_sto, 1)
        @test POMATWO._comp_bounds(:conv, "n3", 1, nd_sto, lev)[2] ≈ 15.0
        @test POMATWO._comp_bounds(:conv, "n3", 2, nd_sto, lev)[2] ≈ 1.0
        @test POMATWO._comp_bounds(:sto, "n3", 2, nd_sto, lev) == (-10.0, 10.0)

        # ...but the lever is INCREMENTAL to the reference day's storage dispatch, which
        # precompute_nodal has already folded into the injection baseline P: a node
        # discharging 4 MW in the reference hour has only 6 MW of discharge headroom left
        # and 14 MW of charging room (F3).
        nd_dis = merge(nd_sto, (STO = Dict(("n3",1)=>4.0, ("n3",2)=>4.0),))
        @test POMATWO._comp_bounds(:sto, "n3", 2, nd_dis, refday_levers(nd_dis, 1)) ==
              (-14.0, 6.0)
        # saturated the other way: full discharge in the reference hour ⇒ no room up
        nd_full = merge(nd_sto, (STO = Dict(("n3",1)=>10.0, ("n3",2)=>10.0),))
        @test POMATWO._comp_bounds(:sto, "n3", 2, nd_full, refday_levers(nd_full, 1)) ==
              (-20.0, 0.0)

        m_sto = ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0, load_shift_share=1.0,
                           resolution=:zonal, redist=RefPropRedist(), enforce_balance=false)
        tr = POMATWO.ShiftTraceCollector()
        p = POMATWO.shift_single(nd_sto, params, 2, 1, m_sto; trace = tr)
        df = POMATWO.shift_trace_df(tr)

        @test isapprox(p["n3"], 35.0; atol = 1e-6)             # gap fully closed
        n3rows = filter(:node => ==("n3"), df)
        getdelta(c) = sum(n3rows.delta[n3rows.component .== c]; init = 0.0)
        @test isapprox(getdelta("conv"), 1.0; atol = 1e-6)     # conv headroom saturated
        @test isapprox(getdelta("sto"), 10.0; atol = 1e-6)     # storage saturated (±installed 10)
        @test isapprox(getdelta("load"), 4.0; atol = 1e-6)     # remainder into load
        @test !("NP" in df.component)                          # no phantom exchange lever
        @test !("np_relax" in df.component)                    # gap fully closed physically

        # storage clipped to installed power: shrink the cap below the remainder →
        # storage saturates and the unmet 5 MW is left relaxed toward reference.
        nd_cap = merge(nd_sto, (gmax_sto_dis = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>4.0),
                                gmax_sto_chg = Dict("n1"=>0.0,"n2"=>0.0,"n3"=>4.0)))
        tr2 = POMATWO.ShiftTraceCollector()
        p2 = POMATWO.shift_single(nd_cap, params, 2, 1, m_sto; trace = tr2)
        df2 = POMATWO.shift_trace_df(tr2)
        @test isapprox(sum(df2.delta[(df2.node .== "n3") .& (df2.component .== "sto")]; init=0.0), 4.0; atol = 1e-6)
        @test !("NP" in df2.component)
        # z2's unmet 5 MW recorded as np_relax (zone label in the node column)
        @test isapprox(sum(df2.delta[(df2.node .== "z2") .& (df2.component .== "np_relax")]; init=0.0), 5.0; atol = 1e-6)
        @test isapprox(p2["n3"], 30.0; atol = 1e-6)            # only the physically reachable part

        # same cascade, but the reference day already discharges 6 of the 10 MW: only
        # 4 MW of storage headroom remain, so the cascade delivers conv 1 + sto 4 +
        # load 5 (load's own cap) = 10 of the 15 MW gap and relaxes the rest (F3).
        # With the full ±10 available (STO = 0 above) storage alone covered 10.
        nd_busy = merge(nd_sto, (STO = Dict(("n3",1)=>6.0, ("n3",2)=>6.0),))
        tr3 = POMATWO.ShiftTraceCollector()
        p3 = POMATWO.shift_single(nd_busy, params, 2, 1, m_sto; trace = tr3)
        df3 = POMATWO.shift_trace_df(tr3)
        g3(c) = sum(df3.delta[(df3.node .== "n3") .& (df3.component .== c)]; init = 0.0)
        @test isapprox(g3("conv"), 1.0; atol = 1e-6)
        @test isapprox(g3("sto"), 4.0; atol = 1e-6)
        @test isapprox(g3("load"), 5.0; atol = 1e-6)
        @test isapprox(sum(df3.delta[(df3.node .== "z2") .& (df3.component .== "np_relax")];
                           init = 0.0), 5.0; atol = 1e-6)
        @test isapprox(p3["n3"], 30.0; atol = 1e-6)
    end

    @testset "global balance guarantee (enforce_balance=true)" begin
        Σp(p) = sum(values(p))
        # explicit: default is false (the balance pass is opt-in)
        mBal = ShareShift(β_conv=0.5, β_load=0.5, load_shift_share=1.0, enforce_balance=true,
                          resolution=:zonal, redist=RefPropRedist())

        # balanced target (Σ P(·,2)=0), ample headroom → zones reach target AND
        # Σ p_new ≈ 0, with no balance/np_relax corrections.
        ndB = merge(nd, (P = Dict(("n1",1)=>10.0,("n2",1)=>-4.0,("n3",1)=>-6.0,
                                  ("n1",2)=>2.0, ("n2",2)=>2.0, ("n3",2)=>-4.0),))
        trB = POMATWO.ShiftTraceCollector()
        pB  = POMATWO.shift_single(ndB, params, 2, 1, mBal; trace = trB)
        dfB = POMATWO.shift_trace_df(trB)
        @test isapprox(Σp(pB), 0.0; atol = 1e-6)
        for (z, znodes) in ndB.nodes_in_zone
            @test isapprox(sum(pB[n] for n in znodes), sum(ndB.P[(n,2)] for n in znodes); atol = 1e-6)
        end
        @test !("balance" in dfB.component) && !("np_relax" in dfB.component)

        # surplus target (Σ P(·,2)=+4) → conventional-gen cut restores balance
        ndS = merge(nd, (P = Dict(("n1",1)=>10.0,("n2",1)=>-4.0,("n3",1)=>-6.0,
                                  ("n1",2)=>2.0, ("n2",2)=>2.0, ("n3",2)=>0.0),))
        trS = POMATWO.ShiftTraceCollector()
        pS  = POMATWO.shift_single(ndS, params, 2, 1, mBal; trace = trS)
        dfS = POMATWO.shift_trace_df(trS)
        @test isapprox(Σp(pS), 0.0; atol = 1e-6)
        @test isapprox(sum(dfS.delta[dfS.component .== "balance"]; init=0.0), -4.0; atol = 1e-6)
        @test all(in(Set(["RES_prestep","load_prestep","RES","conv","load","sto","balance","np_relax"])), dfS.component)
        @test !("NP" in dfS.component)

        # deficit target (Σ P(·,2)=−4) → conventional-gen raise restores balance
        ndD = merge(nd, (P = Dict(("n1",1)=>10.0,("n2",1)=>-4.0,("n3",1)=>-6.0,
                                  ("n1",2)=>2.0, ("n2",2)=>2.0, ("n3",2)=>-8.0),))
        trD = POMATWO.ShiftTraceCollector()
        pD  = POMATWO.shift_single(ndD, params, 2, 1, mBal; trace = trD)
        dfD = POMATWO.shift_trace_df(trD)
        @test isapprox(Σp(pD), 0.0; atol = 1e-6)
        @test isapprox(sum(dfD.delta[dfD.component .== "balance"]; init=0.0), 4.0; atol = 1e-6)

        # conv exhausted → load last-resort absorbs the residual (with a warning).
        # Levers built by hand: nothing generated and nothing consumed at the reference
        # hour (load0 = 0 ⇒ no load to cut), so only the "add load" direction is open —
        # bounded by γ·load_max, which with γ = 1 is the node's peak load.
        pin = Dict("n1"=>3.0, "n2"=>0.0, "n3"=>0.0)                   # surplus R = 3
        ndZ = merge(nd, (gmax_conv = Dict((n,t)=>0.0 for n in nd.nodes, t in nd.times),))
        zero_lev(γ) = POMATWO.ShiftLevers(Dict(n => 0.0 for n in nd.nodes),
                                          Dict(n => 0.0 for n in nd.nodes),
                                          Dict(n => 0.0 for n in nd.nodes),
                                          Dict(n => 0.0 for n in nd.nodes),
                                          Dict(n => 0.0 for n in nd.nodes), γ)
        trZ = POMATWO.ShiftTraceCollector()
        @test_logs (:warn, r"insufficient") POMATWO._enforce_global_balance!(
            pin, ndZ, 2, zero_lev(1.0), trZ)
        @test isapprox(sum(values(pin)), 0.0; atol = 1e-6)

        # ...but balance is no longer unconditional: with γ so small that the load lever
        # cannot absorb the residual either, the pass warns twice and leaves Σ ≠ 0.
        pin2 = Dict("n1"=>3.0, "n2"=>0.0, "n3"=>0.0)
        trZ2 = POMATWO.ShiftTraceCollector()
        @test_logs (:warn, r"insufficient") (:warn, r"could not fully balance") POMATWO._enforce_global_balance!(
            pin2, ndZ, 2, zero_lev(0.1), trZ2)
        # γ·load_max = 0.1·(3+6+5) = 1.4 of the 3 MW surplus absorbed
        @test isapprox(sum(values(pin2)), 3.0 - 1.4; atol = 1e-6)
    end

    @testset "waterfill bounds, remainder and first-pass reallocation" begin
        w = Dict("a"=>1.0, "b"=>1.0)
        lo = Dict("a"=>0.0, "b"=>0.0); hi = Dict("a"=>3.0, "b"=>3.0)
        # first pass wants 5 per node, both clip at 3 → 2+2 reallocated (and unabsorbable)
        ap, rem, re = POMATWO._waterfill(10.0, ["a","b"], w, lo, hi)
        @test ap["a"] ≈ 3.0 && ap["b"] ≈ 3.0 && rem ≈ 4.0 && re ≈ 4.0
        # negative direction with room below — nothing clipped, nothing reallocated
        ap2, rem2, re2 = POMATWO._waterfill(-2.0, ["a","b"], w, Dict("a"=>-5.0,"b"=>-5.0), hi)
        @test ap2["a"] ≈ -1.0 && ap2["b"] ≈ -1.0 && abs(rem2) < 1e-9 && re2 == 0.0
        # lo = 0 blocks negative movement entirely → full remainder returned
        ap3, rem3, re3 = POMATWO._waterfill(-2.0, ["a","b"], w, lo, hi)
        @test ap3["a"] == 0.0 && ap3["b"] == 0.0 && rem3 ≈ -2.0 && re3 == 0.0
        # clipped but fully absorbed: "a" caps at 1, its 4 go to "b" — reallocated
        # reports the departure from the key even though nothing is left over
        ap4, rem4, re4 = POMATWO._waterfill(10.0, ["a","b"], w,
                                            Dict("a"=>0.0,"b"=>0.0), Dict("a"=>1.0,"b"=>9.0))
        @test ap4["a"] ≈ 1.0 && ap4["b"] ≈ 9.0 && abs(rem4) < 1e-9 && re4 ≈ 4.0
    end

    @testset "validate_shares errors" begin
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(β_conv = 0.9, β_load = 0.9, β_RES = 0.0))   # sum > 1
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(resolution = :bogus))
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(load_shift_share = -0.1))
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(prestep = :bogus))
        @test_throws ErrorException POMATWO.validate_shares(
            ShareShift(prestep = [:res, :bogus]))
        # valid pre-step configurations pass
        for pre in (Symbol[], :res, :load, [:res, :load])
            @test POMATWO.validate_shares(ShareShift(prestep = pre, β_conv = 0.0,
                                                     β_load = 0.0)) === nothing
        end
        # moving a component twice (hard-set, then balancer) is warned, not blocked
        @test_logs (:warn, r"prestep") POMATWO.validate_shares(
            ShareShift(prestep = :res, β_RES = 0.5, β_conv = 0.0, β_load = 0.0))
        @test_logs (:warn, r"prestep") POMATWO.validate_shares(
            ShareShift(prestep = :load, β_conv = 0.0, β_load = 0.5))
    end

    @testset "load lever bounded by load_shift_share (γ)" begin
        # Only lever with any headroom is load (no conv/RES/storage anywhere), so the
        # γ cap is directly observable. z1 = [n1,n2] needs −8 (load UP, the direction
        # that used to be unbounded), z2 = [n3] needs +3 (load down). Every node carries
        # 10 MW at every hour ⇒ |δ| ≤ γ·10 per node.
        ndL = create_refday_load_nd()
        mL(γ; bal = false) = ShareShift(β_conv=0.0, β_load=1.0, β_RES=0.0,
                                        load_shift_share=γ, resolution=:zonal,
                                        redist=LoadPropRedist(), enforce_balance=bal)
        ldelta(df, n) = sum(df.delta[(df.node .== n) .& (df.component .== "load")]; init = 0.0)
        relax(df, z) = sum(df.delta[(df.node .== z) .& (df.component .== "np_relax")]; init = 0.0)

        tr = POMATWO.ShiftTraceCollector()
        POMATWO.shift_single(ndL, params, 2, 1, mL(0.2); trace = tr)
        df = POMATWO.shift_trace_df(tr)
        @test isapprox(ldelta(df, "n1"), -2.0; atol = 1e-9)   # capped at −γ·load_max
        @test isapprox(ldelta(df, "n2"), -2.0; atol = 1e-9)
        @test isapprox(ldelta(df, "n3"),  2.0; atol = 1e-9)   # capped at +γ·load_min
        @test isapprox(relax(df, "z1"), -4.0; atol = 1e-9)    # unreachable half relaxed
        @test isapprox(relax(df, "z2"),  1.0; atol = 1e-9)

        # γ = 1 restores the pre-F4 upward cap (the reference load) and the gaps close
        tr1 = POMATWO.ShiftTraceCollector()
        POMATWO.shift_single(ndL, params, 2, 1, mL(1.0); trace = tr1)
        df1 = POMATWO.shift_trace_df(tr1)
        @test isapprox(ldelta(df1, "n1"), -4.0; atol = 1e-9)
        @test isapprox(ldelta(df1, "n3"),  3.0; atol = 1e-9)
        @test !("np_relax" in df1.component)

        # the budget is CUMULATIVE over cascade + balance pass: n3 spent its whole +2
        # in the cascade, so the balance pass (which needs +2 more injection and has no
        # conventional headroom at all — every "balance" row here is a load row) must
        # route all of it to n1/n2, which are still 4 below their cap.
        trB = POMATWO.ShiftTraceCollector()
        pB = with_logger(NullLogger()) do
            POMATWO.shift_single(ndL, params, 2, 1, mL(0.2; bal = true); trace = trB)
        end
        dfB = POMATWO.shift_trace_df(trB)
        moved(n) = sum(dfB.delta[(dfB.node .== n) .&
                                 in.(dfB.component, Ref(Set(["load", "balance"])))]; init = 0.0)
        @test isapprox(sum(values(pB)), 0.0; atol = 1e-6)     # balance still reached
        @test isapprox(moved("n3"),  2.0; atol = 1e-9)        # pinned at the cap
        @test isapprox(moved("n1"), -1.0; atol = 1e-9)
        @test isapprox(moved("n2"), -1.0; atol = 1e-9)
        for n in ndL.nodes
            @test -0.2 * ndL.load_max[n] - 1e-9 <= moved(n) <=
                  min(0.2 * ndL.load_min[n], ndL.LOAD[(n, 1)]) + 1e-9
        end
    end

    @testset "REFDAY_DIAG: apportionment diagnostics" begin
        ndL = create_refday_load_nd()
        mD(γ) = ShareShift(β_conv=0.0, β_load=1.0, β_RES=0.0, load_shift_share=γ,
                           resolution=:zonal, redist=LoadPropRedist(), enforce_balance=false)
        diagrun(γ) = begin
            d = POMATWO.ShiftDiagCollector()
            POMATWO.shift_single(ndL, params, 2, 1, mD(γ); diag = d)
            POMATWO.shift_diag_df(d)
        end

        # forced saturation (γ = 0.2): the load lever is asked for the whole gap but the
        # cap clips every node, so part of the key-proportional split is reallocated and
        # the realised share falls short of the configured one.
        dg = diagrun(0.2)
        @test names(dg) == ["Time", "zone", "component", "want", "applied",
                            "reallocated", "beta_configured", "beta_realised"]
        @test all(==(2), dg.Time)
        # one row per zone × lever (RES, conv, sto, load), every hour
        @test nrow(dg) == 2 * 4
        @test nrow(unique(dg[:, [:Time, :zone, :component]])) == nrow(dg)

        r1 = only(filter(r -> r.zone == "z1" && r.component == "load", dg))
        @test isapprox(r1.want, -8.0; atol = 1e-9)
        @test isapprox(r1.applied, -4.0; atol = 1e-9)
        @test isapprox(r1.reallocated, 4.0; atol = 1e-9)   # 2 clipped off each node
        @test r1.beta_configured == 1.0
        @test isapprox(r1.beta_realised, 0.5; atol = 1e-9) # < configured: lever saturated
        @test r1.beta_realised < r1.beta_configured

        r2 = only(filter(r -> r.zone == "z2" && r.component == "load", dg))
        @test isapprox(r2.applied, 2.0; atol = 1e-9) && isapprox(r2.reallocated, 1.0; atol = 1e-9)
        @test isapprox(r2.beta_realised, 2 / 3; atol = 1e-9)

        # levers that never receive anything are reported with a zero want and a zero
        # configured share (:sto is fallback-only)
        rs = only(filter(r -> r.zone == "z1" && r.component == "sto", dg))
        @test rs.want == 0.0 && rs.applied == 0.0 && rs.beta_configured == 0.0

        # unconstrained (γ = 1): nothing clipped, realised share == configured share
        dg1 = diagrun(1.0)
        for z in ("z1", "z2")
            r = only(filter(x -> x.zone == z && x.component == "load", dg1))
            @test r.reallocated == 0.0
            @test isapprox(r.beta_realised, r.beta_configured; atol = 1e-9)
        end
    end

    @testset "shift_single trace: deltas complete and valid" begin
        # enforce_balance off → isolate the physical cascade + np_relax bookkeeping.
        valid_comps = Set(["RES_prestep", "load_prestep", "RES", "conv", "load", "sto", "balance",
                           "np_relax"])
        for m in (
            ShareShift(β_conv=1.0, β_load=0.0, β_RES=0.0,
                       resolution=:zonal, redist=RefPropRedist(), enforce_balance=false),
            ShareShift(β_conv=0.5, β_load=0.5, β_RES=0.0,
                       resolution=:zonal, prestep=:res, redist=LoadPropRedist(), enforce_balance=false),
            ShareShift(β_conv=0.5, β_load=0.5, resolution=:nodal,
                       prestep=:res, redist=RefPropRedist(), enforce_balance=false),
            ShareShift(β_conv=0.0, β_load=0.0, β_RES=0.0,
                       resolution=:zonal, redist=RefPropRedist(), enforce_balance=false),
        )
            tr = POMATWO.ShiftTraceCollector()
            p = POMATWO.shift_single(nd, params, 2, 1, m; trace = tr)
            df = POMATWO.shift_trace_df(tr)

            @test all(abs.(df.delta) .> POMATWO.SHIFT_TRACE_TOL)
            @test all(in(valid_comps), df.component)
            @test all(==(2), df.Time)
            # prestep rows appear iff the pre-step is active
            @test ("RES_prestep" in df.component) == (:res in POMATWO.prestep_components(m))
            @test !("NP" in df.component)             # no phantom exchange lever

            # deltas are complete: p_new = P_ref + Σ nodal deltas (np_relax excluded)
            nodal = filter(:component => !=("np_relax"), df)
            for n in nd.nodes
                d = sum(nodal.delta[nodal.node .== n]; init = 0.0)
                @test isapprox(p[n], nd.P[(n, 1)] + d; atol = 1e-6)
            end
            # per-zone: realized nodal shift + relaxation = full net-position gap.
            # np_relax is keyed by the label of the resolution's "zone": the zone id
            # under :zonal, the node id under :nodal (where every node is its own zone).
            relax = filter(:component => ==("np_relax"), df)
            for (z, znodes) in nd.nodes_in_zone
                labels = Set(m.resolution == :nodal ? znodes : [z])
                dz = sum(nodal.delta[in.(nodal.node, Ref(Set(znodes)))]; init = 0.0)
                rz = sum(relax.delta[in.(relax.node, Ref(labels))]; init = 0.0)
                gap = NP_tgt(z) - sum(nd.P[(n, 1)] for n in znodes)
                @test isapprox(dz + rz, gap; atol = 1e-6)
            end

            # tracing does not change the result
            p_plain = POMATWO.shift_single(nd, params, 2, 1, m)
            @test all(isapprox(p[n], p_plain[n]; atol = 1e-12) for n in nd.nodes)
        end
    end

    @testset "resolve_group_times: fallback flags and skip" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1])
        fb = DataFrame(target_time = [3], matched_time = [2])
        gm, skipped = POMATWO.resolve_group_times(sm, ZonalMatchScope(), params, [3];
                                                  fallback_matches = fb)
        @test isempty(skipped)
        rz1 = only(filter(:group => ==("z1"), gm))
        rz2 = only(filter(:group => ==("z2"), gm))
        @test rz1.matched_time == 1 && rz1.fallback == false
        @test rz2.matched_time == 2 && rz2.fallback == true   # z2 borrowed the global fallback
        # skipped hour contributes no rows at all
        gm2, skipped2 = @test_logs (:warn, r"unresolved") POMATWO.resolve_group_times(
            sm, ZonalMatchScope(), params, [3])
        @test skipped2 == [3] && isempty(gm2)
    end

    @testset "_refday_match_trace: metadata join" begin
        sm = DataFrame(group = ["z1"], target_time = [3], matched_time = [1],
                       target_cluster = [3], matched_cluster = [1], cluster_distance = [0.5])
        fb = DataFrame(target_time = [3], matched_time = [2],
                       target_cluster = [3], matched_cluster = [2], cluster_distance = [1.5])
        gm, _ = POMATWO.resolve_group_times(sm, ZonalMatchScope(), params, [3];
                                            fallback_matches = fb)
        mt = POMATWO._refday_match_trace(gm, sm, fb)
        @test nrow(mt) == 2
        rz1 = only(filter(:group => ==("z1"), mt))
        rz2 = only(filter(:group => ==("z2"), mt))
        @test rz1.matched_cluster == 1 && rz1.cluster_distance == 0.5
        @test rz2.matched_cluster == 2 && rz2.cluster_distance == 1.5   # metadata from fallback table
    end
end

# End-to-end: forecast run → refday run with 2 splits → trace files on disk → read-back
function test_refday_trace_e2e()
    @testset "refday trace end-to-end (write + read-back)" begin
        datapath = joinpath(@__DIR__, "..", "..", "examples", "test_data_3_nodes_v2_fbmc")
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
        solver = HiGHS.Optimizer
        params = load_data(data_files)
        tmpdir = mktempdir()  # no do-block: Arrow mmap blocks eager cleanup on Windows

        with_logger(NullLogger()) do
            # forecast run: provides the 2DA reference pool
            setup_fc = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4),
                MarketType  = ZonalMarket(FlowBased(DispOnlyGSK())),
            )
            mr_fc = ModelRun(params, setup_fc, solver;
                resultdir = tmpdir, scenarioname = "forecast", overwrite = true)
            POMATWO.run(mr_fc)

            # refday run over 2 splits (exercises per-subrun trace slicing)
            bc = ReferenceDayBasecase(
                source = joinpath(tmpdir, "forecast"), source_type = "2DA",
                matching = MatchingConfig(cluster_size = 2, lookback = 1,
                                          scope = ZonalMatchScope()),
                # enforce_balance explicit: the default is false, and the balance
                # assertions further down exercise the opt-in pass end to end.
                shift = ShareShift(β_conv = 0.5, β_load = 0.5, prestep = :res,
                                   enforce_balance = true,
                                   redist = GSKRedist(DispOnlyGSK())),
            )
            setup_rd = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4, split = 2),
                MarketType  = ZonalMarket(FlowBased(GSKStrategy = DispOnlyGSK(), basecase = bc)),
            )
            mr_rd = ModelRun(params, setup_rd, solver;
                resultdir = tmpdir, scenarioname = "refday", overwrite = true)
            POMATWO.run(mr_rd)

            scen = joinpath(tmpdir, "refday")

            # trace files: per-subrun slices + root groups table
            for sub in ("subrun_t1-t2", "subrun_t3-t4")
                @test isfile(joinpath(scen, sub, "REFDAY_MATCH.arrow"))
                @test isfile(joinpath(scen, sub, "REFDAY_SHIFT.arrow"))
                @test isfile(joinpath(scen, sub, "REFDAY_DIAG.arrow"))
                # the assembled basecase itself — what calc_fbmc_params consumed
                @test isfile(joinpath(scen, sub, "REFDAY_NETINPUT.arrow"))
                @test isfile(joinpath(scen, sub, "REFDAY_LINEFLOW.arrow"))
                # flow-based domain persisted per subrun (DayAhead stage, no prefix)
                @test isfile(joinpath(scen, sub, "DayAhead_RAM.arrow"))
            end
            @test isfile(joinpath(scen, "REFDAY_GROUPS.arrow"))

            # in-memory trace: reconstruction identity against the built basecase.
            # ACINJECTION (and :netinput_ac) are import-positive; trace deltas are
            # export-positive, hence: netinput_ac = ACINJECTION_src(ref) − Σ deltas.
            base = build_refday_basecase(bc, params)
            @test haskey(base, :trace)
            trace = base[:trace]
            src = DataFiles(joinpath(tmpdir, "forecast"); type = "2DA")
            P_src = Dict((r.index, r.Time) => r.ACINJECTION for r in eachrow(src.NETINPUT))
            reft = innerjoin(trace[:REFDAY_GROUPS], trace[:REFDAY_MATCH]; on = :group)
            refmap = Dict((r.node, r.target_time) => r.matched_time for r in eachrow(reft))
            shifts = trace[:REFDAY_SHIFT]
            for n in params.sets.N, t in 1:4
                d = sum(shifts.delta[(shifts.node .== n) .& (shifts.Time .== t)]; init = 0.0)
                @test isapprox(base[:netinput_ac][n, t], P_src[(n, refmap[(n, t)])] - d;
                               atol = 1e-6)
            end
            # basecase represents a globally balanced system (production = consumption)
            for t in 1:4
                @test isapprox(sum(base[:netinput_ac][n, t] for n in params.sets.N), 0.0; atol = 1e-6)
            end
            # no trace when disabled
            @test !haskey(build_refday_basecase(bc, params; collect_trace = false), :trace)

            # read-back through DataFiles
            out = DataFiles(scen)
            @test sort(unique(out.REFDAY_MATCH.target_time)) == [1, 2, 3, 4]
            @test nrow(unique(out.REFDAY_MATCH[:, [:group, :target_time]])) == nrow(out.REFDAY_MATCH)
            @test sort(unique(out.REFDAY_GROUPS.node)) == sort(params.sets.N)
            @test nrow(unique(out.REFDAY_GROUPS)) == nrow(out.REFDAY_GROUPS)
            @test !isempty(out.REFDAY_SHIFT)
            rt = refday_reference_times(out)
            @test nrow(rt) == length(params.sets.N) * 4

            # apportionment diagnostics: one row per (target hour, zone, lever), and
            # `applied` is exactly what the per-node REFDAY_SHIFT rows of that lever sum to
            @test !isempty(out.REFDAY_DIAG)
            @test sort(unique(out.REFDAY_DIAG.Time)) == [1, 2, 3, 4]
            @test nrow(unique(out.REFDAY_DIAG[:, [:Time, :zone, :component]])) ==
                  nrow(out.REFDAY_DIAG)
            for r in eachrow(out.REFDAY_DIAG)
                znodes = Set(params.nodes_in_zone[r.zone])
                s = out.REFDAY_SHIFT
                applied = sum(s.delta[(s.Time .== r.Time) .& (s.component .== r.component) .&
                                      in.(s.node, Ref(znodes))]; init = 0.0)
                @test isapprox(r.applied, applied; atol = 1e-6)
                @test r.reallocated >= -1e-9
            end

            # ── the exported basecase IS what the flow-based parameters were built from ──
            ni = out.REFDAY_NETINPUT
            lf = out.REFDAY_LINEFLOW
            @test !isempty(ni) && !isempty(lf)
            @test sort(unique(ni.Time)) == [1, 2, 3, 4]
            @test sort(unique(lf.Time)) == [1, 2, 3, 4]
            @test nrow(ni) == length(params.sets.N) * 4
            @test nrow(lf) == length(params.sets.L) * 4
            @test nrow(unique(ni[:, [:index, :Time]])) == nrow(ni)
            @test nrow(unique(lf[:, [:index, :Time]])) == nrow(lf)
            @test Set(ni.index) == Set(params.sets.N)
            @test Set(lf.index) == Set(params.sets.L)

            # exact equality with the in-memory artifacts, not a recomputation: the
            # persisted numbers must be the ones calc_fbmc_params was handed.
            for r in eachrow(ni)
                @test isapprox(r.ACINJECTION, base[:netinput_ac][r.index, r.Time]; atol = 1e-9)
            end
            for r in eachrow(lf)
                @test isapprox(r.LINEFLOW, base[:lineflows][r.index, r.Time]; atol = 1e-9)
            end

            # ACINJECTION_REF is the source state's injection at that node's matched
            # reference hour, so the shift reads end-to-end from this table alone:
            # ACINJECTION = ACINJECTION_REF − Σ deltas (trace is export-positive).
            for r in eachrow(ni)
                @test isapprox(r.ACINJECTION_REF, P_src[(r.index, refmap[(r.index, r.Time)])];
                               atol = 1e-6)
                s = out.REFDAY_SHIFT
                d = sum(s.delta[(s.node .== r.index) .& (s.Time .== r.Time) .&
                                (s.component .!= "np_relax")]; init = 0.0)
                @test isapprox(r.ACINJECTION, r.ACINJECTION_REF - d; atol = 1e-6)
            end

            # LINEFLOW is the import-positive PTDF image of ACINJECTION (params.ptdf maps
            # NETINPUT to LINEFLOW directly — see the sign-convention note in CLAUDE.md).
            let PTDFn = POMATWO.dict_to_matrix(params.ptdf),
                inj = Dict((r.index, r.Time) => r.ACINJECTION for r in eachrow(ni))
                for r in eachrow(lf)
                    want = sum(PTDFn[r.index, n] * inj[(n, r.Time)] for n in axes(PTDFn, 2))
                    @test isapprox(r.LINEFLOW, want; atol = 1e-6)
                end
            end

            # RAM table: one row per CNE line and timestep, covering both splits, with
            # the 70%-rule reproducible from the persisted columns alone
            @test !isempty(out.RAM)
            @test sort(unique(out.RAM.Time)) == [1, 2, 3, 4]
            @test Set(out.RAM.index) == Set(out.FBMC_INF.index)
            @test nrow(out.RAM) == length(unique(out.RAM.index)) * 4
            @test nrow(unique(out.RAM[:, [:index, :Time]])) == nrow(out.RAM)
            for r in eachrow(out.RAM)
                @test isfinite(r.RAM_POS) && isfinite(r.RAM_NEG) && isfinite(r.F0)
                @test r.fmax == params.acline_capacity[r.index]
                @test r.RAM_POS ≈ max(r.fmax - r.F0 - r.FRM * r.fmax, r.minRAM * r.fmax)
                @test r.RAM_NEG ≈ min(-r.fmax - r.F0 + r.FRM * r.fmax, -r.minRAM * r.fmax)
            end

            # non-refday results read back with empty trace tables
            fc_out = DataFiles(joinpath(tmpdir, "forecast"))
            @test isempty(fc_out.REFDAY_MATCH) && isempty(fc_out.REFDAY_GROUPS) &&
                  isempty(fc_out.REFDAY_SHIFT) && isempty(fc_out.REFDAY_DIAG) &&
                  isempty(fc_out.REFDAY_NETINPUT) && isempty(fc_out.REFDAY_LINEFLOW)
            @test isempty(@test_logs (:warn, r"no reference-day trace") refday_reference_times(fc_out))
            # ... but the RAM table is written for the OptimizationBasecase run too
            @test !isempty(fc_out.RAM)
            @test sort(unique(fc_out.RAM.Time)) == [1, 2, 3, 4]
            @test all(isfinite, fc_out.RAM.F0)

            # ── DayAhead source: the zonal DA persists its own nodal tables ───
            # (report_nodal_flows!), so the baseline is read from them. The plant-level
            # identity they must satisfy is re-derived below and asserted against the
            # persisted ACINJECTION column, which is what the shift consumes.
            bc_da = ReferenceDayBasecase(
                source = joinpath(tmpdir, "forecast"), source_type = "",
                matching = MatchingConfig(cluster_size = 2, lookback = 1,
                                          scope = ZonalMatchScope()),
                # enforce_balance explicit: default is false (see bc above)
                shift = ShareShift(β_conv = 0.5, β_load = 0.5, prestep = :res,
                                   enforce_balance = true,
                                   redist = GSKRedist(DispOnlyGSK())),
            )
            base_da = build_refday_basecase(bc_da, params)
            src_da = DataFiles(joinpath(tmpdir, "forecast"))
            # import-positive DA baseline from plant-level tables: load + charge − gen
            imp = Dict{Tuple{String,Int},Float64}()
            for n in params.sets.N, t in 1:4
                load = haskey(params.nodal_load, n) ? Float64(params.nodal_load[n][t]) : 0.0
                imp[(n, t)] = load
            end
            for r in eachrow(src_da.GEN)
                imp[(params.plant2node[r.index], Int(r.Time))] -= Float64(r.GEN)
            end
            for r in eachrow(src_da.CHARGE)
                imp[(params.plant2node[r.index], Int(r.Time))] += Float64(r.CHARGE)
            end
            # the persisted zonal-DA nodal table must be exactly that (no DC lines in this
            # dataset, so ACINJECTION == NETINPUT) — this is the baseline the shift reads
            @test !isempty(src_da.NETINPUT)
            for r in eachrow(src_da.NETINPUT)
                @test isapprox(Float64(r.ACINJECTION), imp[(String(r.index), Int(r.Time))];
                               atol = 1e-6)
                @test isapprox(Float64(r.NETINPUT), Float64(r.ACINJECTION); atol = 1e-6)
            end
            trace_da = base_da[:trace]
            reft_da = innerjoin(trace_da[:REFDAY_GROUPS], trace_da[:REFDAY_MATCH]; on = :group)
            refmap_da = Dict((r.node, r.target_time) => r.matched_time for r in eachrow(reft_da))
            shifts_da = trace_da[:REFDAY_SHIFT]
            for n in params.sets.N, t in 1:4
                d = sum(shifts_da.delta[(shifts_da.node .== n) .& (shifts_da.Time .== t)];
                        init = 0.0)
                @test isapprox(base_da[:netinput_ac][n, t],
                               imp[(n, refmap_da[(n, t)])] - d; atol = 1e-6)
            end
            # DA-source basecase is globally balanced too (enforce_balance fixes the
            # not-necessarily-zero DA injection sum)
            for t in 1:4
                @test isapprox(sum(base_da[:netinput_ac][n, t] for n in params.sets.N), 0.0; atol = 1e-6)
            end

            # ── Redispatch source ─────────────────────────────────────────────
            # forecast run has no redispatch results → explicit error
            bc_rd_bad = ReferenceDayBasecase(
                source = joinpath(tmpdir, "forecast"), source_type = "REDISP",
                matching = bc_da.matching, shift = bc_da.shift)
            @test_throws ErrorException build_refday_basecase(bc_rd_bad, params)

            # run WITH redispatch: plain NETINPUT comes from the Redispatch DCLF
            setup_rd2 = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 4),
                MarketType  = ZonalMarket(FlowBased(DispOnlyGSK())),
                RedispatchSetup = DCLF(),
            )
            mr_rd2 = ModelRun(params, setup_rd2, solver;
                resultdir = tmpdir, scenarioname = "forecast_redisp", overwrite = true)
            POMATWO.run(mr_rd2)

            bc_rd = ReferenceDayBasecase(
                source = joinpath(tmpdir, "forecast_redisp"), source_type = "REDISP",
                matching = bc_da.matching, shift = bc_da.shift)
            base_rd = build_refday_basecase(bc_rd, params)
            src_rd = DataFiles(joinpath(tmpdir, "forecast_redisp"))
            @test !isempty(src_rd.REDISP)
            P_rd = Dict((r.index, r.Time) => Float64(r.ACINJECTION)
                        for r in eachrow(src_rd.NETINPUT))
            trace_rd = base_rd[:trace]
            reft_rd = innerjoin(trace_rd[:REFDAY_GROUPS], trace_rd[:REFDAY_MATCH]; on = :group)
            refmap_rd = Dict((r.node, r.target_time) => r.matched_time for r in eachrow(reft_rd))
            shifts_rd = trace_rd[:REFDAY_SHIFT]
            for n in params.sets.N, t in 1:4
                d = sum(shifts_rd.delta[(shifts_rd.node .== n) .& (shifts_rd.Time .== t)];
                        init = 0.0)
                @test isapprox(base_rd[:netinput_ac][n, t],
                               P_rd[(n, refmap_rd[(n, t)])] - d; atol = 1e-6)
            end
            for t in 1:4
                @test isapprox(sum(base_rd[:netinput_ac][n, t] for n in params.sets.N), 0.0; atol = 1e-6)
            end
        end
    end
end
