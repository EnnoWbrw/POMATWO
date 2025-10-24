"""
    model_extensions.jl

Provides extension points and hooks for adding new market features,
configurations, and optimization components without modifying core code.
"""

"""
    ModelExtension

Abstract type for model extensions that can be added to the optimization.
"""
abstract type ModelExtension end

"""
    IntradayMarket <: ModelExtension

Extension for intraday market modeling (placeholder for future implementation).
"""
abstract type IntradayMarket <: ModelExtension end

"""
    SeasonalStorage <: ModelExtension

Extension for seasonal storage modeling (placeholder for future implementation).
"""
abstract type SeasonalStorage <: ModelExtension end

"""
    FlowBasedMarketCoupling <: ModelExtension

Extension for flow-based market coupling (placeholder for future implementation).
"""
abstract type FlowBasedMarketCoupling <: ModelExtension end

"""
    apply_extension!(subrun::SubRun, extension::ModelExtension)

Generic function to apply a model extension to a SubRun.
Implement methods for specific extension types.
"""
function apply_extension!(sr::SubRun, ext::ModelExtension)
    error("Extension $(typeof(ext)) not implemented yet")
end

"""
    ModelHooks

Collection of customizable hooks that can be used to inject custom logic
at various points in the model building process.
"""
Base.@kwdef mutable struct ModelHooks
    before_build::Vector{Function} = Function[]
    after_build::Vector{Function} = Function[]
    before_solve::Vector{Function} = Function[]
    after_solve::Vector{Function} = Function[]
    custom_constraints::Vector{Function} = Function[]
    custom_objectives::Vector{Function} = Function[]
end

"""
    register_hook!(hooks::ModelHooks, phase::Symbol, fn::Function)

Register a custom function to be called at a specific phase.

# Phases
- `:before_build`: Called before model construction
- `:after_build`: Called after model construction
- `:before_solve`: Called before optimization
- `:after_solve`: Called after optimization
- `:custom_constraints`: Called during constraint addition
- `:custom_objectives`: Called during objective function setup
"""
function register_hook!(hooks::ModelHooks, phase::Symbol, fn::Function)
    if phase == :before_build
        push!(hooks.before_build, fn)
    elseif phase == :after_build
        push!(hooks.after_build, fn)
    elseif phase == :before_solve
        push!(hooks.before_solve, fn)
    elseif phase == :after_solve
        push!(hooks.after_solve, fn)
    elseif phase == :custom_constraints
        push!(hooks.custom_constraints, fn)
    elseif phase == :custom_objectives
        push!(hooks.custom_objectives, fn)
    else
        error("Unknown hook phase: $phase")
    end
end

"""
    execute_hooks!(hooks::ModelHooks, phase::Symbol, args...)

Execute all registered hooks for a given phase.
"""
function execute_hooks!(hooks::ModelHooks, phase::Symbol, args...)
    hook_list = if phase == :before_build
        hooks.before_build
    elseif phase == :after_build
        hooks.after_build
    elseif phase == :before_solve
        hooks.before_solve
    elseif phase == :after_solve
        hooks.after_solve
    elseif phase == :custom_constraints
        hooks.custom_constraints
    elseif phase == :custom_objectives
        hooks.custom_objectives
    else
        error("Unknown hook phase: $phase")
    end
    
    for hook in hook_list
        hook(args...)
    end
end

"""
    ExtendedModelSetup

Extended model setup that includes hooks and extensions.
This allows users to customize model behavior without modifying core code.
"""
Base.@kwdef struct ExtendedModelSetup{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    base_setup::ModelSetup{MT, PS, RD}
    hooks::ModelHooks = ModelHooks()
    extensions::Vector{ModelExtension} = ModelExtension[]
    constraint_config::MarketConstraintConfig = MarketConstraintConfig()
    network_constraints::NetworkConstraints = NetworkConstraints()
end

"""
    ExtendedModelSetup(setup::ModelSetup; kwargs...)

Create an extended model setup from a base setup.
"""
function ExtendedModelSetup(
    setup::ModelSetup{MT, PS, RD};
    hooks::ModelHooks = ModelHooks(),
    extensions::Vector{ModelExtension} = ModelExtension[],
    constraint_config::MarketConstraintConfig = MarketConstraintConfig(),
    network_constraints::NetworkConstraints = NetworkConstraints(),
) where {MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    return ExtendedModelSetup{MT, PS, RD}(
        setup,
        hooks,
        extensions,
        constraint_config,
        network_constraints,
    )
end
