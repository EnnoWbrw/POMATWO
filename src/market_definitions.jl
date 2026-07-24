#Grid Formulations
abstract type LFFormulation end

abstract type DCLFFormulation <: LFFormulation end

"""
    PhaseAngle <: DCLFFormulation

DC load flow formulation based on phase angle differences between nodes.
"""
struct PhaseAngle <: DCLFFormulation end
struct PTDF       <: DCLFFormulation end

# Exchange Formulations
abstract type ExchangeFormulation end

"""
    NTC <: ExchangeFormulation

Net Transfer Capacity formulation. Represents fixed interzonal capacity limits.
"""
struct NTC <: ExchangeFormulation end

"""
    BasecaseMethod

Abstract supertype for the methodology that produces the FBMC basecase
(nodal net injections + line flows) from which zonal PTDFs, CNEs and RAM
are derived for a flow-based market run.

# Subtypes
- [`OptimizationBasecase`](@ref): solve the `TwoDayAhead` DC load-flow
  optimization as basecase (default, current behavior).
- [`ReferenceDayBasecase`](@ref): construct the basecase from a matched and
  shifted reference day of a previous ("forecast") model run, mimicking the
  D2CF process (defined in `utils/refday_basecase.jl`).
"""
abstract type BasecaseMethod end

"""
    OptimizationBasecase <: BasecaseMethod

Default basecase methodology: the `TwoDayAhead` DC load-flow optimization is
solved ahead of the day-ahead stage and its nodal injections/line flows feed
the FBMC parameter calculation.
"""
struct OptimizationBasecase <: BasecaseMethod end

"""
    FlowBased <: ExchangeFormulation

Flow-based market coupling formulation.

# Fields
- `GSKStrategy::GSKStrategy`: Generation Shift Key strategy (defaults to `FlatGSK()`).
- `basecase::BasecaseMethod`: Basecase methodology (defaults to
  [`OptimizationBasecase`](@ref); see [`ReferenceDayBasecase`](@ref) for the
  reference-day / D2CF-style alternative).

# Constructors
- `FlowBased()`: `FlatGSK()` + `OptimizationBasecase()`.
- `FlowBased(strategy::GSKStrategy)`: provided GSK strategy + `OptimizationBasecase()`.
- `FlowBased(; GSKStrategy = FlatGSK(), basecase = OptimizationBasecase())`: keyword form.
"""
struct FlowBased <: ExchangeFormulation
    GSKStrategy::GSKStrategy
    basecase::BasecaseMethod
end

FlowBased(s::GSKStrategy) = FlowBased(s, OptimizationBasecase())
# NOTE: no explicit zero-arg constructor — the all-defaults keyword method
# below already covers `FlowBased()`.
FlowBased(; GSKStrategy = FlatGSK(), basecase = OptimizationBasecase()) =
    FlowBased(GSKStrategy, basecase)

### MarketTypes
"""
    MarketType

Abstract supertype for market setup descriptors. Subtypes specify the market structure (zonal or nodal) and whether redispatch is considered.

# Subtypes
- [`ZonalMarket`](@ref): Zonal market with specified exchange formulation.
- [`NodalMarket`](@ref): Nodal market with specified load flow formulation.

These types are used to parameterize simulations or models, allowing code to dispatch on market design and redispatch handling.
"""
abstract type MarketType end

abstract type ZonalMarketType  <: MarketType end

"""
    ZonalMarket{XF<:ExchangeFormulation} <: ZonalMarketType

Zonal market definition parameterized by an exchange formulation.

# Fields
- `XF`: Type of the exchange formulation, e.g., `NTC` or `FlowBased`.
- `exchange_formulation`: Instance of the exchange formulation (for accessing configuration like GSKStrategy).

# Constructors
- `ZonalMarket()`: Uses `NTC()` as default.
- `ZonalMarket(FlowBased())`: Uses provided FlowBased instance with custom GSKStrategy.
"""
struct ZonalMarket{XF<:ExchangeFormulation} <: ZonalMarketType
    exchange_formulation::XF
    
    # Inner constructor
    ZonalMarket{XF}(xf::XF) where {XF<:ExchangeFormulation} = new{XF}(xf)
end

