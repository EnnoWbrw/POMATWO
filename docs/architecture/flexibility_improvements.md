# Model Structure Flexibility Improvements

## Overview

This document describes the architectural improvements made to POMATWO to increase flexibility for adding and expanding different market options and configurations.

## Key Improvements

### 1. Market Traits System (`market_traits.jl`)

**Purpose**: Provides trait-based interfaces for market configurations, enabling flexible extension without modifying core code.

**Key Features**:
- `MarketScope` traits (`ZonalScope`, `NodalScope`) for spatial market differentiation
- `market_scope()` function for trait-based dispatch
- `has_redispatch()` and `has_prosumer()` query functions
- `balance_spatial_unit()` and `network_injection_expr()` for unified access patterns
- `MarketConstraintConfig` for flexible constraint configuration

**Benefits**:
- Type-stable dispatch on market characteristics
- Easy to add new market scopes without touching existing code
- Unified interface for querying model capabilities

### 2. Unified Balance Framework (`unified_balance.jl`)

**Purpose**: Single parameterized implementation of energy balance equations that works across all market types.

**Key Features**:
- `create_unified_balance!()` replaces multiple specialized `link_components()` implementations
- Trait-based dispatch to handle zonal vs nodal differences
- Consistent structure with market-specific variations handled via traits
- Reduced code duplication (from ~100 lines per market type to ~50 lines total)

**Benefits**:
- Easier to maintain (single source of truth for balance logic)
- Simpler to extend (add new market types by implementing traits)
- Reduced risk of inconsistencies between market types

### 3. Network Configuration (`network_config.jl`)

**Purpose**: Decouples network formulations from market clearing logic, enabling flexible network modeling.

**Key Features**:
- `NetworkFormulation` abstract type with concrete implementations
- `DCPowerFlow` and `ZonalExchange` formulation wrappers
- `NetworkConstraints` configuration object
- `get_network_formulation()` for automatic formulation selection

**Benefits**:
- Network topology independent of market structure
- Easy to add new network formulations (e.g., PTDF, flow-based)
- Composable network constraints

### 4. Extension Points System (`model_extensions.jl`)

**Purpose**: Provides hooks and extension points for adding features without modifying core code.

**Key Features**:
- `ModelExtension` abstract type for pluggable extensions
- `ModelHooks` for custom logic injection at key phases
- `ExtendedModelSetup` wrapping standard `ModelSetup`
- Pre-defined extension placeholders (`IntradayMarket`, `SeasonalStorage`, `FlowBasedMarketCoupling`)

**Benefits**:
- Users can extend model without forking
- Clear extension API
- Maintainers can add features modularly

## Migration Guide

### For Model Users

Existing code continues to work without changes:

```julia
# This still works exactly as before
setup = ModelSetup(
    TimeHorizon = TimeHorizon(stop = 4),
    MarketType = ZonalMarket(),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle)
)
```

### For Model Developers

#### Adding a New Market Type

Before (required modifying multiple files):
1. Add market type to `market_definitions.jl`
2. Add `link_components()` method to `energy_balances.jl`
3. Add `add_network()` method to `technologies.jl`
4. Add `_run()` method to `solving.jl`

After (trait-based approach):
1. Add market type to `market_definitions.jl`
2. Implement `market_scope()` trait in `market_traits.jl`
3. Optional: Override specific behaviors using trait dispatch

#### Adding Custom Constraints

Before: Modify core constraint functions

After: Use hooks system

```julia
hooks = ModelHooks()
register_hook!(hooks, :custom_constraints, sr -> begin
    # Add custom constraints to sr
end)

extended_setup = ExtendedModelSetup(setup; hooks=hooks)
```

## Examples

### Query Market Capabilities

```julia
setup = ModelSetup(...)

# Check if setup includes redispatch
if has_redispatch(typeof(setup))
    println("Model includes redispatch optimization")
end

# Get market scope
scope = market_scope(typeof(setup.MarketType))
# Returns ZonalScope() or NodalScope()
```

### Configure Constraints

```julia
# Customize which constraints are included
config = MarketConstraintConfig(
    include_historical_generation = true,
    include_min_generation = true,
    include_ramping = false,  # Future feature
    include_unit_commitment = false  # Future feature
)

extended_setup = ExtendedModelSetup(setup; constraint_config=config)
```

### Add Custom Extension

```julia
# Define custom extension
struct MyCustomExtension <: ModelExtension
    param1::Float64
    param2::Int
end

# Implement extension application
function POMATWO.apply_extension!(sr::SubRun, ext::MyCustomExtension)
    # Add custom variables, constraints, etc.
end

# Use extension
extensions = [MyCustomExtension(1.0, 5)]
extended_setup = ExtendedModelSetup(setup; extensions=extensions)
```

## Future Enhancements

The new architecture enables several planned features:

1. **Intraday Markets**: Implement `IntradayMarket` extension with time-varying forecasts
2. **Seasonal Storage**: Implement `SeasonalStorage` with multi-period optimization
3. **Flow-Based Market Coupling**: Implement `FlowBasedMarketCoupling` for EU-style markets
4. **Ramping Constraints**: Add via `MarketConstraintConfig.include_ramping`
5. **Unit Commitment**: Add via `MarketConstraintConfig.include_unit_commitment`
6. **N-1 Security**: Add via `NetworkConstraints.n_1_security`

## Technical Details

### Dispatch Hierarchy

```
MarketType
├── ZonalMarketType → ZonalScope
│   └── ZonalMarket{XF}
│       ├── ZonalMarket{NTC}
│       └── ZonalMarket{FlowBased}
└── NodalMarketType → NodalScope
    └── NodalMarket{LF}
        ├── NodalMarket{PhaseAngle}
        └── NodalMarket{PTDF}
```

### Trait Resolution

1. User creates `ModelSetup{MT, PS, RD}`
2. System queries `market_scope(MT)` → Returns trait
3. Functions dispatch on trait type
4. Trait provides unified interface to type-specific behavior

### Balance Equation Flow

1. `create_energybalance()` calls `link_components()`
2. `link_components()` gets market scope trait
3. Calls `create_unified_balance!()` with trait
4. Balance function dispatches on trait for market-specific details
5. Returns unified result

## Performance Impact

- **Compile time**: Minimal increase due to additional dispatch
- **Runtime**: No change (same generated code)
- **Memory**: Negligible (traits are zero-sized types)

## Testing

All existing tests pass without modification, verifying backward compatibility.
New trait-based code paths are exercised by existing test suite.

## Conclusion

These changes significantly improve model flexibility while maintaining 100% backward compatibility. The trait-based architecture provides clear extension points and reduces code duplication, making POMATWO easier to maintain and extend.
