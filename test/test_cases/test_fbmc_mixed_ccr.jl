"""
Guards the all-zone commercial term of the day-ahead flow-based constraint.

`_basecase_f0` removes the commercial term for EVERY zone (`params.sets.Z`), so the `f0` it
returns is the pure intra-zonal residual and the RAM built on it bounds the commercial flow
of every zone — flow-based and NTC alike. The constraint in
`add_exchange(sr, ::Type{FlowBased})` must therefore re-add that term over all zones:
`NP` for `FBCCR` plus `NP_ntc` for `NTCCCR`.

Bounding an `FBCCR`-only sum against that RAM instead leaves the NTC zones' contribution to
the CNE flow modelled nowhere — the domain behaves as if their net positions were zero
while the day-ahead is free to move them (they are bounded only by `ac_NTC`). Nothing
errors when the two call sites drift apart; the domain just silently stops representing the
flow it is supposed to bound. Hence the assertion is made directly on the built constraint.

Every other test dataset omits the `CCM` column, which puts all zones in `FBCCR` and makes
the two formulations identical, so this is the only place the mixed FB/NTC case is covered.
Conversely, the `FBCCR` half of the sum is what every all-FB golden scenario exercises, so
the two layers together cover both halves.
"""

function test_fbmc_mixed_ccr()
    @testset "FBMC constraint spans NTC zones too" begin
        T = 1:2
        params = load_data(golden_files_v2fbmc())

        # The dataset has no CCM column, so load_data put both zones in FBCCR. Move Z2 to
        # the NTC CCR to build the mixed case this test is about. ntc.csv defines Z1<->Z2
        # in both directions, so the `ac_NTC` caps are well defined.
        #
        # Z2 (nodes n2, n3) is the one moved rather than Z1 because n1 — Z1's only node —
        # is the slack bus, whose PTDF column is zero by construction. That makes the
        # zonal PTDF of Z1 identically zero and the NTC zone the only one with a non-zero
        # column, so the pre-change FBCCR-only constraint contained no `EX` variable at
        # all. The assertions below therefore separate the two formulations as sharply as
        # this grid allows.
        empty!(params.sets.FBCCR); append!(params.sets.FBCCR, ["Z1"])
        empty!(params.sets.NTCCCR); append!(params.sets.NTCCCR, ["Z2"])

        # Synthetic basecase, only used to produce a well-formed PTDFz/RAM. The numbers do
        # not matter for the structural assertion below; the preconditions assert what does.
        nodes = sort(collect(params.sets.N))
        lines = sort(collect(params.sets.L))
        netinput = JuMP.Containers.DenseAxisArray(
            [ 20.0 -10.0
              -5.0  15.0
             -15.0  -5.0], nodes, collect(T))
        lineflows = JuMP.Containers.DenseAxisArray(
            [10.0 5.0
              8.0 4.0
             -6.0 3.0], lines, collect(T))
        basecase = Dict(:netinput_ac => netinput, :lineflows => lineflows)

        fb = POMATWO.calc_fbmc_params(POMATWO.FlatGSK(), params, basecase, T)
        @test !isempty(params.cne)                     # something to constrain at all
        @test "Z2" in collect(axes(fb[:PTDFz], 2))     # PTDFz spans the NTC zone

        mktempdir() do tmpdir
            with_logger(NullLogger()) do
                setup = ModelSetup(
                    TimeHorizon     = TimeHorizon(stop = length(T)),
                    MarketType      = ZonalMarket(FlowBased()),
                    ProsumerSetup   = NoProsumer(),
                    RedispatchSetup = NoRedispatch(),
                )
                mr = ModelRun(params, setup, HiGHS.Optimizer;
                    resultdir = tmpdir, scenarioname = "fbmc_mixed_ccr", overwrite = true)

                # Build the day-ahead stage without solving it and read the constraint back.
                # `ctx[:fbmc_params]` is the same channel `_seed_fbmc!` and `_run_intraday`
                # use, so this is the production build path.
                ctx = Dict{Symbol,Any}(:fbmc_params => fb)
                state = POMATWO.init_state(POMATWO.DayAhead, mr, T, ctx)
                sr = POMATWO.SubRun(mr, state, ctx)

                network = sr.network
                EX = network[:EX]

                for l in params.cne, t in T
                    P_fb  = POMATWO._ptdfz(fb[:PTDFz], l, "Z1", t)   # flow-based zone
                    P_ntc = POMATWO._ptdfz(fb[:PTDFz], l, "Z2", t)   # NTC zone

                    # Precondition: without a non-zero NTC column the two formulations
                    # cannot be told apart and the test would pass vacuously.
                    @test abs(P_ntc) > 1e-6

                    func = JuMP.constraint_object(network[:FBMC_pos][l, t]).func
                    coef = JuMP.coefficient(func, EX[("Z1", "Z2"), t])

                    # NP[Z1]     = EX[(Z2,Z1)] - EX[(Z1,Z2)]      (import-positive)
                    # NP_ntc[Z2] = EX[(Z1,Z2)] - EX[(Z2,Z1)]
                    # LHS = -(P_fb*NP[Z1] + P_ntc*NP_ntc[Z2])
                    #     = (P_fb - P_ntc)*EX[(Z1,Z2)] - (P_fb - P_ntc)*EX[(Z2,Z1)]
                    @test coef ≈ P_fb - P_ntc atol = 1e-8

                    # The FBCCR-only form would leave P_fb here — zero on this grid, i.e.
                    # no EX term at all. Assert the difference explicitly so a revert fails
                    # loudly rather than shifting a number nobody checks.
                    @test !isapprox(coef, P_fb; atol = 1e-8)

                    # Mirror coefficient on the opposite direction of the same border.
                    @test JuMP.coefficient(func, EX[("Z2", "Z1"), t]) ≈ -(P_fb - P_ntc) atol = 1e-8

                    # Same term in the negative-direction constraint. JuMP normalises
                    # `RAM_neg - INF_NEG <= LHS` into a `<=` row with the LHS negated, so
                    # the coefficients come back with the opposite sign.
                    func_neg = JuMP.constraint_object(network[:FBMC_neg][l, t]).func
                    @test JuMP.coefficient(func_neg, EX[("Z1", "Z2"), t]) ≈ -(P_fb - P_ntc) atol = 1e-8
                end
            end
        end
    end
end
