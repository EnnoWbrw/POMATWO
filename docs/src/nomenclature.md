# 1. Nomenclature

This section defines all sets, parameters, and variables used in the market and redispatch model.

## Sets

| Symbol              | Description                                 | Unit |
|---------------------|---------------------------------------------|------|
| $\mathbf{ACL}$      | Set of AC lines                             | -    |
| $\mathbf{DCL}$      | Set of DC lines                             | -    |
| $\mathbf{N}$        | Set of nodes                                | -    |
| $\mathbf{P}$        | Set of power plants (including renewables)  | -    |
| $\mathbf{S}$        | Set of storage units                        | -    |
| $\mathbf{T}$        | Set of time periods                         | -    |
| $\mathbf{Z}$        | Set of market zones                         | -    |

## Parameters

| Symbol                                | Description                                                        | Unit            |
|----------------------------------------|--------------------------------------------------------------------|-----------------|
| $\mathbf{avail_{p,t}}$                 | Availability of generating unit $p$ at time $t$                    | -               |
| $\mathbf{cap_{acl}^{max}}$             | Maximum capacity of AC line $acl$                                  | MW              |
| $\mathbf{cap_{dcl}^{max}}$             | Maximum capacity of DC line $dcl$                                  | MW              |
| $\mathbf{cap_{s}^{max}}$               | Maximum storage capacity of unit $s$                               | MWh             |
| $\mathbf{c^{curt}}$                    | Curtailment cost                                                   | $\mathrm{EUR}/\mathrm{MWh}$ |
| $\mathbf{c_{p,t}^{mc}}$                | Marginal cost of generating unit $p$ at time $t$                   | $\mathrm{EUR}/\mathrm{MWh}$ |
| $\mathbf{charge_{s,t}}$                | Charging of storage unit $s$ at time $t$ (input, redispatch)       | MW              |
| $\mathbf{cu_{p,t}}$                    | Curtailment of unit $p$ at time $t$ (input, redispatch)            | MWh             |
| $\mathbf{gen_{p}^{max}}$               | Maximum generation capacity of unit $p$                            | MW              |
| $\mathbf{gen_{p,t}}$                   | Generation of unit $p$ at time $t$ (input, redispatch)             | MW              |
| $\mathbf{gen_{s}^{max}}$               | Maximum generation capacity of storage unit $s$                    | MW              |
| $\mathbf{inflow_{s,t}}$                | Inflow into storage unit $s$ at time $t$                           | MW              |
| $\mathbf{load_{n,t}}$                  | Load at node $n$ at time $t$                                       | MWh             |
| $\mathbf{ntc_{z,zz}}$                  | Nominal transmission capacity between zones $z$ and $zz$           | MW              |
| $\mathbf{A^{dc}_{l\times n}}$          | Incidence matrix of DC lines                                       | -               |
| $\mathbf{B^{line}_{acl \times n}}$     | Line susceptance matrix                                            | -               |
| $\mathbf{B^{bus}_{n \times m}}$        | Bus susceptance matrix                                             | -               |
| $\mathbf{\eta_s}$                      | Efficiency of storage unit $s$                                     | -               |


## Variables

| Symbol                                | Description                                                        | Unit |
|----------------------------------------|--------------------------------------------------------------------|------|
| $\mathbf{CHARGE_{s,t}}$                | Charging of storage unit $s$ at time $t$                           | MW   |
| $\mathbf{CHARGE_{s,t}^{down}}$         | Charging decrease of storage unit $s$ at time $t$ after redispatch | MW   |
| $\mathbf{CHARGE_{s,t}^{redisp}}$       | Charging of storage unit $s$ at time $t$ after redispatch          | MW   |
| $\mathbf{CHARGE_{s,t}^{up}}$           | Charging increase of storage unit $s$ at time $t$ after redispatch | MW   |
| $\mathbf{CU_{p,t}^{redisp}}$           | Curtailment of generating unit $p$ at time $t$ after redispatch    | MWh  |
| $\mathbf{CU_{z,t}}$                    | Curtailment at zone $z$ at time $t$                                | MWh  |
| $\mathbf{EX_{z,t}^{net}}$              | Net exchange at zone $z$ at time $t$                               | MWh  |
| $\mathbf{EX_{zz,z,t}}$                 | Exchange from zone $zz$ to zone $z$ at time $t$                    | MWh  |
| $\mathbf{F_{dcl,t}}$                   | DC line flow at time $t$                                           | MW   |
| $\mathbf{F_{dcl,t}^{neg}}$             | DC line flow in negative direction at time $t$                     | MW   |
| $\mathbf{F_{dcl,t}^{pos}}$             | DC line flow in positive direction at time $t$                     | MW   |
| $\mathbf{GEN_{p,t}}$                   | Generation of unit $p$ at time $t$                                 | MW   |
| $\mathbf{GEN_{p,t}^{redisp}}$          | Generation of unit $p$ at time $t$ after redispatch                | MW   |
| $\mathbf{INJ_{n,t}}$                   | Injection at node $n$ at time $t$                                  | MW   |
| $\mathbf{RAMP_{p,t}^{down}}$           | Ramping down of generating unit $p$ at time $t$                    | MW   |
| $\mathbf{RAMP_{p,t}^{up}}$             | Ramping up of generating unit $p$ at time $t$                      | MW   |
| $\mathbf{S_{s,t}^{lvl}}$               | Storage level of storage unit $s$ at time $t$                      | MWh  |
| $\mathbf{S_{s,t}^{lvl,redisp}}$        | State of charge of storage unit $s$ after redispatch at time $t$   | MWh  |
| $\mathbf{\theta_n}$                   | Voltage phase angle at node $n$                                    | -    |
See [market_model.md](./market_model.md) for the utilization of the Sets, Parameters and Variables.

## Flow-Based Market Coupling Symbols

These symbols are used in the flow-based market coupling and reference-day basecase
methodology (see [Reference-Day Basecase](./refday_methodology.md)).

| Symbol                          | Description                                                                 | Unit |
|---------------------------------|-----------------------------------------------------------------------------|------|
| $\mathbf{PTDF_{n}}$             | Nodal power transfer distribution factors, $PTDF_n = B^{line}(B^{bus})^{-1}$ | -    |
| $\mathbf{GSK}$                  | Generation Shift Key matrix (node $\times$ zone), columns sum to 1          | -    |
| $\mathbf{PTDF_{z}}$             | Zonal PTDF, $PTDF_z = PTDF_n \cdot GSK$                                      | -    |
| $\mathbf{PTDF_{zz}}$            | Zone-to-zone PTDF, $PTDF_z[\,\cdot\,,z_{im}] - PTDF_z[\,\cdot\,,z_{ex}]$     | -    |
| $\mathbf{NP_{z}}$               | Zonal net position (import-positive), $-\sum_{n \in z} INJ_{ac,n}$          | MW   |
| $\mathbf{F_{0,l}}$              | Reference flow on line $l$ with the commercial exchange removed             | MW   |
| $\mathbf{RAM^{pos/neg}_{l}}$    | Remaining Available Margin on critical line $l$ per direction               | MW   |
| $\mathbf{FRM}$                  | Flow Reliability Margin (fraction of line capacity)                         | -    |
| $\mathbf{\lambda}$              | Minimum-RAM share (`minRAM`, the EU "70 % rule")                            | -    |
| $\mathbf{\beta}$                | Reference-day shift apportionment shares ($RES$, $conv$, $load$, $NP$)      | -    |