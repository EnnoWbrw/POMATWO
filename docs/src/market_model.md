# 2. Market Model

The power market model can operate in two phases:

1. **Zonal/Nodal Market Clearing** — day-ahead dispatch based on perfect competition.
2. **Redispatch** — adjustments to initial dispatch for network feasibility.

---
## Market Clearing Phase

### Objective Function

```math
\min \quad
\sum_{t}^T \sum_{p}^{P} c_{p,t}^{mc} \cdot GEN_{p,t}
+ c^{curt} \cdot \sum_{t}^{T} \sum_{z}^{Z} CU_{z,t}
+ \sum_t^T \sum_{s}^{S} mc_{s,t} \cdot GEN_{s,t}
```
### Market Balance
Depending on the chosen setup, the market balance will either be zonal, or nodal. In Europe, market balances are created in a zonal level, with some countries having multiple market zones. An example of nodal pricing can be found in the electricity market of the USA.
#### Zonal Market Balance

```math
\begin{aligned}
& \sum_{p \in z}^{P} GEN_{p,t}
+ \sum_{s \in z}^{S} (GEN_{s,t} - CHARGE_{s,t})
+ EX_{z,t}^{net}
- CU_{z,t} \\
&= \sum_{n \in z}^{N} load_{n,t}
- LL_{z,t}, \qquad \forall \ z \in Z, t \in T
\end{aligned}
```

#### Nodal Market Balance
```math
\begin{aligned}
 &\sum_{u \ in \ n}^U GEN_{u,t} +
    \sum_{s \ in \ n}^S (GEN_{s,t} -CHARGE_{s,t})
    &+ INJ_{n,t} - CU_{n,t}\\ = &load_{n,t} - LL_{n,t} & \forall \ n \in N, t \in T
\end{aligned}
```

### Storage Balance

```math
S_{s,t}^{lvl} - S_{s,t-1}^{lvl} =
CHARGE_{s,t} \cdot \eta_{s} - \frac{GEN_{s,t}}{\eta_{s}} + inflow_{s,t},
\quad \forall \ s \in S, \ t \in T
```

### Exchange
The following exchange equation only applies in zonal markets, where electricity transmission within a given zone is neglected and only cross border flows are depicted using a simple approach based on net transfer capacities and an import-export balance. Nodal markets on the other hand already take the physical characteristics of the transmission grid into accound (a describtion of lineflow constraints can be found in section [Line Flow Constraints](@ref) and [3. AC Power Flow Linearization](@ref)) 
```math
EX_{z,t}^{net} = \sum_{zz}^Z EX_{zz,z,t} - EX_{z,zz,t},
\qquad \forall \ z \in Z, t \in T
```

### Variable Bounds

```math
\begin{aligned}
0 \leq GEN_{p,t} &\leq avail_{p,t} \cdot gen_{p}^{max}, && \forall \ p \in P, \ t \in T \\
0 \leq GEN_{s,t} &\leq gen_{s}^{max}, && \forall \ s \in S, \ t \in T \\
0 \leq CHARGE_{s,t} &\leq gen_{s}^{max}, && \forall \ s \in S, \ t \in T \\
0 \leq S_{s,t}^{lvl} &\leq cap_{s}^{max}, && \forall \ s \in S, \ t \in T \\
0 &\leq CU_{z,t}, && \forall \ z \in Z, \ t \in T \\
0 &\leq LL_{z,t}, && \forall \ z \in Z, \ t \in T \\
0 \leq EX_{z,zz,t} &\leq ntc_{z,zz}, && \forall \ z \in Z, \ zz \in Z, t \in T
\end{aligned}
```

---

## Redispatch Phase

### Objective Function

```math
\begin{aligned}
\min \quad & \sum_t^T\sum_{p}^P c^{redisp} \cdot (RAMP_{p,t}^{up} + RAMP_{p,t}^{down})
+  \sum_t^T\sum_{p}^P c^{curt} \cdot (CU_{p,t}^{redisp} - cu_{p,t}) \\
& + \sum_t^T\sum_{s}^S c^{redisp} \cdot (GEN_{s,t}^{up} + GEN_{s,t}^{down}) \\
& + \sum_t^T\sum_{s}^S c^{redisp} \cdot (CHARGE_{s,t}^{up} + CHARGE_{s,t}^{down})
\end{aligned}
```

