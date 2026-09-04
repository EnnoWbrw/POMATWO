# POMATWO.jl

Julia electricity market model (WIP, TU Berlin). Multi-step optimizer: day-ahead
zonal/nodal market clearing (merit order), then DCOPF redispatch for congestion
management, with FBMC (Flow-Based Market Coupling) support.

This file holds only what you cannot get by reading the code. Source layout, exported
names, and example data are deliberately not listed here — read `src/POMATWO.jl` and
`ls examples/` instead. Do not add an inventory back; it goes stale and gets ignored.

---

## Rules

**Never call `@objective` twice on the same OptiNode.** It REPLACES the objective, it does
not add to it. A builder with more than one cost term must accumulate into an `AffExpr` and
call `@objective` once at the end — see `add_ndisp_generators` (DayAhead) in
`src/technologies.jl`. Nothing errors when you get this wrong; the model just silently
optimizes a different objective. Guarded by `test/test_cases/test_objectives.jl`.

**Respect the penalty-cost hierarchy.** Slack must always be more expensive than any real
action, so these numbers are only meaningful relative to each other. Never change one in
isolation:

| Cost | Where | Meaning |
|---|---|---|
| 50 | `technologies.jl` DA ndisp | day-ahead curtailment |
| 150 / 500 | `DCLF` fields | redispatch activation (see below) |
| 1000 | `technologies.jl` DA ndisp | historical / min-generation slack |
| 9000 | `energy_balances.jl` | nodal+zonal `CU` / `LL` infeasibility slack |
| 10000 | `technologies.jl` storage | storage balance `INF` |
| 100000 | `technologies.jl` FBMC | FBMC RAM slack |

Redispatch costs are configurable on `DCLF`: `disp_cost` (150), `res_up_cost` (150),
`res_down_cost` (150), `sto_cost` (500). Generation redispatch is priced the same in every
direction, renewable recall included; storage is dearer because it shifts energy across
hours, not just across nodes. The rest are still literals. `DCLF` also has an
opt-in `fix_net_positions::Bool` flag (default `false`, no cost — a hard equality
constraint, not a penalty): when `true`, redispatch may only reshuffle generation within a
zone, since each zone's net position is pinned to its day-ahead cleared value.

**Edit every stage, not just one.** Dispatch keys off `SubRun{MT,PS,RD,MS}` where
`MS <: DayAhead | TwoDayAhead | Redispatch`. The same function name (`add_disp_generators`,
`add_ndisp_generators`, `add_storage`, `add_prosumer`, `injection`) has one method per
stage. Changing the day-ahead method does nothing to redispatch, and vice versa.

**Prosumers are exempt from redispatch by design.** They model aggregated household-scale
capacity, not TSO-dispatchable assets. Their day-ahead behaviour is frozen (`add_prosumer`
for `Redispatch` is a constant `@expression`), and `PRS` plants are excluded from both the
redispatch `NDISP` set and the redispatch energy balance. Do not "fix" this.

**Non-dispatchables redispatch in both directions.** `GEN_UP` recalls day-ahead curtailment
(bounded by it, so it can never exceed `avail * gmax`), `GEN_DOWN` curtails further. Wind
curtailed for economic reasons is still physically available.

**NETINPUT/ACINJECTION are IMPORT-positive.** The persisted `NETINPUT`/`ACINJECTION`
result columns (and the in-memory `:netinput_ac` basecase arrays) follow the model's
nodal-balance convention: positive = power flowing INTO the node,
`netinput = load + charge − gen` (verify: `link_balance` in `energy_balances.jl` puts
`NETINPUT` on the supply side). This is the opposite of the physical feed-in intuition
the names suggest. Consequences:
- Net positions (export-positive) require negation: `NP[z,t] = -Σ_n netinput_ac[n,t]`
  (`calc_ram`), and generation recovery is `gen = load − netinput_ac`
  (`build_gsk_timeseries`). Writing `gen = netinput_ac + load` is the historical
  sign bug — do not reintroduce it.
- The reference-day shift pipeline (`refday_basecase.jl`) works EXPORT-positive
  internally: the baseline is negated on entry (`_ac_injection_baseline`) and negated
  back on exit (`build_refday_basecase`). `REFDAY_SHIFT` trace deltas are therefore
  export-positive (positive = more feed-in), unlike the result tables:
  `netinput_ac[n,tt] = ACINJECTION_source(n, ref(n,tt)) − Σ deltas(n,tt)`.
  The assembled basecase is exported too — `REFDAY_NETINPUT` (`ACINJECTION_REF`,
  `ACINJECTION`) and `REFDAY_LINEFLOW` — and those, being result tables, are
  IMPORT-positive. So the one identity spans both conventions: a `REFDAY_SHIFT` row and a
  `REFDAY_NETINPUT` row of the same (node, hour) have opposite signs by construction.
