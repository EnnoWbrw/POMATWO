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
    FlowBased <: ExchangeFormulation

Flow-based market coupling formulation.

# Fields
- `GSKStrategy::GSKStrategy`: Generation Shift Key strategy (defaults to `FlatGSK()`).

# Constructors
- `FlowBased()`: Uses `FlatGSK()` as default.
- `FlowBased(strategy::GSKStrategy)`: Uses provided GSK strategy.
"""
struct FlowBased <: ExchangeFormulation 
    GSKStrategy::GSKStrategy
end

FlowBased() = FlowBased(FlatGSK())

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
    ProsumerOptimization(; sell_price, buy_price=0, retail_type=:buy_price)

Represents a prosumer setup where prosumer actions are explicitly optimized with respect to market conditions.

# Keyword Arguments
- `sell_price::Float64`: Price at which the prosumer can sell electricity to the market or grid.
- `buy_price::Float64`: Price at which the prosumer buys electricity from the market/grid. Defaults to `0`.
- `retail_type::Symbol`: Retail tariff structure. Must be one of `:buy_price`, `:flat`, or `:realtime`. Default is `:buy_price`.

An error is thrown if `retail_type` is not valid.

# Example
```julia
ProsumerOptimization(sell_price=0.12, buy_price=0.22)
```
"""
struct ProsumerOptimization <: ProsumerSetup
    sell_price::Float64
    buy_price::Float64
    retail_type::Symbol

    function ProsumerOptimization(;
        sell_price,
        buy_price = 0,
        retail_type::Symbol = :buy_price,
    )

        if !(retail_type in [:buy_price, :flat, :realtime])
            error("retail_type must be one of [:buy_price, :flat, :realtime]")
        end

        return new(sell_price, buy_price, retail_type)
    end
end

abstract type RedispatchSetup end
abstract type RedispatchType <: RedispatchSetup end

"""
    DCLF{DCF<:DCLFFormulation} <: RedispatchType

Redispatch setup using a DC load flow formulation.

# Fields
- `DCF`: DC load flow formulation type (e.g., `PhaseAngle`, `PTDF`).

# Constructors
- `DCLF()`: Uses `PhaseAngle` as default.
- `DCLF(DCF::Type{<:DCLFFormulation})`: User-defined formulation type.
"""
struct DCLF{DCF<:DCLFFormulation} <: RedispatchType end

# 1) Null-Argument-Default: PhaseAngle
DCLF() = DCLF{PhaseAngle}()

# 2) Typgetriebener Convenience-Konstruktor
DCLF(::Type{DCF}) where {DCF<:DCLFFormulation} = DCLF{DCF}()

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