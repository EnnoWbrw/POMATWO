# POMATWO Refactor Action Plan — Extensible Model Setup & Run Workflow

Goal (from repo purpose): a model that is methodologically correct, auto-detects faulty
input, is **easy to expand/maintain**, and exposes an **intuitive API** — in particular so a
user can add a **custom Plasmo `OptiNode` (component) plus its linking constraints** without
editing core files.

This document is the working plan. It is written so an AI agent can execute it in small,
token-efficient, individually-verifiable steps. Every step must keep the golden-file
regression tests in `test/test_cases/expected_results/` green (that suite is the safety net).

---

## 1. Diagnosis — why extension is hard today

The build pipeline is: `ModelRun.run` → `_run` (solving.jl) → per stage constructs a
`SubRun` → `SubRun` inner constructor (model_structs.jl:363) hardcodes 6 OptiNodes and calls
`create_energybalance` (energy_balances.jl:7) → which hardcodes `add_disp_generators`,
`add_ndisp_generators`, `add_storage`, `add_network`, `add_prosumer`, `link_components`.

Concrete blockers to adding a custom component:

| # | Blocker | Location | Why it hurts |
|---|---------|----------|--------------|
| B1 | `SubRun` hardcodes 6 named `OptiNode` fields (`disp`,`ndisp`,`sto`,`network`,`prosumer`,`balance`) | model_structs.jl:363-408 | A new node has nowhere to live without editing the struct. |
| B2 | `SubRun` constructor hardcodes the 6 `add_module!` calls + calls `create_energybalance` | model_structs.jl:382-406 | Construction and model-building are fused; no injection point. |
| B3 | `create_energybalance` hardcodes the `add_*` call list | energy_balances.jl:7-14 | Cannot register an extra builder. |
| B4 | **`link_components` hardcodes the balance equation by naming every node's variables** (`sr.disp[:GEN]`, `sr.ndisp[:FEEDIN]`, `sr.sto[:GEN]-sr.sto[:CHARGE]`, `sr.network[:NETINPUT]`, prosumer term) | energy_balances.jl:37-263 (4 near-duplicate methods) | **The crux.** A component that injects power into a node/zone cannot join the balance without editing all 4 methods. |
| B5 | `_run` is ~7 near-duplicate methods differing only by stage order + inter-stage glue | solving.jl:35-311 | The stage *sequence* and the *glue* (`calc_fbmc_params`,`prev_results_for_redispatch`,`get_balance`) are re-encoded imperatively per method, even though the `MarketState` types in market_definitions.jl already model the stages. Adding/reordering = copy-edit a whole method. |
| B6 | `add_disp_generators`/`add_ndisp_generators`/`add_storage` have byte-identical `DayAhead` vs `TwoDayAhead` methods | technologies.jl:7-533 | ~250 duplicated lines; every fix must be applied twice. |
| B7 | `Parameters` is a ~90-field monolith struct | model_structs.jl:198-281 | Custom data for a custom component forces a core struct edit. |
| B8 | `results_value_cols` / `results_dual_cols` const dicts hardcode the result schema | model_structs.jl:410-442 | Custom result tables aren't discoverable. |
| B9 | `add_module!` and the whole component API are internal / unexported | utils/model_utils.jl:63; POMATWO.jl exports | No public surface for user extension. |

Net: "add one component" currently touches `SubRun`, `create_energybalance`, up to 4
`link_components`, up to 7 `_run`, plus `Parameters`. That is the problem to fix.

---

## 2. Target architecture

### 2.1 Component interface (the core new seam)

A component owns one `OptiNode` and declares how it plugs into the shared balance. Define a
small interface (methods a user overloads):