- **`params.ptdf` is import-positive too.** It maps `NETINPUT` to `LINEFLOW` directly
  (`PTDF · NETINPUT == LINEFLOW`), i.e. the negation of the usual export-positive PTDF.
  The whole flow-based subsystem consistently works in that negated convention — the FBMC
  constraint negates once more (`-Σ PTDFz[l,z]·NP[z]` with `NP` import-positive), and `F0`
  is computed from the negated basecase flow. It is internally coherent end to end; do not
  "fix" one half. Verified: with `FRM = 0` the flow-based domain reproduces the exact nodal
  physical export limit.
- Never mix stages when checking a balance. `ReferenceDayBasecase` takes matching data and
  injection baseline from ONE MarketState selected by `source_type` (`""`/`"DA"`, `"2DA"`,
  `"REDISP"` → `RefdaySourceState` dispatch in `refday_basecase.jl`), always reading the
  `ACINJECTION` column of that state's `NETINPUT` table.

**Every DA stage writes nodal tables, zonal ones included.** A zonal DA has no nodal
variables (`add_network` routes to `add_exchange`), so `report_nodal_flows!`
(`energy_balances.jl`, hooked into the `SubRun` constructor after `link_balance`) computes
them from the cleared dispatch: `NETINPUT[n,t] = load − Σ injection(c, sr, NodalScope(), n, t)`
over every component except `NetworkComp`, then `LINEFLOW = params.ptdf · ACINJECTION`.
These are the flows BEFORE redispatch and are deliberately **not** capacity-limited — an
overload is the congestion redispatch then resolves. Do not "fix" it by adding line limits.
- It reuses the `injection` methods at `NodalScope`, but on a **fresh** component vector:
  the instances on `sr.components` have their `members` caches filled with zone keys.
- `DELTA` is 0 (no phase angles). Under `NTC` DC lines are assumed idle
  (`ACINJECTION == NETINPUT`, no `DCLINEFLOW` rows); `FlowBased` has real DC variables and
  is exact. Zonal `CU`/`LL` slacks are not nodally attributable, so with active slack a
  zone's summed net input and its `EXCHANGE` differ by them.
- Consequence for tests: the nodal invariant `inv_network!` cannot run on a zonal DA (no
  `DELTA`, limits may be violated) — `inv_zonal_da_network!` covers it instead.

**Redispatch is always nodal.** `add_network` for `MS<:Redispatch` dispatches on
`DCLF{LF}` regardless of `MarketType` (`src/technologies.jl`), so there is never an
`EXCHANGE` variable in the redispatch stage, zonal or nodal. A "zonal net position" during
redispatch is therefore a derived aggregate — `sum(NETINPUT[n,t] for n in
nodes_in_zone[z])` — not a variable of its own; that is how `fix_net_positions!`
(`energy_balances.jl`) and its day-ahead counterpart `zonal_net_position`
(`utils/df_utils.jl`) build it.

---

## Result files are namespaced per market state

Every `MarketState` writes its tables as `<StateName>_<TABLE>.arrow`
(`DayAhead_GEN.arrow`, `Redispatch_NETINPUT.arrow`, `TwoDayAhead_LINEFLOW.arrow`,
`ProsumerOptimizationState_PRS.arrow`). Before this, all stages wrote unprefixed files and
the redispatch stage silently **overwrote** the day-ahead's `NETINPUT`/`LINEFLOW`/
`DCLINEFLOW`, destroying the DA flows.

- The prefix is **derived**: `result_prefix(::Type{MS}) = string(nameof(MS))`
  (`market_definitions.jl`). Do not add a per-state table — a new state is covered
  automatically. Tables of user-defined `ModelComponent`s are namespaced too.
- Reading: `DataFiles(dir, Redispatch)` (preferred), `DataFiles(dir; type = "REDISP")`
  (legacy aliases `""`/`"DA"`/`"2DA"`/`"REDISP"` and canonical names both accepted, via
  `MARKET_STATE_ALIASES` / `market_state_type`).
- `DataFiles(dir)` is a **composite**: per table the latest stage wins
  (`Redispatch` > `ProsumerOptimizationState` > `DayAhead`), reproducing the pre-change
  single view. `TwoDayAhead` is excluded — ask for the basecase explicitly. Two pinned
  exceptions: `STO_LVL` always means the day-ahead levels, and the redispatch levels
  surface as `STO_LVL_REDISP`.
