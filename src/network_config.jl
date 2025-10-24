"""
    network_config.jl

Provides modular network configuration and formulation selection,
decoupling network topology from market clearing logic.
"""

"""
    NetworkFormulation

Abstract type for network formulations that can be composed with market types.
"""
abstract type NetworkFormulation end

"""
    DCPowerFlow <: NetworkFormulation

DC power flow network formulation using phase angles or PTDF.
"""
struct DCPowerFlow{F<:DCLFFormulation} <: NetworkFormulation
    formulation::Type{F}
end

DCPowerFlow() = DCPowerFlow{PhaseAngle}(PhaseAngle)
DCPowerFlow(::Type{F}) where {F<:DCLFFormulation} = DCPowerFlow{F}(F)

"""
    ZonalExchange <: NetworkFormulation

Zonal exchange formulation using NTC or flow-based.
"""
struct ZonalExchange{E<:ExchangeFormulation} <: NetworkFormulation
    exchange_type::Type{E}
end

ZonalExchange() = ZonalExchange{NTC}(NTC)
ZonalExchange(::Type{E}) where {E<:ExchangeFormulation} = ZonalExchange{E}(E)

"""
    get_network_formulation(::MarketType) -> NetworkFormulation

Returns the appropriate network formulation for a market type.
"""
get_network_formulation(::NodalMarket{LF}) where {LF<:DCLFFormulation} = DCPowerFlow{LF}(LF)
get_network_formulation(::ZonalMarket{XF}) where {XF<:ExchangeFormulation} = ZonalExchange{XF}(XF)

"""
    NetworkConstraints

Collection of network-related constraints that can be added to the model.
"""
Base.@kwdef struct NetworkConstraints
    line_limits::Bool = true
    voltage_limits::Bool = false
    n_1_security::Bool = false
    ramping_limits::Bool = false
end

"""
    apply_network_constraints!(subrun, formulation, constraints)

Applies network constraints based on formulation and constraint configuration.
"""
function apply_network_constraints!(
    sr::SubRun,
    formulation::DCPowerFlow,
    constraints::NetworkConstraints,
)
    if constraints.line_limits
        apply_dc_line_limits!(sr)
    end
    # Additional constraint types can be added here as the model evolves
end

function apply_network_constraints!(
    sr::SubRun,
    formulation::ZonalExchange,
    constraints::NetworkConstraints,
)
    # NTC limits are inherently included in the exchange formulation
    # Additional zonal constraints can be added here
end

"""
    apply_dc_line_limits!(sr)

Helper function to apply DC line limit constraints.
Called by network constraint application logic.
"""
function apply_dc_line_limits!(sr::SubRun)
    # Line limits are already applied in add_dclf
    # This is a placeholder for additional line limit logic
    # that might be added in future extensions
end
