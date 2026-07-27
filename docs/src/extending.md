# Extending POMATWO with custom components

POMATWO models are assembled from **components**. Each component owns one Plasmo
`OptiNode` in the subrun's optigraph and declares how it participates in the shared
energy balance. The built-in components (dispatchable generation, non-dispatchable
generation, storage, network, prosumers) use the same interface that is available
to you — so a custom technology, demand-response scheme, or coupling constraint can
be added **without editing any POMATWO source file**.

## The interface

Subtype `ModelComponent` and implement:

| Method | Required | Purpose |
|---|---|---|
| `POMATWO.label(c)::Symbol` | yes | Unique OptiNode label within a subrun. |
| `POMATWO.build!(c, sr)` | yes | Create variables/constraints/objective on `sr.vars[label(c)]`. |
| `POMATWO.injection(c, sr, scope, region, t)` | for balance participation | Contribution to the energy balance (see below). Defaults to `nothing`. |
| `POMATWO.collect_results!(c, sr)` | no | Push results into `sr.results` DataFrames. |
| `POMATWO.validate_component(c, params, setup)` | no | Return `Vector{String}` of input errors; a run aborts if non-empty. |

Register instances via the setup:

```julia
setup = ModelSetup(
    TimeHorizon = TimeHorizon(stop = 24),
    MarketType = ZonalMarket(),
    components = [MyComponent(...)],
)
```

## The energy balance and `BalanceScope`

The balance is not always nodal — its granularity is a trait of
`(MarketType, MarketState)`:

| Market type | Market state | Balance over |
|---|---|---|
| `ZonalMarket` | `DayAhead` | zones (`ZonalScope`) |
| `ZonalMarket{FlowBased}` | `TwoDayAhead` basecase | nodes (`NodalScope`) |
| `NodalMarket` | `DayAhead` | nodes (`NodalScope`) |
| any | `Redispatch` | nodes (`NodalScope`) |

`injection(c, sr, scope, region, t)` is called with the scope the balance runs at:
`region` is a node name under `NodalScope` and a zone name under `ZonalScope`.
Return an `AffExpr`/`VariableRef` (built from your component's variables), or
`nothing` when the component does not inject at that region/time.

**Sign convention:** positive = supply, negative = demand.

Implement the nodal method at minimum. If your component should also participate in
zonal day-ahead balances, implement the `ZonalScope` method too (map your nodes to
zones via `sr.modelrun.params.node2zone`). A missing method for a scope/market-state
combination simply means the component is absent from that balance.

Market-state-specific behaviour (e.g. different variables in redispatch) is
expressed by dispatching on the subrun's state parameter:

```julia
function POMATWO.injection(c::MyComponent, sr::POMATWO.SubRun{MT,PS,RD,MS},
        ::POMATWO.NodalScope, n, t) where {MT<:MarketType,PS<:ProsumerSetup,
                                           RD<:RedispatchSetup,MS<:DayAhead}
    ...
end
```

!!! warning "Bound your type variables"
    When dispatching on `SubRun{MT,PS,RD,MS}`, always write the bounds
    (`MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup`) explicitly.
    With unbounded variables, Julia's method-specificity ranking can prefer a
    generic fallback over your method.

## Custom input data

Load your component's data into `params.extra[label]`:

```julia
params = load_data(data_files)
params.extra[:battery_fleet] = CSV.read("battery_fleet.csv", DataFrame)
```

and read it in `build!` via `sr.modelrun.params.extra`. Use `validate_component`
to check it before the run starts.

## Worked example: a fixed must-run feed-in

A minimal component that injects a constant feed-in at one node (the same component
is used as the acceptance test in `test/test_cases/test_custom_component.jl`):

```julia
using POMATWO

struct FixedInjector <: POMATWO.ModelComponent
    node::String
    mw::Float64
end

POMATWO.label(::FixedInjector) = :fixed_injector
POMATWO.build!(::FixedInjector, sr) = nothing   # no own variables needed

POMATWO.injection(c::FixedInjector, sr, ::POMATWO.NodalScope, n, t) =
    n == c.node ? POMATWO.AffExpr(c.mw) : nothing

POMATWO.injection(c::FixedInjector, sr, ::POMATWO.ZonalScope, z, t) =
    sr.modelrun.params.node2zone[c.node] == z ? POMATWO.AffExpr(c.mw) : nothing

function POMATWO.validate_component(c::FixedInjector, params, setup)
    errs = String[]
    c.node in params.sets.N || push!(errs, "node $(c.node) not in node set")
    return errs
end

setup = ModelSetup(
    TimeHorizon = TimeHorizon(stop = 24),
    MarketType = ZonalMarket(),
    components = [FixedInjector("n1", 10.0)],
)
```

A component with its own decision variables would create them in `build!` on its
node — including a node-local `@objective` (set it **once**; `@objective` replaces
rather than adds) — and return variable expressions from `injection`.

## Worked example: capacity expansion

Investment decisions fit the same pattern — a candidate unit with an investment
variable and generation limited by it (full version incl. results collection in
`test/test_cases/test_custom_component.jl`):

```julia
struct CandidateUnit <: POMATWO.ModelComponent
    node::String
    invest_cost::Float64
    mc::Float64
end

POMATWO.label(::CandidateUnit) = :candidate

function POMATWO.build!(c::CandidateUnit, sr)
    m = sr.vars[:candidate]
    T = sr.market_state.Time
    @variable(m, 0 <= CAP)
    @variable(m, 0 <= GEN[t = T])
    @constraint(m, [t = T], GEN[t] <= CAP)
    @objective(m, Min, c.invest_cost * CAP + c.mc * sum(GEN[t] for t in T))
end

POMATWO.injection(c::CandidateUnit, sr, ::POMATWO.NodalScope, n, t) =
    n == c.node ? sr.vars[:candidate][:GEN][t] : nothing
```

!!! warning "Investment variables and time splits"
    The model is solved per time split (`TimeHorizon.split`, default 24 h) and each
    split builds a fresh model. An investment variable is therefore only consistent
    **within one split**. For capacity-expansion studies use a single split covering
    the full horizon: `TimeHorizon(stop = 8760, split = 8760)`.

To expand *existing* plants instead of greenfield candidates, prefer a candidate
unit at the same node over mutating the built-in components' variable bounds —
user components are built after the built-ins, so `set_upper_bound` on
`sr.vars[:disp][:GEN][p, t]` works, but couples your component to internals.

## How a subrun is assembled

For every market state, `SubRun`:

1. collects `components(setup, market_state)` — the built-ins plus `setup.components`;
2. creates one OptiNode per component (plus the `:balance` node);
3. calls `build!` on every component;
4. creates the generic energy-balance link constraint (`link_balance`), summing all
   component `injection`s per region and timestep;
5. calls `collect_results!` on every component.

The sequence of market states per time split (day-ahead, prosumer, redispatch,
flow-based basecase) is defined by `state_sequence(setup)`; the data flow between
states is handled by `init_state` and `postprocess!` — all three dispatch on the
existing `MarketState` types and can be extended the same way.

## API reference

```@docs
ModelComponent
POMATWO.label
build!
injection
collect_results!
validate_component
BalanceScope
NodalScope
ZonalScope
balance_scope
state_sequence
POMATWO.init_state
POMATWO.postprocess!
POMATWO.link_balance
POMATWO.components
MarketState
DayAhead
TwoDayAhead
ProsumerOptimizationState
Redispatch
```
