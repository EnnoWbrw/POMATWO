"""
    market_traits.jl

This module provides trait-based interfaces for market configurations,
enabling flexible extension of market types and configurations without
modifying core model logic.
"""

# Market Traits for flexible dispatch
"""
    MarketScope

Trait to identify the spatial scope of market clearing.
"""
abstract type MarketScope end

"""
    ZonalScope <: MarketScope

Markets cleared at the zonal level.
"""
struct ZonalScope <: MarketScope end

"""
    NodalScope <: MarketScope

Markets cleared at the nodal level.
"""
struct NodalScope <: MarketScope end

"""
    market_scope(::Type{<:MarketType}) -> MarketScope

Returns the market scope trait for a given market type.
Enables dispatch based on whether market is zonal or nodal.
"""
market_scope(::Type{<:ZonalMarketType}) = ZonalScope()
market_scope(::Type{<:NodalMarketType}) = NodalScope()

"""
    has_redispatch(::Type{<:ModelSetup}) -> Bool

Returns true if the model setup includes redispatch optimization.
"""
has_redispatch(::Type{ModelSetup{MT,PS,RD}}) where {MT,PS,RD<:RedispatchType} = true
has_redispatch(::Type{ModelSetup{MT,PS,RD}}) where {MT,PS,RD<:NoRedispatch} = false

"""
    has_prosumer(::Type{<:ModelSetup}) -> Bool

Returns true if the model setup includes prosumer optimization.
"""
has_prosumer(::Type{ModelSetup{MT,PS,RD}}) where {MT,PS<:ProsumerOptimization,RD} = true
has_prosumer(::Type{ModelSetup{MT,PS,RD}}) where {MT,PS<:NoProsumer,RD} = false

"""
    balance_spatial_unit(::MarketScope, ::Parameters) -> Vector{String}

Returns the spatial units over which balance equations are defined.
For zonal markets, returns zones; for nodal markets, returns nodes.
"""
balance_spatial_unit(::ZonalScope, params::Parameters) = params.sets.Z
balance_spatial_unit(::NodalScope, params::Parameters) = params.sets.N

"""
    balance_unit_name(::MarketScope) -> Symbol

Returns the name identifier for balance units.
"""
balance_unit_name(::ZonalScope) = :Zone
balance_unit_name(::NodalScope) = :Node

"""
    network_injection_expr(::MarketScope, subrun, location, time)

Returns the network injection expression for a given location and time.
Different for zonal vs nodal markets.
"""
network_injection_expr(::ZonalScope, sr::SubRun, z, t) = sr.network[:EXCHANGE][z, t]
network_injection_expr(::NodalScope, sr::SubRun, n, t) = sr.network[:NETINPUT][n, t]

"""
    MarketConstraintConfig

Configuration object that specifies which constraints to include in the model.
Provides a flexible way to enable/disable model features.
"""
Base.@kwdef struct MarketConstraintConfig
    include_historical_generation::Bool = true
    include_min_generation::Bool = true
    include_storage_balance::Bool = true
    include_line_limits::Bool = true
    include_ramping::Bool = false
    include_unit_commitment::Bool = false
end

"""
    get_constraint_config(::ModelSetup) -> MarketConstraintConfig

Returns the constraint configuration for a model setup.
Can be extended to support setup-specific configurations.
"""
get_constraint_config(::ModelSetup) = MarketConstraintConfig()
