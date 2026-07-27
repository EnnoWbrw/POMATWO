# Acceptance test for the ModelComponent extension interface:
# a user-defined component participates in the energy balance of every market type
# without editing any file under src/.

"""
Toy custom component: a fixed feed-in (e.g. a must-run unit) at one node.
Injects `mw` MW into the energy balance at `node` in every timestep of the
day-ahead stage — at nodal scope directly, at zonal scope via the node's zone.
"""
struct FixedInjector <: POMATWO.ModelComponent
    node::String
    mw::Float64
end

POMATWO.label(::FixedInjector) = :fixed_injector

# no own variables needed; the node stays empty
POMATWO.build!(::FixedInjector, sr) = nothing

function POMATWO.injection(c::FixedInjector, sr, ::POMATWO.NodalScope, n, t)
    return n == c.node ? POMATWO.AffExpr(c.mw) : nothing
end

function POMATWO.injection(c::FixedInjector, sr, ::POMATWO.ZonalScope, z, t)
    return sr.modelrun.params.node2zone[c.node] == z ? POMATWO.AffExpr(c.mw) : nothing
end

function POMATWO.validate_component(c::FixedInjector, params, setup)
    errs = String[]
    c.node in params.sets.N || push!(errs, "FixedInjector: node $(c.node) not in node set")
    c.mw >= 0 || push!(errs, "FixedInjector: mw must be non-negative")
    return errs
end

"""
Toy capacity-expansion component: a candidate unit at one node with an investment
variable CAP and generation GEN[t] ≤ CAP. Objective: invest_cost * CAP + mc * ΣGEN.
Demonstrates a component with its own variables, objective, and result table.
Note: investment decisions require a single time split (TimeHorizon(split = stop)).
"""
struct CandidateUnit <: POMATWO.ModelComponent
    node::String
    invest_cost::Float64   # cost per MW of installed capacity (for the model horizon)
    mc::Float64            # marginal generation cost
end

POMATWO.label(::CandidateUnit) = :candidate

function POMATWO.build!(c::CandidateUnit, sr)
    m = sr.vars[:candidate]
    T = sr.market_state.Time
    JuMP.@variable(m, 0 <= CAP)
    JuMP.@variable(m, 0 <= GEN[t = T])
    JuMP.@constraint(m, [t = T], GEN[t] <= CAP)
    JuMP.@objective(m, Min, c.invest_cost * CAP + c.mc * sum(GEN[t] for t in T))
    return m
end

function POMATWO.injection(c::CandidateUnit, sr, ::POMATWO.NodalScope, n, t)
    return n == c.node ? sr.vars[:candidate][:GEN][t] : nothing
end

function POMATWO.injection(c::CandidateUnit, sr, ::POMATWO.ZonalScope, z, t)
    return sr.modelrun.params.node2zone[c.node] == z ? sr.vars[:candidate][:GEN][t] : nothing
end

function POMATWO.collect_results!(c::CandidateUnit, sr)
    m = sr.vars[:candidate]
    T = sr.market_state.Time
    sr.results[:CANDIDATE] = DataFrame(;
        index = fill(c.node, length(T)),
        Time = collect(T),
        GEN = [m[:GEN][t] for t in T],
        CAP = fill(m[:CAP], length(T)),
    )
    return nothing
end

function test_custom_component()
    @testset "Custom ModelComponent" begin
        solver = HiGHS.Optimizer
        params = load_data(cases["case 1"][:data_files])
        node = first(params.sets.N)
        injected_mw = 10.0

        for market in [ZonalMarket(), NodalMarket()]
            mktempdir() do tmpdir
                with_logger(NullLogger()) do
                    total_gen = Dict{String,Float64}()
                    for (name, comps) in
                        [("base", POMATWO.ModelComponent[]), ("injected", POMATWO.ModelComponent[FixedInjector(node, injected_mw)])]
                        setup = ModelSetup(
                            TimeHorizon = TimeHorizon(stop = 2),
                            MarketType = market,
                            components = comps,
                        )
                        mr = ModelRun(params, setup, solver;
                            resultdir = tmpdir, scenarioname = name, overwrite = true)
                        @test POMATWO.run(mr) === nothing
                        results = DataFiles(joinpath(tmpdir, name))
                        @test isempty(check_infeasibility(results))
                        total_gen[name] = sum(results.GEN.GEN)
                    end
                    # the injected energy displaces conventional generation
                    n_timesteps = 2
                    @test total_gen["injected"] ≈ total_gen["base"] - injected_mw * n_timesteps atol = 1e-4
                end
            end
        end

        # capacity expansion: candidate cheaper than the marginal plant gets built,
        # and the component's own result table is fetched and written
        @testset "CandidateUnit expansion" begin
            node = first(params.sets.N)
            candidate = CandidateUnit(node, 1.0, 0.0)  # near-free capacity, free energy
            setup = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 2, split = 2),  # single split: investment spans horizon
                MarketType = ZonalMarket(),
                components = POMATWO.ModelComponent[candidate],
            )
            # no mktempdir-do-block: Arrow keeps the file mmap'ed, which breaks
            # eager cleanup on Windows (same pattern as create_mock_datafiles)
            tmpdir = mktempdir()
            with_logger(NullLogger()) do
                mr = ModelRun(params, setup, solver;
                    resultdir = tmpdir, scenarioname = "capex", overwrite = true)
                @test POMATWO.run(mr) === nothing
                subdir = joinpath(tmpdir, "capex", "subrun_t1-t2")
                # result tables of user components are namespaced by their market state
                # like every other table (DayAhead_CANDIDATE.arrow)
                @test isfile(joinpath(subdir, "DayAhead_CANDIDATE.arrow"))
                cand = DataFrame(Arrow.Table(joinpath(subdir, "DayAhead_CANDIDATE.arrow")))
                @test all(isa.(cand.CAP, Real))          # values, not VariableRefs
                @test first(cand.CAP) > 1.0              # investment happened
                @test all(cand.GEN .<= cand.CAP .+ 1e-6) # capacity limit respected
            end
        end

        # validation hook: invalid component must abort the run before solving
        @testset "validate_component" begin
            setup_bad = ModelSetup(
                TimeHorizon = TimeHorizon(stop = 2),
                components = POMATWO.ModelComponent[FixedInjector("no_such_node", 5.0)],
            )
            mktempdir() do tmpdir
                mr = ModelRun(params, setup_bad, solver;
                    resultdir = tmpdir, scenarioname = "bad", overwrite = true)
                @test_throws ErrorException POMATWO.run(mr)
            end
        end
    end
end
