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
| 150 | `DCLF` fields | redispatch activation (see below) |
| 1000 | `technologies.jl` DA ndisp | historical / min-generation slack |
| 9000 | `energy_balances.jl` | nodal+zonal `CU` / `LL` infeasibility slack |
| 10000 | `technologies.jl` storage | storage balance `INF` |
| 100000 | `technologies.jl` FBMC | FBMC RAM slack |

Redispatch costs are configurable on `DCLF`: `disp_cost` (150), `res_up_cost` (1),
`res_down_cost` (150), `sto_cost` (150). The rest are still literals.

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
- Two result-table quirks compound the confusion: a zonal DA stage writes NO nodal
  tables (a basecase run has only `2DANETINPUT.arrow`; `DataFiles` falls back to the
  `2DA` prefix with a warning), and in runs with redispatch the plain `NETINPUT.arrow`
  comes from the redispatch DCLF stage — never mix these with DA-stage `GEN`/`CHARGE`
  when checking balances. `ReferenceDayBasecase` takes matching data and injection
  baseline from ONE MarketState selected by `source_type` (`""`/`"DA"`, `"2DA"`,
  `"REDISP"` → `RefdaySourceState` dispatch in `refday_basecase.jl`; zonal DA sources
  get their nodal injections computed from plant-level results).

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
- Takes ~5.5 min. Solver and data-loading output is noisy; the useful line is the final
  `Test Summary`.
- HiGHS is in `[extras]` / `targets.test`, not `[deps]`. A standalone script doing
  `using POMATWO, HiGHS` will NOT run under `--project=<root>`. For scratch scripts, build a
  temp env: `Pkg.activate(tmp); Pkg.develop(path=root); Pkg.add(["HiGHS", "JuMP"])`.
- Adding a test file means editing `test/runtests.jl` in **two** places: the `include(...)`
  and the `test_xyz()` call.

## Test data

Registered in `test/test_cases/cases.jl`, files under `test/test_cases/data/`.

- **case 1 / case 2** — `test_data_3_nodes_prosumer` (without / with prosumer). Trap: `wind`
  is `dispatchable=1` in this data, so `NDISP` is empty in case 1 and prosumer-only in
  case 2. **This data does not exercise non-dispatchable logic at all** — that is how the
  one-directional-curtailment bug survived so long.
- **case 3** — `test_data_3_nodes_res_recall`, purpose-built for bidirectional
  non-dispatchable redispatch. A binding NTC forces day-ahead wind curtailment, and the
  congested line can only be relieved by recalling that wind. See the comment in `cases.jl`
  for the PTDF derivation.

## Build docs

```powershell
julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()"
julia --project=docs docs/make.jl
```
