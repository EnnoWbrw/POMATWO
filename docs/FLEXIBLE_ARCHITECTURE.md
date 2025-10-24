# New Flexible Architecture (v0.2+)

POMATWO now includes a flexible, trait-based architecture that makes it significantly easier to extend the model with new market types, configurations, and features.

## What's New

### 1. Trait-Based Market Configuration
Query and configure market characteristics programmatically:

```julia
using POMATWO

setup = ModelSetup(
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)

# Query market configuration
scope = market_scope(typeof(setup.MarketType))  # Returns ZonalScope()
has_redisp = has_redispatch(typeof(setup))      # Returns true
has_prs = has_prosumer(typeof(setup))           # Returns false
```

### 2. Configurable Constraints
Enable or disable specific constraints:

```julia
# Customize constraint inclusion
config = MarketConstraintConfig(
    include_historical_generation = true,
    include_min_generation = true,
    include_ramping = false,            # Future feature
    include_unit_commitment = false     # Future feature
)

# Apply to extended setup
extended_setup = ExtendedModelSetup(setup; constraint_config=config)
```

### 3. Extension Hooks
Add custom logic without modifying core code:

```julia
# Define custom hooks
hooks = ModelHooks()

register_hook!(hooks, :before_build, function(args...)
    # Custom pre-processing
end)

register_hook!(hooks, :after_solve, function(args...)
    # Custom post-processing
end)

# Use in model
extended_setup = ExtendedModelSetup(setup; hooks=hooks)
```

### 4. Modular Extensions
Create reusable extensions:

```julia
# Define a custom extension
struct MyMarketFeature <: ModelExtension
    parameter1::Float64
end

# Implement extension behavior
function POMATWO.apply_extension!(sr::SubRun, ext::MyMarketFeature)
    # Add custom variables, constraints, objectives
    # to the SubRun sr
end

# Use extension
extensions = [MyMarketFeature(1.0)]
extended_setup = ExtendedModelSetup(setup; extensions=extensions)
```

## Backward Compatibility

**All existing code continues to work without any changes.** The new features are opt-in extensions that provide additional flexibility for advanced users.

## Benefits

- **Easier Extension**: Add new market types by implementing traits, not rewriting code
- **Less Code Duplication**: Unified balance equations across all market types
- **User Customization**: Extend model behavior via hooks without forking
- **Future Ready**: Architecture supports planned features (intraday, FBMC, seasonal storage)

## Documentation

- **Architecture Guide**: `docs/architecture/flexibility_improvements.md`
- **Implementation Details**: `IMPLEMENTATION_SUMMARY.md`
- **Working Example**: `examples/flexible_architecture_demo.jl`

## For Developers

### Adding a New Market Type (Old Way)
```julia
# Required modifying 4-5 files:
# 1. market_definitions.jl
# 2. energy_balances.jl
# 3. technologies.jl
# 4. solving.jl
# 5. Various helper files
```

### Adding a New Market Type (New Way)
```julia
# 1. Define type in market_definitions.jl
struct MyNewMarket <: MarketType end

# 2. Implement trait in market_traits.jl
market_scope(::Type{MyNewMarket}) = ZonalScope()

# Done! Existing infrastructure handles the rest
```

## Future Features Enabled

The new architecture makes these planned features much easier to implement:

1. **Intraday Markets**: Multi-gate simulation with updated forecasts
2. **Seasonal Storage**: Long-term storage optimization
3. **Flow-Based Market Coupling**: European-style FBMC
4. **Ramping Constraints**: Generation ramping limits
5. **Unit Commitment**: Binary commitment decisions
6. **N-1 Security**: Contingency analysis

## Learn More

See the full documentation in:
- `docs/architecture/flexibility_improvements.md` - Architecture overview
- `examples/flexible_architecture_demo.jl` - Working examples
- `IMPLEMENTATION_SUMMARY.md` - Technical details

## Questions?

The new architecture is designed to make POMATWO more flexible and easier to extend. If you have questions or suggestions, please open an issue on GitHub.