```julia
abstract type ModelComponent end

# Build vars/constraints/objective on the component's own OptiNode. Return the node.
build!(c::ModelComponent, sr::SubRun) -> OptiNode

# Contribution of this component to the balance at (node n, time t). Return an
# AffExpr/VariableRef, or `nothing` if the component does not inject at n. Summed into the
# generic balance link-constraint. Zonal balance calls with z; nodal with n (see 2.2).
injection(c::ModelComponent, sr::SubRun, region, t) -> Union{AffExpr,VariableRef,Nothing}

# Push this component's variables into result DataFrames (optional; default no-op).
collect_results!(c::ModelComponent, sr::SubRun) = nothing

# Result table schema this component contributes (default empty). Replaces B8.
result_columns(::Type{<:ModelComponent}) = Dict{Symbol,Any}()
```

Existing behaviour (`add_disp_generators`, storage energy-balance, network line limits,
prosumer, redispatch up/down, FBMC) each become a `ModelComponent` subtype implementing
`build!` + `injection` + `collect_results!`. The current `add_*` function bodies move almost
verbatim into `build!` methods — dispatch keys (`MarketType`,`ProsumerSetup`,`RedispatchSetup`,
`MarketState`) are preserved, so golden results are unchanged.

### 2.2 Generic energy balance (kills B4)

**Balance scope is NOT always nodal.** The four current `link_components` methods differ in
their region set, and the scope is a function of `(MarketType, MarketState)`:

| MarketType | MarketState | balances over | network term | load term |
|---|---|---|---|---|
| ZonalMarket | DayAhead | `Z` | `EXCHANGE[z,t]` | Σ `nodal_load` over `nodes_in_zone[z]` |
| ZonalMarket | TwoDayAhead (FBMC basecase) | `N` | `NETINPUT[n,t]` | `nodal_load[n][t]` |
| NodalMarket | DayAhead | `N` | `NETINPUT[n,t]` | `nodal_load[n][t]` |
| any | Redispatch | `N` (always) | `NETINPUT[n,t]` | `nodal_load[n][t]` |

Encode this explicitly as a trait instead of hardcoding either level:

```julia
abstract type BalanceScope end
struct NodalScope <: BalanceScope end   # regions = sets.N
struct ZonalScope <: BalanceScope end   # regions = sets.Z

balance_scope(::ZonalMarketType, ::DayAhead)     = ZonalScope()
balance_scope(::MarketType,      ::MarketState)  = NodalScope()   # 2DA, nodal DA, Redispatch

regions(::NodalScope, params) = params.sets.N
regions(::ZonalScope, params) = params.sets.Z
load(::NodalScope, params, n, t) = params.nodal_load[n][t]
load(::ZonalScope, params, z, t) = sum(params.nodal_load[n][t] for n in params.nodes_in_zone[z]
                                       if haskey(params.nodal_load, n))
```

`injection` takes the scope, so a component answers at the granularity the balance asks for:

```julia
injection(c::ModelComponent, sr, scope::BalanceScope, region, t)
```

- Plant-like components (`Dispatchable`, `NonDispatchable`, `Storage`) implement the nodal
  method; a generic zonal fallback sums their nodal answer over `nodes_in_zone[z]` (identical
  to today's `plants_in_zone` formulation since plant→node→zone is consistent — assert this
  in `validate_params`). Components may override the zonal method for efficiency.
- `Network` MUST implement both explicitly: `ZonalScope → EXCHANGE[z,t]`,
  `NodalScope → NETINPUT[n,t]` — they are different models, not aggregations of each other.
- `Prosumer` demand sits on the load side today; represent it as a **negative injection**
  (mathematically identical) so the interface stays single-method. Document the sign
  convention prominently.

One generic method then serves all four variants:

```julia
function link_balance(sr::SubRun)
    scope = balance_scope(sr.modelrun.setup.MarketType, sr.market_state)
    R = regions(scope, params); T = sr.market_state.Time
    @linkconstraint(m, Balance[r = R, t = T],
        sum(injection(c, sr, scope, r, t) for c in sr.components
            if injection(c, sr, scope, r, t) !== nothing)          # hoisted in real impl
        - balance[:CU][r,t] == load(scope, params, r, t) - balance[:LL][r,t])
end
```

