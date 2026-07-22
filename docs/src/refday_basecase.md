# FBMC Reference-Day Basecase

Flow-based market coupling (FBMC) requires a *basecase*: a forecast of the nodal
injections and line flows expected on the delivery day, from which the zonal PTDF and the
Remaining Available Margins (RAM) of the flow-based domain are derived. In the European
CWE/Core process this forecast is the **D2CF** (Two-Days-Ahead Congestion Forecast), which
TSOs build not by solving an optimization problem but by taking a *reference day* — a
recent, similar day — and adjusting it toward the expected conditions of the delivery day.

POMATWO supports two ways to obtain the basecase for a `ZonalMarket(FlowBased(...))` run:

- [`OptimizationBasecase`](@ref) (default): solve the `TwoDayAhead` optimization state — a
  clean but idealized proxy in which the basecase is itself a market-optimal dispatch.
- [`ReferenceDayBasecase`](@ref) (this page): mimic the D2CF process. Match every target
  day to a similar day of a previous ("forecast") model run and *shift* that day's nodal
  injection pattern toward the target day's renewable infeed and zonal net positions. The
  `TwoDayAhead` state is then skipped entirely; the basecase is built once for the whole
  horizon before the split loop (`_prepare_refday_artifacts` in `src/solving.jl`) and fed
  into [`calc_fbmc_params`](@ref) exactly like a `TwoDayAhead` result.

The purpose of the reference-day path is to let you study an FBMC process *closer to
operational reality*, where capacity-calculation inputs are heuristic forecasts with
errors and conventions — not the output of a welfare-maximizing solver. The price is that
almost every step is governed by a user decision with no single "correct" setting. This
page walks through both stages, flags each decision and its risk, assesses the methodology
critically, and ends with a fully hand-checkable numeric example.

The construction returns a dict with `:netinput_ac` (node × time nodal net injection) and
`:lineflows` (line × time, `= PTDFn · netinput`) — a drop-in replacement for the
`TwoDayAhead` results.

!!! warning "User decision 0: the source run (`source`, `source_type`)"
    The entire construction is anchored to the results of a previous POMATWO run. `source`
    names its results directory; `source_type` selects which MarketState of that run
    provides **both** the matching data and the injection baseline (never mixed):
    `""`/`"DA"` day-ahead, `"2DA"` the TwoDayAhead basecase, `"REDISP"` redispatch.
    Risks:

    - A *zonal* day-ahead source persists no nodal tables; nodal injections are then
      reconstructed from plant-level `GEN`/`CHARGE` and nodal load. DC-line flows,
      prosumer net input, and infeasibility slacks are not nodally attributable and are
      **silently omitted** (exact only for AC-only networks whose DA stage used no slack).
    - The "forecast" is another run of the same model — usually with the *same* input time
      series as the target run. That is (almost) perfect foresight in disguise, the only differences occur due to possibly different RAM.

## Stage 1 — Reference-day matching

Implemented in `src/utils/refday_matching.jl`, configured by [`MatchingConfig`](@ref).

1. **Clustering.** The time axis is cut into contiguous clusters of `cluster_size` steps
   (default 24 — a "day").
2. **Profiles.** From the source run's generation table, only plants whose `plant_type`
   contains one of the `res_tags` substrings (default `"solar"`, `"wind"`) are kept. Per
   cluster, their generation is aggregated by `keycols` (default `(plant_type, node)`)
   using the statistics in `value_methods` (default `median` and `maximum`).
3. **Distance.** Similarity between two clusters is the weighted distance between
   their profiles ([`match_by_cluster`](@ref); weights per statistic column, optionally
   per plant type).
4. **Candidate window.** Each target cluster is compared against its `lookback`
   predecessors (default 14), *cyclically wrapped* around the horizon. With
   `exact_weekend = true`, candidates must share the weekend/workday type of the target
   (classified from `start_date`); if no such candidate exists the restriction is relaxed
   with a warning rather than dropping the day.
5. **Selection.** The minimum-distance candidate wins; ties break toward temporal
   proximity. Every hour of the target cluster is then mapped to the hour at the *same
   intra-cluster position* of the matched cluster.
6. **Scope.** With [`ZonalMatchScope`](@ref) or [`AreaMatchScope`](@ref) the matching runs
   independently per bidding zone / control area ([`match_by_scope`](@ref)) — each group
   borrows its own reference day, mimicking how each TSO builds the D2CF for its own area
   before merging. Groups without a match fall back to the global match table.