- Result directories written before this change still load: a directory with no
  stage-prefixed file is detected as a legacy layout and read under the old names.
  Detection is per directory, so `type = "2DA"` can never silently fall back to DA data.

---

## Model structure

Plasmo optigraph. Each technology builder owns one `OptiNode` (`sr.vars[:disp]`, `:ndisp`,
`:sto`, `:prosumer`, `:exchange`, `:balance`); Plasmo sums the node objectives. Nodes are
coupled only through `link_balance` in `src/energy_balances.jl`, which calls `injection(c,
sr, scope, r, t)` per component — that is the single place where a technology enters the
energy balance.

Result DataFrames are populated with unresolved JuMP `AffExpr`/`VariableRef` during model
build and only resolved to floats after solving. That is why the `df_*` schemas in
`src/utils/df_utils.jl` are typed `AffOrVarOrFloatOrInt`.

**Two rules keep that from being ruinously slow.** `JuMP.value` on a Plasmo node variable
is a round-trip into the solved optimizer, one variable at a time, and `value(::AffExpr)`
repeats it per term — so a variable that appears in many rows is re-fetched once per
occurrence.

1. `fetch_results` resolves against `primal_cache(sr)` (`src/utils/model_utils.jl`), which
   fetches every variable's primal once. Terms and summation order are untouched, so the
   numbers are identical.
2. A quantity that enters **no constraint** must not be built as a JuMP expression at all.
   `add_to_expression!` flattens, so a PTDF line flow — a dense row over the nodes, each
   `ACINJECTION[n,t]` itself a sum over that node's plants — would carry one term per
   plant, per line, per hour. Compute such reporting quantities after the solve in
   `derive_results!` (`src/energy_balances.jl`), which is called from `_run_states` between
   `fetch_results` and `write_results`. The zonal day-ahead `LINEFLOW` is one matrix
   product there; as expressions it cost ~60 s of a 672 h split's result extraction.

`ModelRun(verbose = true)` logs `build`/`solve`/`fetch`/`write` seconds per stage, which is
how to tell which of the four a slow subrun is actually spending its time in.

Stages hand data forward through a `ctx` dict (`prev_results_for_redispatch`,
`prev_results_for_fbmc` in `df_utils.jl`), not by sharing variables.

**Compatibility shim:** `JuMP.variable_ref_type(::Type{Plasmo.OptiNode}) = JuMP.VariableRef`
(needed for Plasmo 0.5.4 + JuMP 1.27+).

---

## Run tests

```powershell
julia --project="<absolute repo root>" -e "using Pkg; Pkg.test()"
```

- `--project=.` **fails** with "Project.toml of the package being tested must have a name and
  a UUID entry". Pass the absolute path, not `.`.
- Takes ~7 min. Solver and data-loading output surpressed; the useful line is the final
  `Test Summary`.
- HiGHS is in `[extras]` / `targets.test`, not `[deps]`. A standalone script doing
  `using POMATWO, HiGHS` will NOT run under `--project=<root>`. For scratch scripts, build a
  temp env: `Pkg.activate(tmp); Pkg.develop(path=root); Pkg.add(["HiGHS", "JuMP"])`.
- Adding a test file means editing `test/runtests.jl` in **two** places: the `include(...)`
  and the `test_xyz()` call.
- A test file must import what it uses itself (e.g. `using LinearAlgebra`); `runtests.jl`'s
  imports are not a contract, and `test/regenerate_expected_results.jl` includes
  `test_expected_results.jl` standalone.

## Golden results

`test/test_cases/expected_results/` holds per-scenario Arrow tables for the 20-scenario
grid in `golden_grid()` (`test/test_cases/test_expected_results.jl`), compared by
`test_expected_results()`. Regenerate with `julia test/regenerate_expected_results.jl`
(opt-in, never run by CI — it bootstraps a temp env because HiGHS is in `[extras]`), then
**review the diff**: every changed number is a behavioural change.

- The expected side is compared **file-set first, then value**, and deliberately does not
  go through `DataFiles` — that struct has no `BIL_EXCHANGE` field and three fields
  (`FEEDIN`, `NTC`, `STO_LVL_REDISP`) that no builder writes, so a loader-mediated
  comparison silently skips tables.
- Alongside the goldens is an invariant layer that rebuilds a reference system straight
  from the input CSVs (`build_refsys`) and checks DC-flow/PTDF/KVL/KCL, energy balances,
  redispatch identities, merit order, prices and the FBMC 70 %-rule. Goldens catch drift;
  invariants catch wrongness.
