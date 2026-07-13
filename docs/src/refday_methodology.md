# Reference-Day Basecase — Worked Example

Flow-based market coupling (FBMC) needs a **basecase**: a nodal snapshot of net
injections from which the zonal PTDF, the reference flows ``F_0``, and the Remaining
Available Margins (RAM) are derived. POMATWO offers two ways to obtain it:

- [`OptimizationBasecase`](@ref) (default) — solve the `TwoDayAhead` DC load-flow and use
  its nodal injections and line flows.
- [`ReferenceDayBasecase`](@ref) — skip that optimization and **construct** the basecase
  from a previous ("forecast") run, mimicking the CWE **D2CF** (Two-Day-Ahead Congestion
  Forecast) process: for every target hour, borrow the nodal texture of a *similar
  historical day* and *shift* it so its renewables and zonal net positions match the
  target.

This page proves the reference-day method end to end on one small system, deriving every
sub-step **on paper** and pairing it with the **actual model output** for identical
inputs. Every model-check block below is a line in the companion script
[`examples/run_3_node_v2_fbmc_refday_example.jl`](https://github.com/EnnoWbrw/POMATWO/blob/main/examples/run_3_node_v2_fbmc_refday_example.jl);
run it top to bottom to reproduce the numbers yourself. Symbols follow the
[Nomenclature](./nomenclature.md); the nodal PTDF derivation follows
[AC Power Flow](./power_flow_ac.md).

## 1. The example system

The system `examples/test_data_3_nodes_v2_fbmc` is deliberately tuned so that congestion
lands on a single line and the effect of each design choice is visible by hand.

```
        l1 (b=1, cap 50)          l3 (b=1, cap 50)
   n2 ───────────────────► n1 ◄─────────    ─────────► n3
   │  (Z2)                   (Z1, slack)                (Z2) │
   └──────────────────────────────────────────────────────┘
                    via  l2: n1 ─► n3 (b=2, cap 40)
```

| Node | Zone | Slack | Load ``t_1{-}t_4`` |
|------|------|-------|--------------------|
| n1   | Z1   | yes   | 150, 160, 150, 150 |
| n2   | Z2   | —     | 30, 30, 30, 30     |
| n3   | Z2   | —     | 20, 20, 50, 20     |

| Line | from → to | ``b`` | ``x=1/b`` | Capacity |
|------|-----------|-------|-----------|----------|
| l1   | n2 → n1   | 1     | 1.0       | 50       |
| l2   | n1 → n3   | 2     | 0.5       | 40       |
| l3   | n2 → n3   | 1     | 1.0       | 50       |

| Plant | Type | Node | ``g^{max}`` | ``c^{mc}`` | Dispatchable | Avail ``t_1{-}t_4`` |
|-------|------|------|-------------|-----------|--------------|---------------------|
| p1    | gas  | n1   | 150         | 50        | yes          | 1                   |
| p2    | solar| n1   | 80          | 0         | no           | 1, 1, 1, 0.2        |
| p3    | wind | n2   | 50          | 0         | no           | 1, 1, 1, 0.6        |
| p4    | coal | n3   | 200         | 30        | yes          | 1                   |

Two zones: **Z1 = {n1}**, **Z2 = {n2, n3}**. Merit order: wind/solar (0) < coal (30) <
gas (50). n1 is the slack node. The key structural feature: **zone Z2 contains one
dispatchable node (n3, coal) and one non-dispatchable node (n2, wind)** — this is what
makes the GSK choice matter in §3.

```julia
params, report = load_data_with_report(data_files)
# params.sets.DISP      == ["p1", "p4"]          (gas, coal — wind/solar excluded)
# params.nodes_in_zone  == Dict("Z1"=>["n1"], "Z2"=>["n2","n3"])
# params.slack          == ["n1"]
```

The whole pipeline is:

```math
\text{forecast run} \;\xrightarrow{\text{matching}}\; \text{reference day}
\;\xrightarrow{\text{shift}}\; (INJ_{ac},\, F)
\;\xrightarrow{\texttt{calc\_fbmc\_params}}\; (GSK,\, PTDF_z,\, RAM)
\;\longrightarrow\; \text{FBMC clearing}
```

## 2. Nodal PTDF

The nodal PTDF is fixed by topology and reactances (see [AC Power Flow](./power_flow_ac.md)).
With the incidence convention ``A_{l,n}=-1`` at a line's start node and ``+1`` at its end
node, the diagonal susceptance ``B^d=\operatorname{diag}(b)``, and slack node n1:

```math
A = \begin{bmatrix} \;\;1 & -1 & 0 \\ -1 & 0 & 1 \\ 0 & -1 & 1 \end{bmatrix}
\quad
B^d = \begin{bmatrix} 1 & & \\ & 2 & \\ & & 1 \end{bmatrix}
\quad
B^{line} = B^d A = \begin{bmatrix} \;\;1 & -1 & 0 \\ -2 & 0 & 2 \\ 0 & -1 & 1 \end{bmatrix}
```

```math
B^{bus} = A^\top B^d A =
\begin{bmatrix} \;\;3 & -1 & -2 \\ -1 & \;\;2 & -1 \\ -2 & -1 & \;\;3 \end{bmatrix}
```

Delete the slack row/column (n1) and invert the reduced ``2\times2`` block on ``\{n_2,n_3\}``:

```math
B^{bus}_{red} = \begin{bmatrix} 2 & -1 \\ -1 & 3 \end{bmatrix},\qquad
(B^{bus}_{red})^{-1} = \frac{1}{5}\begin{bmatrix} 3 & 1 \\ 1 & 2 \end{bmatrix}
= \begin{bmatrix} 0.6 & 0.2 \\ 0.2 & 0.4 \end{bmatrix}
```

Re-embedding with a zero slack column and multiplying ``PTDF_n = B^{line}\,(B^{bus})^{-1}``:

```math
PTDF_n =
\begin{array}{c|ccc}
   & n_1 & n_2 & n_3 \\ \hline
l_1 & 0 & -0.6 & -0.2 \\
l_2 & 0 & \;\;0.4 & \;\;0.8 \\
l_3 & 0 & -0.4 & \;\;0.2
\end{array}
```

**Model check** — `dict_to_matrix(params.ptdf)`:

```julia
3×3 DenseAxisArray  (rows l1,l2,l3 — cols n1,n2,n3)
 0.0  -0.6  -0.2
 0.0   0.4   0.8
 0.0  -0.4   0.2
```

Matches. A unit injection at n2 withdrawn at the slack loads l1 by ``-0.6`` and l2 by
``+0.4``; the low-reactance line l2 carries the larger share.

## 3. GSK and zonal PTDF — design choice #1

A Generation Shift Key (GSK) maps a zonal net-position change onto nodes, so the zonal
PTDF is ``PTDF_z = PTDF_n \cdot GSK``. Zone Z1 has a single node, so its column is trivially
``[1]``. Zone Z2 = {n2, n3} is where the choice bites:

| GSK | weight n2 | weight n3 | rationale |
|-----|-----------|-----------|-----------|
| [`FlatGSK`](@ref)     | 0.5 | 0.5 | equal split |
| [`DispOnlyGSK`](@ref) | 0.0 | 1.0 | only dispatchable capacity (coal at n3); wind at n2 excluded |

Applying ``PTDF_z[\,\cdot\,,Z2] = w_{n_2}\,PTDF_n[\,\cdot\,,n_2] + w_{n_3}\,PTDF_n[\,\cdot\,,n_3]``:

```math
\underbrace{\begin{array}{c|c} & Z2 \\ \hline
l_1 & -0.4 \\ l_2 & \;\;0.6 \\ l_3 & -0.1 \end{array}}_{\text{Flat}}
\qquad\qquad
\underbrace{\begin{array}{c|c} & Z2 \\ \hline
l_1 & -0.2 \\ l_2 & \;\;0.8 \\ l_3 & \;\;0.2 \end{array}}_{\text{DispOnly}}
```

The two are qualitatively different: on l3 the sensitivity **changes sign** (``-0.1`` vs
``+0.2``), and on the critical line l2 it jumps from ``0.6`` to ``0.8`` — a 33 % tighter
mapping of Z2's net position onto the congested line. Because DispOnly places all of Z2's
marginal injection at n3 (where the flexible coal actually sits), it is the physically
honest choice for this fleet, and it is what the rest of this page uses.

**Model check** — `build_gsk(params, DispOnlyGSK())` then `zonal_ptdf(PTDFn, GSK)`:

```julia
GSK (n×z):          zonal PTDF (l×z):
 1.0  0.0            0.0  -0.2
 0.0  0.0            0.0   0.8
 0.0  1.0            0.0   0.2
```

The zone-to-zone PTDF (`zone_to_zone_ptdf`) is the column difference
``PTDF_{zz}[l,(z_{ex},z_{im})]=PTDF_z[l,z_{im}]-PTDF_z[l,z_{ex}]``; it drives the CNE
selection (`define_cne!`, threshold 0.05, keeping lines with an endpoint in the
flow-based region). Here all three lines qualify.

## 4. Stage 1 — the forecast run (reference pool)

The reference-day method needs a pool of already-solved nodal snapshots. A first
"forecast" run — a plain flow-based run with an [`OptimizationBasecase`](@ref) — provides
it. Its `TwoDayAhead` (`"2DA"`) tables give the nodal `ACINJECTION` we borrow from:

```julia
setup_forecast = ModelSetup(;
    TimeHorizon     = TimeHorizon(stop = 4),
    MarketType      = ZonalMarket(FlowBased(DispOnlyGSK())),
    RedispatchSetup = DCLF(PhaseAngle))
POMATWO.run(ModelRun(params, setup_forecast, solver; scenarioname="forecast", ...))
ref = DataFiles(joinpath(output_path, "forecast"); type = "2DA")
```

The resulting nodal injections (``INJ_{ac}``, MW) — our reference pool:

| node | ``t_1`` | ``t_2`` | ``t_3`` | ``t_4`` |
|------|-----|-----|-----|-----|
| n1   | 60  | 60  | 60  | 50  |
| n2   | −20 | −20 | −20 | 0   |
| n3   | −40 | −40 | −40 | −50 |

## 5. Stage 2a — matching

The horizon is split into day-clusters of `cluster_size = 2`, giving **c₁ = {t₁, t₂}** and
**c₂ = {t₃, t₄}**. Matching compares clusters using **only the renewable generation** as
the similarity signal (wind + solar), aggregated per cluster with the statistics
``\{\text{median}, \text{maximum}\}`` and compared with a **weighted L1 (Manhattan)
distance**:

```math
d(c,c') = \sum_{k \in \text{keys}} \sum_{s \in \{\text{med},\max\}}
          w_{s} \,\bigl| \mathrm{stat}_s(c,k) - \mathrm{stat}_s(c',k) \bigr|
```

With `scope = ZonalMatchScope()` each zone matches independently (per-TSO D2CF). The
renewable frame:

| plant | node | zone | ``c_1`` GEN | ``c_2`` GEN | median ``c_1{,}c_2`` | max ``c_1{,}c_2`` |
|-------|------|------|-------------|-------------|----------------------|-------------------|
| p3 wind | n2 | Z2 | 50, 50 | 50, 30 | 50, 40 | 50, 50 |
| p2 solar| n1 | Z1 | 80, 80 | 80, 16 | 80, 48 | 80, 80 |

so (unit weights):

```math
d_{Z2}(c_1,c_2) = |50-40| + |50-50| = 10, \qquad
d_{Z1}(c_1,c_2) = |80-48| + |80-80| = 32,
```

and the global distance is their sum, ``42``. With `lookback = 1` and two cyclic clusters,
each cluster's only candidate is the other one, so **c₁ ↔ c₂** in every zone. Matching
positions within a cluster in order maps target times ``t_1{\to}t_3,\ t_2{\to}t_4,\
t_3{\to}t_1,\ t_4{\to}t_2``.

**Model check** — `match_by_scope(gen_df, ZonalMatchScope(), ref.params; ...)`:

```julia
 target_cluster  matched_cluster  target_time  matched_time  cluster_distance  group
        1               2              1             3              10.0         Z2
        2               1              3             1              10.0         Z2
        1               2              1             3              32.0         Z1
        2               1              3             1              32.0         Z1
```

The distances ``10`` (Z2) and ``32`` (Z1) match the hand calculation; the global fallback
(`match_by_cluster`) reports ``42``.

## 6. Stage 2b — the shift — design choice #2

For each target hour the reference-day injections are **warped** so the zone's net position
matches the target while renewables are pinned to the target. [`ShareShift`](@ref)
apportions the zonal net-position gap

```math
D(z) = NP_z^{\text{tgt}} - NP_z^{\text{cur}}
```

across components ``\{RES, conv, load, NP\}`` with shares ``\beta`` (here
``\beta_{conv}=\beta_{load}=0.5``), each spread to nodes by a redistribution key and
clipped to physical head-room; the unbounded ``NP`` component is applied last and therefore
**closes the gap exactly** (the *NP-closure invariant*). The `resolution` field decides the
granularity of ``D``:

- **`:nodal`** — the gap is computed and closed per node, so the output reproduces the
  target's own nodal injection exactly. The reference day contributes nothing beyond a
  seed.
- **`:zonal`** — the gap is computed per zone and redistributed across the zone's nodes
  (here by a `GSKRedist(DispOnlyGSK())` key). The reference day's intra-zonal texture
  survives, reshaped only enough to hit the zonal net position.

Both resolutions preserve the same zonal net position, but distribute it differently inside
Z2, which changes the line flows and hence the RAM.

**Model check** — `build_refday_basecase(bc, params)[:netinput_ac]`:

```
:zonal shift                         :nodal shift
      t1   t2   t3   t4                    t1   t2   t3   t4
 n1   60   60   60   50            n1      60   60   60   50
 n2  -20   20  -20  -40            n2     -20  -20  -20    0
 n3  -40  -80  -40  -10            n3     -40  -40  -40  -50
```

Read off ``t_2``: both give the Z2 sum ``NP`` (``20+(-80)=-60`` vs ``-20+(-40)=-60``) — the
invariant holds — but the **nodal** result equals the reference pool of §4 exactly, whereas
the **zonal** result has pushed injection from n3 onto n2. The line flows follow from
``F = PTDF_n \cdot INJ_{ac}``; e.g. zonal ``t_2``: ``F_{l2}=0.4(20)+0.8(-80)=-56`` against
nodal ``F_{l2}=0.4(-20)+0.8(-40)=-40``.

## 7. Reference flow ``F_0`` and RAM

From the basecase, RAM is built per critical line and direction. First the basecase zonal
net positions and the reference flow with the commercial exchange removed:

```math
NP_z = -\!\!\sum_{n \in z} INJ_{ac,n}, \qquad
F_{0,l} = F_l - \sum_z PTDF_{z}[l,z]\, NP_z
```

Then, with line limit ``f^{max}_l``, flow-reliability margin ``FRM`` and the minimum-RAM
share ``\lambda`` (the EU "70 % rule", `minRAM = 0.7`):

```math
\begin{aligned}
RAM^{pos}_l &= \max\!\bigl(f^{max}_l - F_{0,l} - FRM\, f^{max}_l,\;\; \lambda\, f^{max}_l\bigr) \\
RAM^{neg}_l &= \min\!\bigl(-f^{max}_l - F_{0,l} + FRM\, f^{max}_l,\;\; -\lambda\, f^{max}_l\bigr)
\end{aligned}
```

Worked for **l2** (``f^{max}=40``, ``FRM=0.1``, ``\lambda=0.7``) under the **:zonal**
basecase:

- ``t_1``: basecase ``INJ_{ac}=[60,-20,-40]``, ``F_{l2}=-40``, ``NP_{Z2}=60``.
  ``F_0 = -40 - 0.8(60) = -88``; ``RAM^{pos} = \max(40+88-4,\,28)=124``,
  ``RAM^{neg} = \min(-40+88+4,\,-28)=-28``.
- ``t_4``: basecase ``INJ_{ac}=[50,-40,-10]``, ``F_{l2}=-24``, ``NP_{Z2}=50``.
  ``F_0 = -24 - 0.8(50) = -64``; ``RAM^{pos} = \max(40+64-4,\,28)=100``.

**Model check** — `calc_fbmc_params(DispOnlyGSK(), params, base, 1:4)[:RAM]`, positive
direction:

```julia
:zonal basecase              :nodal basecase
       t1   t2   t3   t4              t1   t2   t3   t4
 l1    35   35   35   35       l1     35   35   35   35
 l2   124  140  124  100       l2    124  124  124  116
 l3    57   81   57   41       l3     57   57   57   65
```

The two basecases give **different RAM on l2 at ``t_4``: 100 (zonal) vs 116 (nodal)** — the
sole reason being how each distributed Z2's injection between n2 and n3. This single number
drives the market outcome below.

## 8. FBMC market clearing

The day-ahead zonal market prices energy against the flow-based domain. For each critical
line the net positions ``NP`` (import-positive) must satisfy

```math
RAM^{neg}_l \;\le\; -\sum_{z} PTDF_z[l,z]\, NP_z \;\le\; RAM^{pos}_l .
```

Merit order fills demand from wind/solar, then coal (30), then gas (50). For ``t_1{-}t_3``
demand is low and no line binds. The decisive hour is **``t_4``** (load 200, but RES down to
solar 16 + wind 30 = 46). Zone Z2 (coal at n3) is cheap and wants to export to Z1 (only
expensive gas at n1). The binding constraint on the export is l2:

```math
-PTDF_z[l_2,Z2]\,NP_{Z2} = -0.8\,NP_{Z2} \le RAM^{pos}_{l_2,t_4}.
```

- **:zonal basecase** (``RAM^{pos}_{l2}=100``): ``-0.8\,NP_{Z2}\le100 \Rightarrow
  NP_{Z2}\ge-125`` → Z2 export capped at **125 MW**. Z1's residual demand
  (``150-16=134``) cannot be fully imported, so **9 MW of gas** must run at n1.
- **:nodal basecase** (``RAM^{pos}_{l2}=116``): the cap loosens to ``145`` MW, the export is
  set instead by Z1's demand (134 MW), l2 does **not** bind, and **no gas** runs.

**Model check** — refday market `GEN`/`EXCHANGE` at ``t_4``:

| basecase | coal (n3) | gas (n1) | Z2 export | l2 binds? |
|----------|-----------|----------|-----------|-----------|
| :zonal   | 145       | **9**    | 125       | yes (=100) |
| :nodal   | 154       | **0**    | 134       | no         |

The zonal-shift basecase, by keeping the reference day's texture, produces a tighter RAM
that forces ``9\text{ MW} \times (50-30) = 180\ \text{EUR/h}`` of extra cost at ``t_4`` — a
purely methodological artefact, not a physical necessity. This is the concrete impact of a
basecase design choice, and a limitation to keep in mind.

## 9. Limitations and design-choice summary

- **GSK mismatch (§3).** The GSK is a linear stand-in for where a zone's injection actually
  lands. Flat vs DispOnly moved the l2 sensitivity from 0.6 to 0.8 and flipped l3's sign; a
  GSK that misrepresents the fleet mis-sizes every RAM.
- **Basecase resolution (§6–§8).** `:zonal` preserves the reference day but can create RAM
  (and cost) that `:nodal` — which reproduces the target exactly — does not. `:nodal` is
  more faithful to the target but discards the reference day's value; `:zonal` is the true
  D2CF-style forecast, with the modelling risk shown here.
- **``F_0`` is a linear reference flow (§7)** obtained by subtracting the commercial
  exchange via the *zonal* PTDF, not a re-solved AC/DC flow; its accuracy inherits every GSK
  and basecase approximation above.
- **Matching representativeness (§5).** On a 2-cluster horizon the match is forced; on real
  data the `lookback`, `exact_weekend`, `cluster_size`, weights and `scope` all steer which
  historical day is borrowed, and a poor match propagates into ``F_0`` and RAM.
- **Margins (§7).** `minRAM` (70 % rule) and `FRM` set how much of each line is offered to
  the market; here `minRAM` floored several RAM values (e.g. l1 at 35 = ``0.7\times50``)
  independently of the basecase.

## 10. Traceability

Runs configured with a `ReferenceDayBasecase` persist how the basecase was constructed,
next to the regular result tables:

| Table | Rows | Location |
|---|---|---|
| `REFDAY_MATCH` | one per (group, `target_time`): `matched_time`, `target_cluster`, `matched_cluster`, `cluster_distance`, `fallback::Bool` | each `subrun_*` folder, sliced by `target_time` |
| `REFDAY_GROUPS` | one per (group, node) — the matching scope's node membership | scenario root (time-independent) |
| `REFDAY_SHIFT` | sparse, one per (`Time`, node, component) with `delta` = applied net-injection change | each `subrun_*` folder, sliced by `Time` |

Conventions:

- `component ∈ {"RES_prestep", "RES", "conv", "load", "NP", "unabsorbed"}`. `delta` is
  always the change in **nodal net injection**; for `"load"` the actual load change is
  `-delta`. `"unabsorbed"` rows (zone label in the `node` column) flag gap remainders the
  component cascade could not place — nonzero only when `fallback_order` cannot close the
  gap.
- `fallback = true` marks hours where a scoped group borrowed the global fallback match;
  cluster metadata columns can be `missing` where a join found no counterpart.

Everything else is derivable — nothing is stored twice:

- per-node reference time: `REFDAY_GROUPS ⋈ REFDAY_MATCH` on `group`
  (convenience: [`refday_reference_times`](@ref));
- basecase injection: `netinput_ac[n, t] = P_source(n, ref(n, t)) + Σ REFDAY_SHIFT deltas(n, t)`,
  with `P_source` the forecast run's AC net injection (`NETINPUT.ACINJECTION`).

All three tables load automatically via `DataFiles(scen_dir)`; they are empty for runs
without a reference-day basecase.

## API reference

```@docs
BasecaseMethod
OptimizationBasecase
ReferenceDayBasecase
MatchingConfig
MatchScope
GlobalMatchScope
ZonalMatchScope
AreaMatchScope
ShiftMethod
ShareShift
RedistKey
GSKRedist
RefPropRedist
LoadPropRedist
DispOnlyGSK
match_by_cluster
match_by_scope
build_refday_basecase
refday_reference_times
calc_fbmc_params
POMATWO.zone_to_zone_ptdf
```