# Outer constructors
ZonalMarket() = ZonalMarket{NTC}(NTC())
ZonalMarket(xf::XF) where {XF<:ExchangeFormulation} = ZonalMarket{XF}(xf)

abstract type NodalMarketType <: MarketType end

"""
    NodalMarket{LF<:LFFormulation} <: NodalMarketType

Nodal market definition parameterized by a load flow formulation.

# Fields
- `LF`: Type of the load flow formulation, e.g., `PhaseAngle` or `PTDF`.

# Constructors
- `NodalMarket()`: Uses `PhaseAngle` as default.
- `NodalMarket(LF::Type{<:LFFormulation})`: Specify load flow formulation type.
"""
struct NodalMarket{LF<:LFFormulation} <: NodalMarketType end

NodalMarket() = NodalMarket{PhaseAngle}()
NodalMarket(::Type{LF}) where {LF<:LFFormulation} = NodalMarket{LF}()


"""
    ProsumerSetup

Abstract supertype for prosumer market participation models.
Subtypes specify whether and how prosumers are represented in the simulation.

# Subtypes
- [`NoProsumer`](@ref): No prosumers are modeled.
- [`ProsumerOptimization`](@ref): Prosumers are modeled with explicit optimization (variable sell/buy prices and retail tariff types).
"""
abstract type ProsumerSetup end

"""
    NoProsumer

Represents a market setup with no prosumer participation.
"""
struct NoProsumer <: ProsumerSetup end

"""
    ProsumerOptimization(; sell_price, buy_price=0, retail_type=:buy_price,
                           netzentgelte=250.0, self_discharge=0.999)

Represents a prosumer setup where prosumer actions are explicitly optimized with respect to market conditions.

!!! note "Units"
    All prices are **EUR/MWh**, the same unit as the marginal costs of every other
    technology. Earlier versions passed values such as `0.22` here while adding a hardcoded
    grid fee of `250`, mixing EUR/kWh with EUR/MWh.

# Keyword Arguments
- `sell_price::Float64`: Price (EUR/MWh) at which the prosumer sells electricity to the grid.
- `buy_price::Float64`: Price (EUR/MWh) the prosumer pays for electricity, used when
  `retail_type = :buy_price`. Defaults to `0`.
- `retail_type::Symbol`: Retail tariff structure, one of
  - `:buy_price` — the flat `buy_price` above,
  - `:flat` — the mean non-negative day-ahead price of the time span,
  - `:realtime` — the day-ahead price of each hour.
  Default is `:buy_price`.
- `netzentgelte::Float64`: Grid fee (EUR/MWh) added on top of the retail price for every
  MWh the prosumer buys. Defaults to `250.0`.
- `self_discharge::Float64`: Share of the prosumer storage level retained per hour, in
  `[0, 1]`. Defaults to `0.999`. Charging/discharging efficiency is *not* set here — it
  comes from the plant's `eta` in the input data.

An error is thrown if `retail_type` is not valid or `self_discharge` is outside `[0, 1]`.

# Example
```julia
ProsumerOptimization(sell_price = 80.0, buy_price = 250.0)
```
"""
struct ProsumerOptimization <: ProsumerSetup
    sell_price::Float64
    buy_price::Float64
    retail_type::Symbol
    netzentgelte::Float64
    self_discharge::Float64

    function ProsumerOptimization(;
        sell_price,
        buy_price = 0,
        retail_type::Symbol = :buy_price,
        netzentgelte::Real = 250.0,
        self_discharge::Real = 0.999,
    )

        if !(retail_type in [:buy_price, :flat, :realtime])
            error("retail_type must be one of [:buy_price, :flat, :realtime]")
        end
        if !(0 <= self_discharge <= 1)
            error("self_discharge must be between 0 and 1, got $self_discharge")
        end

        return new(sell_price, buy_price, retail_type, netzentgelte, self_discharge)
    end
end

abstract type RedispatchSetup end
abstract type RedispatchType <: RedispatchSetup end