**Guardrail — dual extraction depends on constraint names.** `get_balance`
(utils/get_vals_utils.jl:56-58) reads `sr.optigraph[:ZonalMarketBalance]` /
`[:NodalMarketBalance]`, and `results_dual_cols` keys the result tables
(`ZonalMarketBalance`, `NodalMarketBalance`, `NodalMarketRedispBalance`). The generic
balance must register the link-constraint under the same scope-dependent name (or
`get_balance`/result keys must be migrated in the same commit). A silent rename breaks
prosumer price assignment without a test failure unless golden PRS results are compared —
they are, but only in prosumer test cases; verify those run.

A user's custom component implements `injection` (nodal at minimum) and is automatically in
the balance for every market type — **zero core edits.**

### 2.3 Generic `SubRun` (kills B1–B3)

Replace the 6 named fields with:

```julia
struct SubRun{MT,PS,RD,MS}
    results::Dict{Symbol,DataFrame}
    optigraph::OptiGraph
    nodes::Dict{Symbol,OptiNode}        # label => node (incl. :balance)
    components::Vector{ModelComponent}
    modelrun::ModelRun{MT,PS,RD}
    market_state::MS
end
```

Keep a thin accessor `getnode(sr, :disp)` (and optionally keep `sr.disp` working via
`Base.getproperty` for back-compat during migration). Construction:

```julia
function SubRun(mr, ms)
    comps = components(mr.setup, ms)   # ordered list, see 2.4
    g = OptiGraph(); nodes = Dict(); results = Dict()
    for c in comps; nodes[label(c)] = add_module!(g, string(label(c))); end
    sr = SubRun(results, g, nodes, comps, mr, ms)
    for c in comps; build!(c, sr); end
    link_balance(sr)                   # generic, see 2.2
    for c in comps; collect_results!(c, sr); end
    return sr
end
```

`components(setup, ms)` builds the component list from the setup (default components +
`setup.components` user list), so registration is data, not code.

### 2.4 State pipeline — reuse `MarketState`, do NOT add a parallel `Stage` type (kills B5)

`MarketState` (market_definitions.jl:194-252 — `TwoDayAhead`, `DayAhead`,
`ProsumerOptimizationState`, `Redispatch`) is **already** the "stage" concept: it carries the
stage's `Time` + payload (`fbmc_params`, `da_market_result`, `price`) and is the `MS` dispatch
key on every builder. A separate `Stage`/`BasecaseStage`/`DayAheadStage`/… hierarchy would be
1:1 redundant with it. So there is no new `Stage` type — the pipeline is expressed as an
ordered sequence of `MarketState`s plus the glue that flows one stage's results into the next.

What the 7 `_run` methods actually hardcode is two things, both keyable on `MarketState`:
1. **the sequence** (which states, in what order) — a function of the setup;
2. **the inter-stage glue** (how the next state is constructed from the previous solve:
   `calc_fbmc_params`, `prev_results_for_redispatch`, `get_balance`).

Encode both by dispatching on `MarketState` types instead of copy-pasting them:

```julia
# 1) Ordered list of MarketState *constructors-of-types* for this setup. Reuses existing types.
#    Dispatches on {MarketType, ProsumerSetup, RedispatchSetup}. One table, ~5 rows.
state_sequence(setup)::Vector{DataType}
# e.g. ZonalMarket{FlowBased} + Redispatch  -> [TwoDayAhead, DayAhead, Redispatch]
#      NodalMarket + Redispatch             -> [DayAhead, Redispatch]
#      any + ProsumerOptimization           -> [..., ProsumerOptimizationState]

# 2) Build the next state instance from the running context (previous results).
#    Dispatch on the *target* MarketState type. Replaces the imperative glue in _run.
init_state(::Type{DayAhead},  mr, T, ctx) = DayAhead(T, get(ctx, :fbmc_params, nothing))
init_state(::Type{Redispatch}, mr, T, ctx) = Redispatch(T, ctx[:da_results])
init_state(::Type{TwoDayAhead}, mr, T, ctx) = TwoDayAhead(T)
# ...

# 3) After a solve, extract what later states need. Dispatch on the *source* MarketState.
postprocess!(sr, ctx)  # e.g. MS<:TwoDayAhead -> ctx[:fbmc_params] = calc_fbmc_params(...)
                       #      MS<:DayAhead    -> ctx[:da_results]   = prev_results_for_redispatch(sr); ctx[:price]=...

function _run(mr)
    for T in split(mr.setup.TimeHorizon)
        ctx = Dict{Symbol,Any}()
        for ST in state_sequence(mr.setup)
            ms = init_state(ST, mr, T, ctx)
            sr = SubRun(mr, ms)
            @suppress optimize!(sr)
            log_status(sr, string(nameof(ST)))
            fetch_results(sr); write_results(sr)
            postprocess!(sr, ctx)
        end
    end
end
```

Result: the 7 `_run` methods collapse to **one** generic loop + one `state_sequence` table +
a handful of tiny `init_state`/`postprocess!` methods keyed on the already-existing
`MarketState` types. No concept is duplicated. Adding a stage = add a `MarketState` subtype
(if genuinely new) and its `init_state`/`postprocess!`; reordering = edit one `state_sequence`
row. `_run_intraday` becomes a `state_sequence` that starts from `DayAhead` with a pre-seeded
`ctx[:fbmc_params]`.

Note the `write_results_2DA` special-case (solving.jl:186,235): fold it in via a
`result_prefix(::Type{TwoDayAhead}) = "2DA"` method rather than a separate write path.

### 2.5 Parameter & data extensibility (B7)

Add an open extension bag to `Parameters` so custom components carry data without editing the
struct:

```julia
extra::Dict{Symbol,Any} = Dict{Symbol,Any}()
```

Custom loaders write `params.extra[:my_thing]`; custom components read it. Longer term,
consider splitting `Parameters` into namespaced sub-structs (`PlantParams`, `GridParams`, …)
but that is optional and lower priority than the `extra` bag.

### 2.6 Public API (B9)

Export the extension surface and document it: `ModelComponent`, `build!`, `injection`,
`collect_results!`, `add_module!`, `getnode`, `MarketState`, `state_sequence`, `init_state`,
`postprocess!`, plus the `components=` keyword on `ModelSetup`. (No `Stage` type — the pipeline
reuses `MarketState`; see 2.4.)

---

## 3. Phased execution plan

Each phase is independently mergeable and must leave `Pkg.test` green. Steps are sized for
one focused edit each.

### Phase 0 — Safety net (do first)
- [x] 0.1 Confirm `test/runtests.jl` runs all golden cases locally; record baseline pass.
- [x] 0.2 (implemented directly as test_custom_component.jl) Add a tiny "custom component" acceptance test stub (currently `@test_skip`) that
      will be un-skipped in Phase 6 — this is the definition of done for the whole effort.

### Phase 1 — Introduce the interface as an adapter (no behavior change)
- [x] 1.1 New file `src/components.jl`: define `ModelComponent`, `build!`, `injection`,
      `collect_results!`, `result_columns`, `label`. Include it early in POMATWO.jl.
- [x] 1.2 Define concrete subtypes wrapping existing builders: `Dispatchable`,
      `NonDispatchable`, `Storage`, `Network`, `Prosumer`. Their `build!` **call the existing
      `add_*` functions** (thin adapters). No logic moves yet. Golden tests unchanged.

### Phase 2 — Generic balance
- [x] 2.1 Add `BalanceScope` trait + `balance_scope(MT, MS)` + `regions`/`load` (see 2.2 table).
      Unit-test the trait mapping against all 4 current `link_components` methods.