### Redispatch Market Balance

```math
\begin{aligned}
\sum_{p \in n}^P GEN_{p,t}^{redisp} +
\sum_{s \in n}^S (GEN_{s,t}^{redisp} - CHARGE_{s,t}^{redisp})
+ INJ_{n,t} - CU_{n,t}
= load_{n,t} - LL_{n,t} \qquad \forall \ n \in N, t \in T
\end{aligned}
```

### Line Flow Constraints

```math
\begin{aligned}
F_{dcl,t} &= F_{dcl,t}^{pos} - F_{dcl,t}^{neg}, && \forall \ t \in T, dcl \in DCL \\
F_{acl,t} &= \sum_n^{N} \text{B}_{acl \times n}^{line} \cdot \theta_{n}, && \forall \ acl \in ACL, t \in T \\
INJ_n &= \sum_m^{M} \text{B}_{n \times m}^{bus} \cdot \theta_{m}  + \sum_{dcl}^{DCL} \text{A}_{l\times n}^{dc} \cdot F_{dcl,t}, && \forall \ n  \in N
\end{aligned}
```

### Variable Balances

```math
\begin{aligned}
GEN_{p,t}^{redisp} &= RAMP_{p,t}^{up} - RAMP_{p,t}^{down} + gen_{p,t}, && \forall p \in P, t \in T \\
GEN_{s,t}^{redisp} &= GEN_{s,t}^{up} - GEN_{s,t}^{down} + gen_{s,t}, && \forall s \in S, t \in T \\
CHARGE_{s,t}^{redisp} &= CHARGE_{s,t}^{up} - CHARGE_{s,t}^{down} + charge_{s,t}, && \forall s \in S, t \in T
\end{aligned}
```

### Storage Balance

```math
S_{s,t}^{lvl,redisp} = S_{s,t-1}^{lvl,redisp} - \frac{GEN_{s,t}^{redisp}}{\eta_s} + CHARGE_{s,t}^{redisp} \cdot \eta_s, \quad \forall s \in S, t \in T
```

### Variable Bounds

```math
\begin{aligned}
0 \leq RAMP_{p,t}^{up} &\leq avail_{p,t} \cdot gen_{p}^{max} - gen_{p,t}, && \forall p \in P, t \in T \\
0 \leq RAMP_{p,t}^{down} &\leq gen_{p,t}, && \forall p \in P, t \in T \\
0 \leq GEN_{s,t}^{up} &\leq gen_{s}^{max} - gen_{s,t}, && \forall s \in S, t \in T \\
0 \leq GEN_{s,t}^{down} &\leq gen_{s,t}, && \forall s \in S, t \in T \\
0 \leq CHARGE_{s,t}^{up} &\leq gen_{s}^{max} - charge_{s,t}, && \forall s \in S, t \in T \\
0 \leq CHARGE_{s,t}^{down} &\leq charge_{s,t}, && \forall s \in S, t \in T \\
0 \leq S_{s,t}^{lvl,redisp} &\leq cap_{s}^{max}, && \forall s \in S, t \in T \\
0 \leq CU_{p,t}^{redisp} &\leq avail_{p,t} \cdot gen_{p}^{max}, && \forall p \in P, t \in T \\
-cap_{acl}^{max} \leq F_{acl,t} &\leq cap_{acl}^{max}, && \forall acl \in ACL, t \in T \\
-cap_{dcl}^{max} \leq F_{dcl,t} &\leq cap_{dcl}^{max}, && \forall dcl \in DCL, t \in T \\
0 \leq F_{dcl,t}^{pos}, && \forall t \in T, dcl \in DCL \\
0 \leq F_{dcl,t}^{neg}, && \forall t \in T, dcl \in DCL \\
0 \leq \theta_{n,t}, && \forall t \in T, n \in N \\
0 = \theta_{n=slack,t}, && \forall t \in T \\
0 \leq GEN_{p,t}^{redisp}, && \forall p \in P, t \in T \\
0 \leq GEN_{s,t}^{redisp}, && \forall s \in S, t \in T \\
0 \leq CHARGE_{s,t}^{redisp}, && \forall s \in S, t \in T \\
0 \leq LL_{n,t}, && \forall n \in N, t \in T
\end{aligned}
```