"""
    DCLF{DCF<:DCLFFormulation} <: RedispatchType

Redispatch setup using a DC load flow formulation.

The cost fields are activation costs on redispatch volume, not fuel costs: the redispatch
stage minimizes the priced deviation from the day-ahead schedule. Non-dispatchable plants
are redispatched in both directions — `res_up_cost` prices the recall of energy that was
curtailed in the day-ahead (physically available, since `avail * gmax` already caps the
technical potential), `res_down_cost` prices additional curtailment.

# Fields
- `DCF`: DC load flow formulation type (e.g., `PhaseAngle`, `PTDF`).
- `disp_cost`: Cost per MWh of dispatchable up- or downward redispatch. Defaults to `150.0`.
- `res_up_cost`: Cost per MWh of recalled non-dispatchable generation. Defaults to `1.0`,
  i.e. near-free (no fuel is burnt), but nonzero so that recall only happens where it
  actually relieves a network constraint.
- `res_down_cost`: Cost per MWh of additional non-dispatchable curtailment. Defaults to `150.0`.
- `sto_cost`: Cost per MWh of storage up- or downward redispatch. Defaults to `150.0`.

# Constructors
- `DCLF()`: Uses `PhaseAngle` as default.
- `DCLF(DCF::Type{<:DCLFFormulation})`: User-defined formulation type.
- Both accept the cost fields as keyword arguments, e.g. `DCLF(PTDF; res_up_cost = 0.0)`.
"""
struct DCLF{DCF<:DCLFFormulation} <: RedispatchType
    disp_cost::Float64
    res_up_cost::Float64
    res_down_cost::Float64
    sto_cost::Float64
end

# 1) Null-Argument-Default: PhaseAngle
DCLF(; kwargs...) = DCLF(PhaseAngle; kwargs...)

# 2) Typgetriebener Convenience-Konstruktor
function DCLF(
    ::Type{DCF};
    disp_cost::Real = 150.0,
    res_up_cost::Real = 1.0,
    res_down_cost::Real = 150.0,
    sto_cost::Real = 150.0,
) where {DCF<:DCLFFormulation}
    return DCLF{DCF}(disp_cost, res_up_cost, res_down_cost, sto_cost)
end

"""
    NoRedispatch <: RedispatchSetup

Represents a setup without redispatch modeling.
"""
struct NoRedispatch <: RedispatchSetup end

### Storage boundary conditions
"""
    StorageBoundary

Abstract supertype for the storage-level boundary condition at the edges of each
time split. Determines what the storage level of the first hour of a split connects
to. Subtypes: [`CyclicStorage`](@ref) (default), [`CarryOverStorage`](@ref).
"""
abstract type StorageBoundary end

"""
    CarryOverStorage(; start_share = 0.0) <: StorageBoundary

Storage levels are carried over between time splits: the first hour of a split
starts from the level the storage had at the end of the previous split. In the
first split, the level starts at `start_share * storage_capacity`.

This is the physically consistent choice — energy cannot teleport between days.

!!! warning "End-of-split dumping"
    A split has no terminal value for stored energy: the optimizer has no incentive
    to keep energy for later splits and will discharge whatever is profitable before
    each split boundary. For day-cycling storages (batteries, pumped hydro) consider
    [`CyclicStorage`](@ref), or use splits long enough to cover the storage cycle.
"""
struct CarryOverStorage <: StorageBoundary
    start_share::Float64

    function CarryOverStorage(; start_share::Float64 = 0.0)
        0.0 <= start_share <= 1.0 ||
            error("start_share must be between 0 and 1, got $start_share")
        return new(start_share)
    end
end

"""
    CyclicStorage() <: StorageBoundary

The storage level is cyclic within every time split: the first hour of a split
connects to the level at the last hour of the same split. Splits stay fully
independent and no energy is dumped at split boundaries, but levels do not carry
over between splits — plausible for day-cycling storages, wrong for seasonal ones.

Storage inflows in the first hours of a split can exceed the storage capacity under
this boundary (the level wraps around full); use [`CarryOverStorage`](@ref) when
inflows are used to set initial levels.
"""
struct CyclicStorage <: StorageBoundary end


### MarketStates
"""
    MarketState

Abstract supertype for different temporal stages or submodels in market simulations (e.g., day-ahead, redispatch).
"""
abstract type MarketState end