!!! warning "User decisions in Stage 1"
    | Decision | Default | Risk |
    |---|---|---|
    | `cluster_size` | 24 | Anything but 24 breaks the "day" analogy; hour mapping is positional, so unequal cluster lengths (horizon not a multiple of `cluster_size`) silently truncate. |
    | `start_date` | 2013-01-01 | Weekday/weekend classification is a pure user assertion; a wrong anchor mislabels every weekend. |
    | `lookback` | 14 | Too small forces bad matches. The cyclic wrap lets early days match "future" days from the horizon end — defensible for a full year, distorting for short horizons. |
    | `exact_weekend` | `true` | The automatic relaxation keeps coverage but surfaces only as a `@warn` in the log. |
    | `keycols`, `value_methods`, `weights` | `(plant_type, node)`, median+max, 1.0 | The similarity metric is entirely user-shaped; different choices select different reference days. |
    | `res_tags` | `["solar","wind"]` | Defines both the matching signal *and* the RES shift lever. Substring matching (`occursin`) can catch unintended plant types. |
    | `scope` | global | Per-area matching stitches injections from *different* days into one system snapshot — see the critical assessment. |

The deepest limitation of Stage 1 is what the distance *cannot* see: it is computed from
renewable generation only. Load level, unit outages, storage state, and import/export
patterns are invisible, so a "similar RES day" is treated as a "similar grid situation" —
which it need not be. The per-cluster statistics (median, maximum) also erase intra-day
shape: a morning-peaked and an evening-peaked wind day with equal median and maximum are
indistinguishable.

## Stage 2 — Shifting the reference day

Implemented in `src/utils/refday_basecase.jl`, configured by [`ShareShift`](@ref). The
whole pipeline works **export-positive** (feed-in convention: nodal injection
`P = gen − load − charge`, positive = the node feeds the grid). The persisted
`NETINPUT`/`ACINJECTION` result tables use the opposite, import-positive model convention;
the baseline is negated on entry and the assembled basecase negated back on exit.

For every target hour ``t`` with matched reference hour ``r`` (per node, when matching is
scoped), `shift_single` proceeds as follows:

1. **Baseline.** Start from the reference hour's nodal injection ``P(n,r)`` and its
   per-node RES generation, conventional generation, and load.
2. **Optional RES pre-step** (`res_prestep = true`). Hard-set renewable infeed to the
   target hour's value — nodally (direct) or zonally (the zonal RES total is aligned while
   the reference day's intra-zone RES shares are preserved). This mirrors the D2CF step of
   inserting the delivery-day wind/solar forecast into the snapshot.
3. **Net-position gap.** Per zone: ``D(z) = NP_{target}(z) − NP_{current}(z)``, where
   ``NP`` is the zonal sum of nodal injections. (With `resolution = :nodal` the gap is
   computed per node instead — the output then *equals* the target's own nodal injection
   and the reference day contributes nothing; a degenerate setting, useful only as an
   upper benchmark.)
4. **Apportionment (physical levers only).** The gap is split among the physical
   components RES / conventional / load / storage by the shares
   ``β_{RES}, β_{conv}, β_{load}`` (must sum to ``≤ 1``; the leftover
   ``1 - β_{RES} - β_{conv} - β_{load}`` is the fraction *deliberately* left relaxed
   toward the reference). Each component's zonal
   amount is spread across the zone's nodes by the [`RedistKey`](@ref)
   ([`GSKRedist`](@ref), [`RefPropRedist`](@ref), [`LoadPropRedist`](@ref), or
   `RandomRedist`), clipped to physical headroom (conventional and RES between 0 and their
   *availability-weighted* installed capacity at the target hour; storage to ±installed
   power; load cuts limited by the reference load) via bounded waterfilling, cascading down
   `fallback_order` (default `conv → sto → load`). There is **no** phantom exchange slack:
   a gap no physical lever can absorb is left relaxed toward the reference and recorded as
   `np_relax`.
5. **Global balance.** With `enforce_balance = true` (default) a final pass forces the
   whole basecase to represent a globally **balanced** system (`Σ_n injection = 0`,
   production = consumption) by adjusting conventional generation (load only as a last
   resort), so the net-injection basecase is physically consistent for the PTDF/FBMC flow
   computation. Applied deltas are traced as `balance`.
