#!/usr/bin/env julia
#
# Regenerate test/test_cases/expected_results/ — the golden result tables compared by
# `test_expected_results()` in test/test_cases/test_expected_results.jl.
#
# OPT-IN. Never run by CI. Run it after a deliberate model change, then **review the
# git diff** before committing: every changed number is a behavioural change.
#
#   julia test/regenerate_expected_results.jl
#
# HiGHS lives in [extras]/targets.test rather than [deps], so this script bootstraps a
# temporary environment when HiGHS is not already loadable (see CLAUDE.md). That costs a
# minute or two on the first run.
#
# What it writes, per scenario in `golden_grid()`:
#   expected_results/<scenario>/subrun_tX-tY/<TABLE>.arrow   result tables
#   expected_results/manifest.csv                            full setup of every scenario
#
# `params.jld2` is deliberately NOT kept: it is never compared, and `DataFiles` falls back
# to an empty `Parameters()` when it is absent.

# normpath keeps the trailing separator when it resolves a ".." — strip it so the path
# comparisons below cannot fail on that alone.
_norm(p) = rstrip(normpath(p), ('/', '\\'))
const REPO = _norm(joinpath(@__DIR__, ".."))

# The active environment is only usable if it resolves POMATWO to THIS repository. It is
# perfectly normal for the default environment to have another checkout deved (that is how
# one works on two branches at once), and silently regenerating the goldens of this repo
# from another repo's code produces a diff that looks like a behavioural change but is not.
function _resolves_to_repo()
    id = Base.identify_package("POMATWO")
    id === nothing && return false
    src = Base.locate_package(id)                      # <root>/src/POMATWO.jl
    src === nothing && return false
    found = _norm(dirname(dirname(src)))
    found == REPO && return true
    @warn "the active environment resolves POMATWO elsewhere — bootstrapping instead" found REPO
    return false
end

# Checked before loading anything: once the wrong POMATWO is in the session, activating
# another environment cannot replace it (same UUID).
function _load_deps()
    _resolves_to_repo() || return false
    try
        @eval using POMATWO, HiGHS, JuMP, DataFrames, Arrow, CSV, Logging, LinearAlgebra, Test
    catch
        return false
    end
    return true
end

if !_load_deps()
    @info "Bootstrapping a temporary environment (HiGHS is in [extras], not [deps])"
    using Pkg
    Pkg.activate(mktempdir())
    Pkg.develop(path = REPO)
    Pkg.add(["HiGHS", "JuMP", "DataFrames", "Arrow", "CSV", "JLD2"])
    @eval using POMATWO, HiGHS, JuMP, DataFrames, Arrow, CSV, Logging, LinearAlgebra, Test
    _norm(@eval pkgdir(POMATWO)) == REPO || error(
        "regenerate_expected_results.jl: POMATWO still resolves to " *
        "$(@eval pkgdir(POMATWO)) instead of $REPO — refusing to overwrite the goldens.")
end

include(joinpath(@__DIR__, "test_cases", "test_expected_results.jl"))

function regenerate()
    grid = golden_grid()
    root = golden_expected_root()
    mkpath(root)

    @info "Solving $(length(grid)) scenarios"
    tmpdir = mktempdir()
    solved = solve_golden_grid(tmpdir)

    # Drop scenario folders that are no longer in the grid, so renamed or removed
    # scenarios do not linger as dead goldens.
    live = Set(sc.name for sc in grid)
    for d in filter(isdir, readdir(root, join = true))
        basename(d) in live || (@info "removing stale golden" scenario=basename(d); rm(d; recursive = true))
    end

    total = 0
    for sc in grid
        src = solved[sc.name].dir
        dst = joinpath(root, sc.name)
        isdir(dst) && rm(dst; recursive = true)   # so removed tables do not survive
        mkpath(dst)

        n = 0
        for f in readdir(src)
            endswith(f, ".arrow") || continue     # skip params.jld2
            cp(joinpath(src, f), joinpath(dst, f))
            n += 1
        end
        for d in filter(isdir, readdir(src, join = true))
            sub = mkpath(joinpath(dst, basename(d)))
            for f in filter(x -> endswith(x, ".arrow"), readdir(d))
                cp(joinpath(d, f), joinpath(sub, f))
                n += 1
            end
        end
        total += n
        @info "wrote golden" scenario=sc.name tables=n
    end

    CSV.write(joinpath(root, "manifest.csv"), DataFrame([golden_manifest_row(sc) for sc in grid]))

    @info "Done" scenarios=length(grid) tables=total root
    println("\nReview the diff before committing:\n  git diff --stat test/test_cases/expected_results/")
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    regenerate()
end