- No `@test_broken` anywhere: behaviour believed to be wrong is pinned by an assertion
  that states it exactly (e.g. a nodal market's redispatch volume equals the prosumer
  restatement — see F-1 in the FINDINGS block at the top of `test_expected_results.jl`),
  so a change in that behaviour fails loudly instead of passing silently.

## Plotting extension is not covered by CI

`[extensions] Plotting = ["Tyler", "GLMakie", "ColorSchemes", "Colors"]`. None of those are
in `[deps]`, `targets.test` or `docs/Project.toml`, so **neither `Pkg.test()` nor the docs
build loads a single line of `ext/`**. GLMakie also needs an OpenGL context that GitHub
runners lack without an xvfb workaround, so this is deliberate, not an oversight.

Consequences:
- The docstrings in `ext/` are never processed by Documenter. `docs/src/Visualizing_*.md`
  duplicates them **by hand**; the two drift silently. Update both.
- Verification is manual, in an environment with the four weakdeps added:
  - `julia --project=examples examples/bench_plotting.jl [results_dir] [out_dir]` —
    renders every entry point to PNG and reports ms / MiB / allocations per prep step.
    Takes a results dir; the bundled test cases are 4 h and hide every scaling effect.
  - `julia test/verify_plotting_equivalence.jl [refday_results_dir]` — opt-in oracle
    (bootstraps its own temp env, never run by CI). Re-implements the pre-refactor data
    pipeline verbatim and asserts the current helpers produce identical numbers, solving a
    subset of `golden_grid()` for its own inputs. It also carries a sign-invariant section
    (`verify_map_signs`) that is NOT old-vs-new: it pins the negation in
    `_net_injection_matrix` and `ACINJECTION == Σ_l incidence[l,n]·LINEFLOW[l,t]`, which is
    what makes a positive `LINEFLOW` mean `line_start → line_end` and therefore which way
    the map's flow arrows point. The reference-day checks need a `ReferenceDayBasecase`
    result directory, which the golden grid has none of, so they are skipped unless one is
    passed.

**When a plotting behaviour change is deliberate**, edit the frozen "old" side of
`verify_plotting_equivalence.jl` to match and mark it `# deliberate change: ...`. A bare
failure there must always mean "something moved that nobody decided to move".

Two traps that oracle exists to catch — both produced entirely plausible-looking figures:
- `_dispatch_data` aggregates **per contribution, then routes that contribution's total by
  sign**. Routing each row breaks `Net injection` (a zone's importing and exporting nodes
  must cancel); summing across contributions first breaks `GEN` vs `CU` (same plant type,
  opposite sides of the stack).
- `CU` is stacked **upward** as a pale cap pinned last (`_TOP_SERIES`), not as a downward
  bar. `GEN` is already post-curtailment (`FEEDIN = avail*gmax − CU`), so the cap is the
  gap to full potential and is in no energy balance.

## Test data

Registered in `test/test_cases/cases.jl`, files under `test/test_cases/data/`.

- **case 1 / case 2** — `test_data_3_nodes_prosumer` (without / with prosumer). Trap: `wind`
  is `dispatchable=1` in this data, so `NDISP` is empty in case 1 and prosumer-only in
  case 2. **This data does not exercise non-dispatchable logic at all** — that is how the
  one-directional-curtailment bug survived so long.
- **`test_data_3_nodes_v2_fbmc`** — two zones (Z1={n1}, Z2={n2,n3}), genuinely
  non-dispatchable solar/wind, non-uniform susceptance (b = 1/2/1, so the PTDF algebra is
  actually exercised) and the reference-format `slack` column (activates
  `SlackZoneBalance`). `ntc.csv` is set to 55 deliberately: the physical export limit on
  `l2` is 60 MW in t1–t3 but 50 MW in t4, so the zonal NTC market is congested in exactly
  one hour and redispatches 10 MWh there and nothing elsewhere. Changing that number
  changes what the redispatch path covers. No storage plant and no curtailment in any hour.
- **case 3** — `test_data_3_nodes_res_recall`, purpose-built for bidirectional
  non-dispatchable redispatch. A binding NTC forces day-ahead wind curtailment, and the
  congested line can only be relieved by recalling that wind. See the comment in `cases.jl`
  for the PTDF derivation.

## Build docs

```powershell
julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()"
julia --project=docs docs/make.jl
```

## graphify (optional, local-only)

**This whole section applies only if the `graphify` CLI is installed AND `graphify-out/graph.json`
exists locally.** `graphify-out/` is gitignored and never shipped with the repo, so a fresh clone
has neither. If either is missing, ignore this section entirely and use normal file reading and
search — do not install anything, and do not tell the user to.

When both are present, graphify-out/ holds a knowledge graph of this repo with god nodes,
community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"`. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
