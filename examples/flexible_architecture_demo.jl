"""
Example: Using the New Flexible Architecture

This example demonstrates how to use the new trait-based architecture
and extension system in POMATWO.
"""

using POMATWO
using HiGHS

# Example 1: Query Market Configuration
# =====================================

setup = ModelSetup(
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

# Query market characteristics using the new trait system
println("Example 1: Querying Market Configuration")
println("="^50)

# Get market scope (ZonalScope or NodalScope)
scope = POMATWO.market_scope(typeof(setup.MarketType))
println("Market Scope: ", typeof(scope))

# Check if setup includes redispatch
has_redisp = POMATWO.has_redispatch(typeof(setup))
println("Has Redispatch: ", has_redisp)

# Check if setup includes prosumers
has_prs = POMATWO.has_prosumer(typeof(setup))
println("Has Prosumer: ", has_prs)

println()

# Example 2: Configure Custom Constraints
# =======================================

println("Example 2: Custom Constraint Configuration")
println("="^50)

# Create a custom constraint configuration
constraint_config = MarketConstraintConfig(
    include_historical_generation = true,
    include_min_generation = true,
    include_storage_balance = true,
    include_line_limits = true,
    include_ramping = false,  # Future feature
    include_unit_commitment = false  # Future feature
)

println("Constraint Configuration:")
println("  Historical Generation: ", constraint_config.include_historical_generation)
println("  Min Generation: ", constraint_config.include_min_generation)
println("  Storage Balance: ", constraint_config.include_storage_balance)
println("  Line Limits: ", constraint_config.include_line_limits)

println()

# Example 3: Network Configuration
# ================================

println("Example 3: Network Formulation Configuration")
println("="^50)

# Configure network constraints
network_constraints = NetworkConstraints(
    line_limits = true,
    voltage_limits = false,  # Future feature
    n_1_security = false,    # Future feature
    ramping_limits = false   # Future feature
)

println("Network Constraints:")
println("  Line Limits: ", network_constraints.line_limits)
println("  Voltage Limits: ", network_constraints.voltage_limits)
println("  N-1 Security: ", network_constraints.n_1_security)

println()

# Example 4: Using Extension System (Advanced)
# ============================================

println("Example 4: Extension System")
println("="^50)

# Create model hooks for custom behavior
hooks = ModelHooks()

# Register a custom hook that runs before model build
# (This is a placeholder - actual implementation would add constraints/variables)
POMATWO.register_hook!(hooks, :before_build, function(args...)
    println("  Custom hook: Before model build")
    # Custom logic would go here
end)

# Register a custom hook that runs after solve
POMATWO.register_hook!(hooks, :after_solve, function(args...)
    println("  Custom hook: After solve")
    # Custom post-processing would go here
end)

# Create an extended model setup with hooks
extended_setup = ExtendedModelSetup(
    setup;
    hooks = hooks,
    constraint_config = constraint_config,
    network_constraints = network_constraints
)

println("Extended Setup Created:")
println("  Base Market Type: ", typeof(extended_setup.base_setup.MarketType))
println("  Number of Hooks: ", 
    length(extended_setup.hooks.before_build) + 
    length(extended_setup.hooks.after_solve))

println()

# Example 5: Adding a Custom Extension (Conceptual)
# ================================================

println("Example 5: Custom Extensions (Conceptual)")
println("="^50)

# Define a custom extension type (this would be in user code)
# struct MyCustomMarketFeature <: ModelExtension
#     parameter1::Float64
#     parameter2::String
# end
# 
# Then implement:
# function POMATWO.apply_extension!(sr::SubRun, ext::MyCustomMarketFeature)
#     # Add custom variables, constraints, objectives
#     # to the subrun sr
# end

println("Custom extensions can be defined by:")
println("  1. Creating a subtype of ModelExtension")
println("  2. Implementing apply_extension! method")
println("  3. Adding to ExtendedModelSetup")
println()
println("This allows extending the model without modifying core code!")

println()
println("="^50)
println("✅ All examples completed successfully!")
println("="^50)

# Note: To actually run a model, you would need:
# - Load data: params = load_data(data_files)
# - Create ModelRun: mr = ModelRun(params, setup, solver)
# - Execute: run(mr)