"""
    DayAhead <: MarketState

Represents the day-ahead market stage.

# Fields
- `Time::UnitRange{Int}`: Time horizon covered by the day-ahead market model.
- `fbmc_params::Union{Dict,Nothing}`: Optional flow-based market coupling parameters (only used for FlowBased exchange formulation).

# Constructors
- `DayAhead(T::UnitRange{Int})`: Creates DayAhead without fbmc_params (for NTC and other formulations).
- `DayAhead(T::UnitRange{Int}, fbmc_params::Dict)`: Creates DayAhead with fbmc_params (for FlowBased formulation).
"""
struct DayAhead <: MarketState
    Time::UnitRange{Int}
    fbmc_params::Union{Dict,Nothing}
end

DayAhead(T::UnitRange{Int}) = DayAhead(T, nothing)

"""
    ProsumerOptimizationState <: MarketState

Represents the prosumer-specific optimization stage.

# Fields
- `Time::UnitRange{Int}`: Time steps for the optimization.
- `price::Any`: Price signal or structure used for prosumer optimization.
"""
struct ProsumerOptimizationState <: MarketState
    Time::UnitRange{Int}
    price::Any
end

"""
    Redispatch <: MarketState

Represents the redispatch stage after the day-ahead market.

# Fields
- `Time::UnitRange{Int}`: Time range for redispatch actions.
- `da_market_result::Dict`: Results from the day-ahead market used for redispatch.
"""
struct Redispatch <: MarketState
    Time::UnitRange{Int}
    da_market_result::Dict
end

"""
    TwoDayAhead <: MarketState
Represents a two-day-ahead market stage. Also referred to as base-case for flow-based markets.
# Fields
- `Time::UnitRange{Int}`: Time horizon for the two-day-ahead market.
"""
struct TwoDayAhead <: MarketState
    Time::UnitRange{Int}
end

### Result-file namespacing
#
# Every MarketState writes its result tables under its own filename prefix, so two stages
# of the same run can never overwrite each other (they did until this was introduced: a
# redispatch stage clobbered the day-ahead's NETINPUT/LINEFLOW/DCLINEFLOW).

"""
    result_prefix(state) -> String

Filename prefix namespacing one market state's result tables, e.g. `DayAhead_GEN.arrow`.

Derived from the state's type name, so a new [`MarketState`](@ref) subtype is covered
automatically and two states can never collide on the same prefix. Accepts a state
instance, a state type, or one of the legacy strings understood by
[`market_state_type`](@ref).
"""
result_prefix(::Type{MS}) where {MS<:MarketState} = string(nameof(MS))
result_prefix(ms::MarketState) = result_prefix(typeof(ms))
result_prefix(s::AbstractString) = result_prefix(market_state_type(s))

# Short strings that predate the per-state prefixes and are part of the public API:
# `DataFiles(dir; type = ...)` and `ReferenceDayBasecase(source_type = ...)`.
const MARKET_STATE_ALIASES = Dict{String,DataType}(
    "DA"     => DayAhead,
    "2DA"    => TwoDayAhead,
    "REDISP" => Redispatch,
)

"""
    market_state_type(s::AbstractString) -> DataType

Resolve a market-state name to its type. Accepts the canonical type name
(`"Redispatch"`, `"TwoDayAhead"`, ...) as well as the legacy short aliases
`"DA"`, `"2DA"` and `"REDISP"` (see [`MARKET_STATE_ALIASES`](@ref)).

Canonical names are resolved by lookup rather than from a table, so states added later
need no registration here.
"""
function market_state_type(s::AbstractString)
    T = trymarket_state_type(s)
    T === nothing && error(
        "Unknown market state \"$s\". Use a MarketState type name (e.g. \"DayAhead\", " *
        "\"Redispatch\") or one of the aliases $(sort(collect(keys(MARKET_STATE_ALIASES)))).")
    return T
end

"""
    trymarket_state_type(s::AbstractString) -> Union{DataType,Nothing}

Like [`market_state_type`](@ref) but returns `nothing` instead of throwing. Used to test
whether a filename fragment names a market state.
"""
function trymarket_state_type(s::AbstractString)
    haskey(MARKET_STATE_ALIASES, s) && return MARKET_STATE_ALIASES[s]
    sym = Symbol(s)
    if isdefined(@__MODULE__, sym)
        T = getfield(@__MODULE__, sym)
        T isa DataType && T <: MarketState && return T
    end
    return nothing
end