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
struct FlowBased <: ExchangeFormulation end

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

# Constructors
- `ZonalMarket()`: Uses `NTC` as default.
- `ZonalMarket(XF::Type{<:ExchangeFormulation})`: Specify exchange formulation type.
"""
struct ZonalMarket{XF<:ExchangeFormulation} <: ZonalMarketType end

ZonalMarket() = ZonalMarket{NTC}()
ZonalMarket(::Type{XF}) where {XF<:ExchangeFormulation} = ZonalMarket{XF}()

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
"""
struct DayAhead <: MarketState
    Time::UnitRange{Int}
end

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