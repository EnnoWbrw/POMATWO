# Market Types

POMATWO supports different market types, defined as subtypes of the abstract type `MarketType`.  
The market type specifies whether a zonal or nodal market design is used.
Choosing the appropriate type is essential for model construction and simulation behavior.

```@docs
MarketType
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

```@docs
FlowBased
```

## GSK Strategies

Generation Shift Keys (GSKs) define how zonal net positions are distributed to individual nodes when computing zonal PTDFs for flow-based market coupling.

```@docs
GSKStrategy
FlatGSK
GmaxGSK
GenLoadGSK
CustomWeightsGSK
build_gsk
gsk_strategies
POMATWO.build_gsk_timeseries
POMATWO.is_time_dependent
POMATWO.timedep_node_weight
zonal_ptdf
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
NoRedispatch
```

# Storage Boundary Condition

Storage levels within a time split are linked hour by hour; the boundary condition determines what the first hour of each split connects to.

```@docs
StorageBoundary
CarryOverStorage
CyclicStorage
```



# Prosumer Setup

Due to the increasing penetration of decentralized generation, especially rooftop PV, POMATWO includes the ability to model prosumers—entities that both consume and produce electricity.  
Prosumers can be passive or actively optimize their market behavior depending on price signals and tariff schemes.

```@docs
ProsumerSetup
NoProsumer
ProsumerOptimization
```

# Flow-Based Basecase

Flow-based market coupling needs a *basecase* — the reference nodal injections from
which the zonal PTDF and the Remaining Available Margins (RAM) are derived. POMATWO
either solves it (`OptimizationBasecase`) or constructs it from a matched reference day
(`ReferenceDayBasecase`), warping the reference injections toward each zone's target net
position with a `ShiftMethod` (`ShareShift`) and a redistribution key (`RedistKey`).
The reference-day methodology, its user decisions, and a worked example are documented in
[FBMC Reference-Day Basecase](refday_basecase.md).

```@docs
BasecaseMethod
OptimizationBasecase
ReferenceDayBasecase
MatchingConfig
MatchScope
GlobalMatchScope
ZonalMatchScope
AreaMatchScope
ShiftMethod
ShareShift
RedistKey
GSKRedist
RefPropRedist
LoadPropRedist
DispOnlyGSK
match_by_cluster
match_by_scope
build_refday_basecase
refday_reference_times
refday_basecase_artifacts
refday_f0
calc_fbmc_params
POMATWO.calc_ram
POMATWO.zone_to_zone_ptdf
```