6. **Assembly.** The shifted injections are negated back to the import-positive
   convention (`:netinput_ac`) and multiplied with the nodal PTDF (`:lineflows`).

### Traceability

With `collect_trace = true` (the default in the solving pipeline) three Arrow tables
reconstruct the construction exactly: `REFDAY_MATCH` (per group and target hour: matched
time, cluster distance, fallback flag), `REFDAY_GROUPS` (group → node membership), and
`REFDAY_SHIFT` (per target hour, node, and component: the applied injection delta,
export-positive). The reconstruction identity is

```
netinput_ac[n, t] = ACINJECTION_source(n, ref(n, t)) − Σ deltas(n, t)
```

(the minus stems from the sign-convention flip between trace and result tables; the
sum runs over the per-node injection components, including `balance`). The `"np_relax"`
component records, per zone (zone label in the `node` column), how far the zone's net
position was left relaxed toward the reference — it is an annotation, not a nodal
injection, and is excluded from the reconstruction sum.

!!! warning "User decisions in Stage 2"
    | Decision | Default | Risk |
    |---|---|---|
    | ``β`` shares | `β_conv = β_load = 0.5` | Pure judgment call — *who absorbs the forecast gap* directly shapes the basecase flows, hence ``f_0`` and RAM. Shares must sum to ``≤ 1`` (leftover is `np_relax`); a sum ``> 1`` is a hard error. |
    | `res_prestep` | `false` | Combined with `β_RES > 0`, RES is moved twice (warned, not blocked). |
    | `resolution` | `:zonal` | `:nodal` discards the reference day entirely (see above). |
    | `redist` | `GSKRedist(FlatGSK())` | The spatial allocation of every correction is user-chosen. With `GSKRedist`, GSK assumptions enter the basecase *and* enter again through the zonal PTDF — the same heuristic used twice. |
    | `fallback_order` | `[:conv, :sto, :load]` | Physical levers only. A gap no lever can absorb is relaxed toward the reference (`np_relax`), not faked. |
    | `enforce_balance` | `true` | Off produces a basecase that need not satisfy `Σ_n injection = 0` — physically inconsistent for the PTDF/FBMC flow calc. |

Two structural points deserve emphasis. First, the bounds: conventional and RES changes
are capped by *availability-weighted* installed capacity, storage by ±installed power, load
*cuts* by the reference load — load *increases* are unbounded. A zonal gap that exceeds the
zone's physical headroom is not faked: it is left relaxed toward the reference and recorded
as `np_relax`, while the final global-balance pass (conventional generation, load as a last
resort) keeps `Σ_n injection = 0`. Second, the realized component split can deviate
arbitrarily from the stated ``β`` shares whenever waterfilling hits a bound — the shares
are targets, not outcomes. Storage, finally, now acts as a bidirectional shift lever
(installed power assumed available every timestep) in addition to being netted in the
baseline.

## Handoff to the flow-based domain

The returned dict is consumed by [`calc_fbmc_params`](@ref): the GSK and zonal PTDF are
built (per timestep for time-dependent GSK strategies), critical network elements are
screened, and `calc_ram` computes the basecase reference flow ``f_0`` and the RAM per CNE
and direction. Nothing more is said about that math here — see the docstrings — but note
the propagation: every heuristic choice above enters ``f_0`` *linearly* and thereby
directly tightens or widens the flow-based domain the day-ahead market clears against.

## Coverage of the CWE D2CF methodologies

