# Market Types

POMATWO supports different market types, defined as subtypes of the abstract type `MarketType`.  
The market type specifies whether a zonal or nodal market design is used.
Choosing the appropriate type is essential for model construction and simulation behavior.

```@docs
MarketType
ZonalMarketType
NodalMarketType
```

## Zonal Markets

Zonal markets are coarse representations of the power system, where nodes are aggregated into zones, and cross-border flows are modeled via exchange formulations.

```@docs
ZonalMarket
```

## Nodal Markets

Nodal markets use detailed grid representations with nodal-level price formation and physical power flows.

```@docs
NodalMarket
```

## Exchange Formulations

Exchange formulations define how power exchanges between zones are handled in zonal market settings.

```@docs
NTC
```

## Load Flow Formulations

Load flow formulations are used in nodal market and redispatch settings to model physical power flows under DC approximations.

```@docs
PhaseAngle
```

# Redispatch Setup

POMATWO supports optional redispatch modeling. Redispatch is activated via types derived from `RedispatchSetup`.

```@docs
DCLF
DCLF(::Type)
DCLF()
NoRedispatch
```

# Market States

Market simulations in POMATWO can consist of multiple stages (or states), such as day-ahead market, redispatch, and prosumer optimization.

```@docs
MarketState
DayAhead
ProsumerOptimizationState
Redispatch
```

# Prosumer Setup

Due to the increasing penetration of decentralized generation, especially rooftop PV, POMATWO includes the ability to model prosumers—entities that both consume and produce electricity.  
Prosumers can be passive or actively optimize their market behavior depending on price signals and tariff schemes.

```@docs
ProsumerSetup
NoProsumer
ProsumerOptimization
```