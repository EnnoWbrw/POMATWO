# Market Types
POMATWO supports different market types, that are defined as subtypes of the `MarketType`.
Defining the type of market that is to be simulated is key for the model creation. 

```@docs
MarketType
```
In the following, a brief description of supported market types is given. 
## Zonal Markets
```@docs
ZonalMarket
```
```@docs
ZonalMarketWithRedispatch
```
## Nodal Markets
```@docs
NodalMarket
```
```@docs
NodalMarketWithRedispatch
```
# Prosumer Setup
Due to the development of increasingly high generation capacities of solar photovoltaiks, owned by private consumers, POMATWO includes the option to include so called "Prosumers" in the market simulation. Prosumers have their own optimization problem i.e. and, depending on the pricing scheme, they can react to wholesale price signals, or flat electricity prices. 

```@docs
ProsumerSetup
```
```@docs
NoProsumer
```
```@docs
ProsumerOptimization
```