The approved CWE flow-based methodology (see the
[ACM/TenneT filing](https://www.acm.nl/sites/default/files/documents/2020-07/aanvulling-op-aanvraag-tennet-wijziging-cwe-flow-based-day-ahead.pdf),
section 4.1.5, pp. 27–34) documents each TSO's D2CF procedure. All variants share a
skeleton — reference-day snapshot, topology/outage adjustment, RES forecast insertion,
load adjustment, net-position alignment, slack distribution — but differ in the details.
POMATWO's implementation spans a meaningful subspace of exactly those axes:

| CWE D2CF element | POMATWO lever |
|---|---|
| Snapshot from a reference day (TransnetBW: "last working day / last weekend") | Stage 1 matching; `lookback`, `exact_weekend` |
| RTE: snapshots chosen as "best compromise between generation pattern, load pattern and exchanges" | distance-based matching (though the signal is RES-only) |
| Each TSO builds the D2CF for its own area, then merges | `ZonalMatchScope` / `AreaMatchScope` |
| Amprion: wind/solar forecast inserted via dedicated RES GSKs | `res_prestep = true` |
| Amprion: net position adapted, slack spread over market-based units via GSK | `β_conv` with `GSKRedist` |
| APG/Elia: load adjusted to forecast, distributed per the reference day | `β_load` with `LoadPropRedist` / `RefPropRedist` |
| TenneT NL: pro-rata redispatch of GSK units between min/max levels | approximated by the bounded waterfilling (not the exact pro-rata formula) |

Not representable with the current implementation:

- **Topology and outage adjustment** — the first step of every TSO procedure. POMATWO
  uses a static PTDF; reference and target day share one grid.
- **Heterogeneous per-area shift procedures** — matching is scoped, but one global
  `ShareShift` applies to all zones; "Amprion does X, TenneT does Y" cannot be configured.
- **Unit-level minimum generation** — the pro-rata redispatch of TenneT NL requires
  per-unit ``P_{min}``/``P_{max}``; the shift works on nodal class aggregates with a lower
  bound of zero.
- **DC-cable exchange programs** taken from the reference day (the baseline is AC-only).
- **Merging with non-CWE DACF files** and unscheduled allocated flows.
- **Forecast errors as an input** — TSOs consume genuinely uncertain load/RES/exchange
  forecasts; here the "forecast" is a sibling model run. Forecast errors only included indirectly by different market setups or different load/availibility input data.
- **Plausibility checks** — TSOs run AC load flows and convergence checks on the merged
  base case; the shifted injections are never validated against anything.

## Improvement outlook

Code-robustness improvements: a strict mode turning the remaining `validate_shares`
warning (`res_prestep` + `β_RES > 0` double-moves RES) into an error — the share-sum
check is already hard; explicit key columns in `profile_distance` (currently inferred from column
*positions*); a tolerance in the tie-break comparison of `match_by_cluster` (exact `==`
on floats); an opt-out for the cyclic lookback wrap; convergence diagnostics from the
waterfilling loop; a cap on the unbounded load-increase direction; and property tests for
the two invariants ``\sum_n P_{new}(n) = NP_{target}(z)`` and the trace reconstruction
identity.

## Worked example

Three nodes: `N1`, `N2` in zone A, `N3` in zone B. One wind plant at `N1`, one solar
plant at `N3`; conventional capacity ``g^{max}_{conv}`` = 50 / 50 / 100 MW at N1 / N2 /
N3. To keep tables small the example uses `cluster_size = 2` — two-hour "days" (real runs
use 24); six hours = three clusters, cluster 3 (hours 5–6) is the target day,
`lookback = 2`, all days are workdays.

### Stage 1: matching

RES generation of the source run (MW):

| hour | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| wind @ N1 | 60 | 40 | 30 | 10 | 50 | 45 |
| solar @ N3 | 20 | 10 | 5 | 15 | 20 | 10 |

Per-cluster profiles with the default statistics (median, maximum) — for two values the
median is their mean:

| cluster (hours) | wind med | wind max | solar med | solar max |
|---|---|---|---|---|
| 1 (1–2) | 50 | 60 | 15 | 20 |
| 2 (3–4) | 20 | 30 | 10 | 15 |
| 3 (5–6) | 47.5 | 50 | 15 | 20 |

L1 distances of the target cluster 3 to its two candidates (unit weights):

- to cluster 1: ``|47.5−50| + |50−60| + |15−15| + |20−20| = 12.5``
- to cluster 2: ``|47.5−20| + |50−30| + |15−10| + |20−15| = 57.5``

Cluster 1 wins. Positional hour mapping: hour 5 → hour 1, hour 6 → hour 2. (Had the
distances tied, temporal proximity would have picked cluster 2; had cluster 3 been a
weekend and both candidates workdays, `exact_weekend` would have been relaxed with a
warning.)

### Stage 2: shift for target hour 5 (reference hour 1)

Full nodal data of the source run at the two hours (export-positive injection
``P = conv + RES − load``):

| | conv | RES | load | ``P`` |
|---|---|---|---|---|
| **hour 1 (reference)** | | | | |
| N1 | 44 | 60 | 50 | **54** |
| N2 | 48 | — | 68 | **−20** |
| N3 | 20 | 20 | 40 | **0** |
| **hour 5 (target)** | | | | |
| N1 | 54 | 50 | 50 | **54** |
| N2 | 40 | — | 50 | **−10** |
| N3 | 30 | 20 | 40 | **10** |

Zonal net positions: ``NP_{ref}(A) = 54 − 20 = 34``, ``NP_{tgt}(A) = 54 − 10 = 44``;
``NP_{ref}(B) = 0``, ``NP_{tgt}(B) = 10``.

Configuration: `ShareShift(β_conv = 0.5, β_load = 0.5, res_prestep = true,
redist = LoadPropRedist(), enforce_balance = false)` — the global balance pass is disabled
here to isolate the per-zone cascade (see the note after the result).

**Step 1 — RES pre-step (zonal).** Zone A's reference RES total is 60 (all at N1), the
target's is 50: ``Δ = −10``, allocated by reference RES shares — entirely to N1.
``P(N1): 54 → 44``. Zone B: reference and target solar are both 20, no change. Working
state: ``NP_{cur}(A) = 44 − 20 = 24``.

**Step 2 — gap.** ``D(A) = 44 − 24 = 20``; ``D(B) = 10 − 0 = 10``.

**Step 3 — conventional share, zone A.** Amount ``0.5 · 20 = 10``. `LoadPropRedist`
weights use the *target-hour* loads (50, 50 → equal split): 5 to each node. Headroom
(installed minus reference dispatch): N1 has ``50 − 44 = 6``, N2 has ``50 − 48 = 2``. N2
caps at +2; waterfilling redistributes the excess 3 to N1, which caps at +6. Applied:
**+6 (N1), +2 (N2)** — total 8, so a remainder of **2 cascades** to the next component.
Note the realized split (6/2) bears no resemblance to the intended equal split (5/5): the
``β`` shares are targets, not outcomes.

**Step 4 — load share, zone A.** Amount ``0.5 · 20 + 2 = 12`` (own share plus the carried
remainder), split equally: **+6 (N1), +6 (N2)** — meaning load *cuts* of 6 MW each
(bounds: a cut may not exceed the reference load of 50 / 68 — not binding). The gap is
closed physically, so `np_relax` is 0.

**Zone B** (single node, no bounds binding): conventional +5, load +5 at N3.

**Result.**

| | ``P_{new}`` (export-pos.) | `:netinput_ac` (import-pos.) |
|---|---|---|
| N1 | ``44 + 6 + 6 = 56`` | −56 |
| N2 | ``−20 + 2 + 6 = −12`` | 12 |
| N3 | ``0 + 5 + 5 = 10`` | −10 |

Invariant check: ``56 − 12 = 44 = NP_{tgt}(A)`` ✓, ``10 = NP_{tgt}(B)`` ✓.

(With the default `enforce_balance = true`, a final pass would additionally adjust
conventional generation so that ``Σ_n P_{new} = 0``. Here ``56 − 12 + 10 = 54 ≠ 0``, so the
balanced basecase cuts a further 54 MW of conventional generation — spread across nodes by
remaining headroom — emitting matching `balance` trace rows. This example disables that
pass to show the per-zone cascade in isolation.)

The `REFDAY_SHIFT` trace for hour 5 (deltas export-positive):

| Time | node | component | delta |
|---|---|---|---|
| 5 | N1 | RES_prestep | −10 |
| 5 | N1 | conv | 6 |
| 5 | N2 | conv | 2 |
| 5 | N1 | load | 6 |
| 5 | N2 | load | 6 |
| 5 | N3 | conv | 5 |
| 5 | N3 | load | 5 |

Reconstruction identity for N1: source `ACINJECTION(N1, 1) = −54` (import-positive), sum
of deltas ``= −10 + 6 + 6 = 2``, and ``−54 − 2 = −56 =`` `netinput_ac[N1, 5]` ✓.

**Same example, different redistribution key.** With `RefPropRedist` (weights
proportional to the target-hour injection magnitudes, 54 vs 10) the conventional step
still saturates at +6/+2 (total headroom 8 < 10), but the load step splits 12 as
``12·54/64`` and ``12·10/64``: final injections **N1 = 60.125, N2 = −16.125** instead of
56 / −12. The zonal net position is identical (44) — but the *nodal* pattern, and with it
every line flow and every RAM derived from this basecase, differs purely because of a
configuration choice. That is the methodology's central caveat in one number.