- [x] 2.2 Implement `injection(c, sr, scope, r, t)` for each component by reading the variable
      it already creates (`Network`: both scopes explicitly; plant-likes: nodal + generic zonal
      fallback; `Prosumer`: negative injection for demand). Cross-check exact expressions
      against current `link_components` so the equation is identical per scope.
- [x] 2.3 Add generic `link_balance(sr)` registering the constraint under the existing
      scope-dependent names (`ZonalMarketBalance`/`NodalMarketBalance`) so `get_balance` duals
      and `results_dual_cols` keep working. Hoist per-region component sums out of the (r,t)
      loop (see P2 in §6). Switch `create_energybalance` to call it. Delete the 4 old
      `link_components` bodies once golden tests pass — including prosumer cases (they exercise
      the dual/price path).

### Phase 3 — Generic SubRun
- [x] 3.1 Add `components(setup, ms)` returning the current fixed list per
      `{MarketType,ProsumerSetup,RedispatchSetup,MarketState}` (reproduces today's behavior).
- [x] 3.2 Rewrite `SubRun` to hold `nodes::Dict` + `components::Vector`. Add
      `getproperty` shims (`sr.disp` etc.) so unmigrated call sites keep working.
- [x] 3.3 Move build orchestration into the constructor loop (2.3). Remove
      `create_energybalance`'s hardcoded list.

### Phase 4 — State pipeline (reuse `MarketState`, no new `Stage` type)
- [x] 4.1 Add `state_sequence(setup)`, `init_state(::Type{<:MarketState}, mr, T, ctx)`,
      `postprocess!(sr, ctx)`, and `result_prefix`. Port the DA / Prosumer / Redispatch /
      FBMC-basecase sequences from the 7 `_run` methods into these `MarketState`-keyed methods
      (reuse the existing types in market_definitions.jl; add none).
- [x] 4.2 Replace all `_run` methods with the single generic loop. Keep `_run_intraday`
      behavior as a `stages` variant or documented entry point.

### Phase 5 — Data extensibility
- [x] 5.1 Add `Parameters.extra::Dict{Symbol,Any}`.
- [x] 5.2 Add a `validate_params` hook so a component can register validation
      (`validate(c, params, setup)`), tying into the existing DataReport system — keeps the
      "auto-detect faulty input" goal working for custom components.

### Phase 6 — Public API + docs + worked example
- [x] 6.1 Export the extension surface (2.6).
- [x] 6.2 Write `docs/src/extending.md`: "Add a custom component in ~30 lines" — define a
      `struct MyBattery <: ModelComponent`, `build!`, `injection`, register via
      `ModelSetup(; components=[..., MyBattery()])`.
- [x] 6.3 Un-skip the Phase 0 acceptance test: a toy custom component (e.g. a fixed nodal
      demand-response injector) that participates in the balance with **no core edits**.

### Phase 7 — De-duplication cleanups (independent, low risk)
- [x] 7.1 Merge the byte-identical `DayAhead`/`TwoDayAhead` methods in technologies.jl (B6)
      by widening the `MS` type bound (`MS<:Union{DayAhead,TwoDayAhead}`), after Phase 1.
- [x] 7.2 (resolved differently) `fetch_results` now value-transforms every column of every
      result table generically — custom component tables included; `results_value_cols`
      deleted, `results_dual_cols` kept for dual extraction. Also fixes F5.
- [ ] 7.3 Replace unmaintained `UnPack` (already flagged in ToDos.md) once call sites are
      touched anyway.

---

## 4. Design checks / risks

- **Plasmo compatibility**: the JuMP/Plasmo shim at POMATWO.jl:23 must be preserved; the
  generic `@linkconstraint` in 2.2 uses the same graph-level macro already used in
  `link_components`, so no new Plasmo surface is required.
- **Objective composition**: today each node sets its own `@objective`; the graph sums them.
  Components keep that pattern — `build!` sets the component's node objective **once**. Do not
  blindly port the existing multi-`@objective` bodies: see finding F1 in §5 (JuMP `@objective`
  replaces, it does not add). Verify the FBMC/infeasibility penalty objectives
  (technologies.jl:1034, prosumer.jl:120) still attach to their own nodes.
- **`getproperty` shim** is the migration lever: it lets Phases 2–4 land incrementally without
  a big-bang rewrite of every `sr.disp[...]` reference. Remove it in a final cleanup once no
  call sites remain.
- **Golden tests are behavioural, not structural** — as long as the emitted variables,
  constraints, and result DataFrames match, refactors are safe. Keep `@suppress`/solver
  identical.

## 5. Correctness findings (found during plan review — handle OUTSIDE the refactor)

These are pre-existing issues. **Do not fix them silently inside refactor phases** — fixing
them changes golden results, which would mask refactor regressions. Triage each first
(methodological decision by maintainer), then fix in a dedicated commit with regenerated
goldens and a changelog note.

| # | Finding | Location | Impact |
|---|---------|----------|--------|
| F1 | `@objective` **replaces** the node objective, it does not add. `add_ndisp_generators` sets `Min 50*ΣCU`, then — if `historical_generation` present — overwrites it with `Min 1000*ΣHISTORICAL_INF`, then — if `min_generation` present — overwrites again with `Min 1000*ΣMINGEN_INF`. | technologies.jl:144,151,173 (and 2DA copy 219,226,248) | With historical/min-gen inputs, curtailment penalty (and possibly the historical penalty) silently drop out of the objective. Datasets without those inputs (e.g. 3-node goldens) unaffected. Fix = accumulate terms, one final `@objective`. |
| F2 ✅ | **RESOLVED**: `StorageBoundary` setup option — `CarryOverStorage(start_share)` (default, levels carried across splits via pipeline ctx) and `CyclicStorage()` (uniformly cyclic per split). Original finding: storage inter-temporal constraint branched on literal `t == 1`, but splits start at arbitrary t. First split: acyclic start (implicit level 0). Later splits: `t==T[1]` falls through to `prev_period`, which wraps to `T[end]` → **cyclic** storage. Same in redispatch storage and prosumer `StorageBalance` (always cyclic). | technologies.jl:323,446,678; utils/time_utils.jl:20; prosumer.jl:57 | First split has different storage semantics than every other split. Decide intended boundary condition (cyclic per split vs. carry-over vs. fixed start level) and implement uniformly — `t == T[1]` at minimum. |
| F3 ✅ | **RESOLVED**: removed (variable, objective, result columns, check_infeasibility rows). Line limits cannot cause infeasibility on their own — THETA=0 always feasible, imbalance lands in CU/LL. Original finding: `LINEINF` is created and penalized in the objective but appears in **no constraint** → always 0, dead variables (ToDos.md already suspects this). | technologies.jl:779,786 | Noise in model + results (`lineinf` column always 0). Either wire it into the line-limit constraints as real slack or delete. |
| F4 | Zonal balance load term shadows the zone variable: `sum(nodal_load[z][t] for z in nodes_in_zone[z] …)` — inner `z` iterates *nodes*. Works, but reads as a bug. | energy_balances.jl:61 | Readability only. Dies automatically with the generic `load(::ZonalScope, …)` in 2.2. |
| F5 | `fetch_results` computes `col = results_value_cols[k]` then ignores it, applying `value_or_number` to **every** column (incl. index/Time). | utils/model_utils.jl:8-9 | Wasted per-cell dispatch over full DataFrames; masks schema errors. Fold into `result_columns` migration (Phase 7.2). |
| F6 | Duplicate `da_results = prev_results_for_redispatch(sr)` (computed twice back-to-back). | solving.jl:140,143 | Wasted work only. Dies with Phase 4. |

---

## 6. Performance opportunities

Ordered by expected wall-clock impact. P1/P2 are large and low-risk; do P2 alongside Phase 2/3
(same code is being touched), P1 after Phase 4 (needs the generic loop).

- **P1 ✅ (implemented) — Parallelize splits.** `_run` threads over splits when `Threads.nthreads() > 1` and splits are independent (`CarryOverStorage` with non-empty storage forces sequential). `@suppress` replaced by per-model `MOI.Silent` so no global stdout state under threading. Each `T in split(...)` iteration is independent (storage is
  cyclic *within* a split, no state crosses splits; result dirs are per-subrun). After Phase 4
  the loop body is generic → `Threads.@threads` (or `Distributed.pmap`) over splits, one solver
  env per task. Near-linear speedup for year runs (365 splits). Caveats: HiGHS is not
  thread-safe across a shared env (create per-task optimizers — `set_optimizer` already runs
  per SubRun); cap `JULIA_NUM_THREADS` vs solver threads; `ctx` stays split-local so the FBMC
  basecase→DA chain still works inside one split.
- **P2 ✅ (implemented via member caches) — Hoist set algebra out of constraint loops.** The balance does
  `intersect(DISP, plants_in_zone[z])` *per (z,t)* (energy_balances.jl:57-59 and 3 siblings);
  `add_*` builders `filter` plant lists per fueltype inside loops. Precompute
  `region → component-members` maps once per SubRun (fits naturally in `build!`) — model build
  time drops noticeably for large systems.
- **P3 ✅ (implemented) — Column-wise results instead of row `push!`.** All builders emit DataFrame blocks via `append_results!`; fetch stays vectorized. Builders push one NamedTuple of
  `AffExpr`/`VariableRef` per (p,t) into DataFrames, then `fetch_results` runs `ByRow` over
  everything. Collect columns as vectors and call vectorized `value.()` once per column; also
  fixes F5. Big constant-factor win on result handling for year runs.
- **P4 ✅ (implemented) — Type-stable parameter access.** `ConcreteProfile = Union{FixedProfile{Float64},HourlyProfile{Float64}}` + `Base.convert` methods; Parameters dicts concretized, call sites unchanged. `Dict{String,Profile}` fields have abstract value
  type → dynamic dispatch on every `mc[p][t]` inside `@variable`/`@objective` loops. Options:
  function barrier per builder (extract to concretely-typed locals), or concrete
  `Union{FixedProfile{Float64},HourlyProfile{Float64}}` value type (small union → fast). Pairs
  with the `Parameters.extra` work in Phase 5.
- **P5 ✅ (implemented) — Make `@suppress` optional.** `ModelRun(; verbose=false)`; silencing via `_silent_solver` (MOI.Silent), Suppressor dependency removed. Wrapping `optimize!` in `Suppressor.@suppress` costs
  stream redirection and hides solver logs users need for tuning. Add
  `ModelRun(...; verbose=false)` and drop `@suppress` when verbose.
- **P6 — (Later, measure first) single-model backend.** Plasmo's OptiGraph adds indirection vs
  a flat JuMP model. If profiling after P1–P4 still shows build overhead, add an optional
  "flatten" path (Plasmo supports aggregation) behind the same component API. Do not do this
  speculatively — the graph structure is the extensibility feature.

---

## 7. Definition of done
A user adds a new `ModelComponent` subtype in a single user file, passes it via
`ModelSetup(; components=[...])`, and it (a) builds on its own OptiNode, (b) contributes to the
energy balance through `injection` at the correct `BalanceScope` for every market type, (c)
emits results, and (d) can register input validation — **without editing any file under
`src/`.** The Phase-6 acceptance test proves it. Correctness findings (§5) are triaged and
fixed in dedicated commits with regenerated goldens; performance items P1–P3 are implemented
or consciously deferred.
