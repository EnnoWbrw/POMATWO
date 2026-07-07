### Component extension interface
#
# A ModelComponent owns one Plasmo OptiNode and declares how it plugs into the
# shared energy balance. Users extend POMATWO by subtyping ModelComponent and
# implementing `label`, `build!` and `injection` — without editing core files.
# Components are registered via `ModelSetup(; components = [...])`.

"""
    ModelComponent

Abstract supertype for all model components. A component owns one `OptiNode` in the
`SubRun`'s optigraph and contributes to the energy balance via [`injection`](@ref).

To add a custom component, subtype `ModelComponent` and implement:

- `POMATWO.label(c)::Symbol` — unique node label (required).
- `POMATWO.build!(c, sr)` — create variables/constraints/objective on `sr.vars[label(c)]` (required).
- `POMATWO.injection(c, sr, scope, region, t)` — contribution to the energy balance at
  `region` and time `t`; return an `AffExpr`/`VariableRef`, or `nothing` if the component
  does not inject there (required for balance participation; defaults to `nothing`).
- `POMATWO.collect_results!(c, sr)` — push results into `sr.results` (optional).
- `POMATWO.validate_component(c, params, setup)` — return a `Vector{String}` of error
  messages checked before a run (optional).

Sign convention: positive `injection` = supply at the region; demand-like components
return negative expressions.

See `docs/src/extending.md` for a worked example.
"""
abstract type ModelComponent end

"""
    label(c::ModelComponent) -> Symbol

Unique label of the component's OptiNode within a `SubRun`. Must be implemented by
every component.
"""
function label end

"""
    build!(c::ModelComponent, sr) -> Union{OptiNode,Nothing}

Build the component's variables, constraints and (node-local) objective on its
OptiNode (`sr.vars[label(c)]`). Called once during `SubRun` construction. Set the
node objective **once** — `@objective` replaces rather than adds.
"""
function build! end

"""
    injection(c::ModelComponent, sr, scope::BalanceScope, region, t)

Contribution of component `c` to the energy balance at `region` (a node name for
`NodalScope`, a zone name for `ZonalScope`) and time `t`. Return an `AffExpr` /
`VariableRef` (positive = supply), or `nothing` when the component does not
participate at that region/time. Default: `nothing`.
"""
injection(::ModelComponent, sr, scope, region, t) = nothing

"""
    collect_results!(c::ModelComponent, sr)

Push the component's variables/expressions into `sr.results` DataFrames after the
model is built. Default: no-op. (The built-in components currently populate results
inside `build!`; custom components may use either place.)
"""
collect_results!(::ModelComponent, sr) = nothing

"""
    validate_component(c::ModelComponent, params, setup) -> Vector{String}

Validate the input data this component needs. Return a vector of error messages
(empty = valid). Called by `run` before solving.
"""
validate_component(::ModelComponent, params, setup) = String[]

### Balance scope
#
# The energy balance is not always nodal: zonal day-ahead markets balance per zone,
# while the flow-based basecase (TwoDayAhead), nodal markets, and redispatch always
# balance per node. The scope is a trait of (MarketType, MarketState).

"""
    BalanceScope

Trait describing the regional granularity of the energy balance.
Subtypes: [`NodalScope`](@ref), [`ZonalScope`](@ref).
"""
abstract type BalanceScope end

"""
    NodalScope <: BalanceScope

Energy balance per node (`sets.N`). Used for nodal markets, the flow-based
TwoDayAhead basecase, and every redispatch stage.
"""
struct NodalScope <: BalanceScope end

"""
    ZonalScope <: BalanceScope

Energy balance per zone (`sets.Z`). Used for zonal day-ahead markets.
"""
struct ZonalScope <: BalanceScope end

"""
    balance_scope(mt::MarketType, ms::MarketState) -> BalanceScope

Scope of the energy balance for the given market type and market state.
"""
balance_scope(::ZonalMarketType, ::DayAhead) = ZonalScope()
balance_scope(::MarketType, ::MarketState) = NodalScope()

### Built-in components
#
# These wrap the existing builder functions (add_disp_generators, add_storage, …).
# The `members` dict caches region → member-plant lists so the balance loop does not
# recompute set intersections per (region, t).

"""Built-in component: dispatchable generation (wraps `add_disp_generators`)."""
struct DispatchableGen <: ModelComponent
    members::Dict{String,Vector{String}}
end
DispatchableGen() = DispatchableGen(Dict{String,Vector{String}}())
label(::DispatchableGen) = :disp

"""Built-in component: non-dispatchable generation (wraps `add_ndisp_generators`)."""
struct NonDispatchableGen <: ModelComponent
    members::Dict{String,Vector{String}}
end
NonDispatchableGen() = NonDispatchableGen(Dict{String,Vector{String}}())
label(::NonDispatchableGen) = :ndisp

"""Built-in component: storage units (wraps `add_storage`)."""
struct StorageComp <: ModelComponent
    members::Dict{String,Vector{String}}
end
StorageComp() = StorageComp(Dict{String,Vector{String}}())
label(::StorageComp) = :sto

"""Built-in component: grid / exchange representation (wraps `add_network`)."""
struct NetworkComp <: ModelComponent end
label(::NetworkComp) = :network

"""Built-in component: prosumers (wraps `add_prosumer`)."""
struct ProsumerComp <: ModelComponent
    members::Dict{String,Vector{String}}
end
ProsumerComp() = ProsumerComp(Dict{String,Vector{String}}())
label(::ProsumerComp) = :prosumer

# Function stubs whose methods are defined after SubRun/ModelSetup exist
# (energy_balances.jl): `components`, `link_balance`, `regions`, `balance_load`.
function components end
function link_balance end
function regions end
function balance_load end
