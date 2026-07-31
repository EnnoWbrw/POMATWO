# 3. AC Power Flow Linearization

The apparent power flow from one node to another can be divided into active and reactive power:
```math
\begin{aligned}
    P_{n,m} &= \lvert \underline{U}_n^2 \rvert \cdot g_{n,m} - \lvert U_n \rvert \cdot \lvert U_m \rvert \cdot g_{n,m} \cdot \cos{\theta_{n,m}} - \lvert U_n \rvert \cdot \lvert U_m \rvert \cdot b_{n,m} \sin{\theta_{n,m}}\\
    Q_{n,m} &= - \lvert \underline{U}_n^2 \rvert \cdot b_{n,m} + \lvert U_n \rvert \cdot \lvert U_m \rvert \cdot b_{n,m} \cdot \cos{\theta_{n,m}} - \lvert U_n \rvert \cdot \lvert U_m \rvert \cdot g_{n,m} \sin{\theta_{n,m}}
\end{aligned}
```
## DC Power Flow Assumptions

For the linearization of power flows in the AC network, the reactive power component ``Q`` is neglected, the reasoning behind this is given below. The following three assumptions are necessary:

1. ``g = 0`` and ``b = \frac{-1}{X}``
2. ``\cos(\theta_{n,m}) = 1`` and ``\sin(\theta_{n,m}) = \theta_{n,m}``
3. ``|U_n| = |U_m| = 1`` (per-unit system)

Assumption 1 is based on the observation that the ohmic resistance ``R`` in the transmission network is significantly smaller than the reactance ``X``. Recall that for the impedance ``\underline{Z}``:

```math
\underline{Z} = R + jX
```

By rearranging the equations:

```math
\underline{Y} = \frac{1}{\underline{Z}} = \frac{1}{R + jX} = g + jb
```

we obtain:

```math
g = \frac{R}{R^2+X^2}\qquad b = \frac{-X}{R^2+X^2}
```

When ``R \ll X``, these terms simplify to: ``g = 0`` and ``b = \frac{-1}{x\_{n,m}}``.

Thus, the equations simplify to:

```math
\begin{aligned}
    P_{n,m} &= - b_{n,m} \cdot |U_n| \cdot |U_m|  \sin(\theta_{n,m}) \\
    &= \frac{1}{x_{n,m}} \cdot |U_n| \cdot |U_m|  \sin(\theta_{n,m}) \\
    Q_{n,m} &= - b_{n,m} \cdot |\underline{U}_n^2| +  b_{n,m} \cdot |U_n| \cdot |U_m| \cdot \cos(\theta_{n,m}) \\
    &= \frac{1}{x_{n,m}} \cdot |\underline{U}_n^2| -  \frac{1}{x_{n,m}} \cdot |U_n| \cdot |U_m| \cdot \cos(\theta_{n,m})
\end{aligned}
```

Assumption 2 is based on the observation that the phase angle difference ``\theta\_{n,m}`` is very small. The cosine of ``\theta`` converges to 1 as ``\theta`` approaches 0. The small-angle approximation states that ``\sin(\theta) \approx \theta``for very small ``\theta\`` (in radians).

With the small-angle approximation, the above equations further simplify to:

```math
\begin{aligned}
    P_{n,m} &= \frac{1}{x_{n,m}} \cdot |U_n| \cdot |U_m| \cdot  \theta_{n,m} \\
    Q_{n,m} &= \frac{1}{x_{n,m}} \cdot |\underline{U}_n^2| -  \frac{1}{x_{n,m}} \cdot |U_n| \cdot |U_m|
\end{aligned}
```

Assumption 3 implies that the node voltages rarely deviate from their design values and only by a small amount. In the per-unit system, the magnitudes of the node voltages are therefore very close to 1.

By substituting Assumption 3 into the previous equations, the linearized equations for power transmission are obtained:

```math
\begin{aligned}
    P_{n,m} &= \frac{1}{x_{n,m}} \cdot \theta_{n,m} \\
    Q_{n,m} &= \frac{1}{x_{n,m}} -  \frac{1}{x_{n,m}} = 0
\end{aligned}
```

For the active nodal power:

```math
P_n = \sum_{m}^N\frac{1}{x_{n,m}}\cdot \theta_{n,m}
```
## Model Integration
With the active power flow ``P_{n,m}`` from node ``n`` to node ``m`` and the net power input at node ``n`` called ``P_n``. In this formulation the line parameter ``x_{n,m}`` representing the line reactance is static, i.e. not time dependent. This is often done in power system modeling. The whole power flow problem depicted in Equations (see formulas below) is dependent on the variable ``\theta_{n,m}``, which represents the phase angle difference between two connected nodes. The equations can be transformed to represent actual power flows on line ``l`` and nodal net power injections into node ``n`` by using two matrices that capture grid topology and line parameters. Additionally, line limitations can be considered by adding equation for ``f_l^{max}``.

```math
F_{l} = \sum_n^N \text{B}_{l\times n}^{line} \cdot \theta_{n} \qquad \forall l \in L \\
INJ_n = \sum_m^N \text{B}_{n \times m}^{bus} \cdot \theta_{m} \qquad \forall n \in N \\
INJ_n = \sum_l^L \text{A}_{l\times n} \cdot F_{l} \qquad \forall n \in N \\
-f_l^{max} \leq F_{l} \leq f_l^{max} \qquad \forall l \in L \\
\theta_{n=slack} = 0
```

Implementing a reference node, often referred to as a "slack node", with a fixed nodal phase angle of ``\theta_{n=slack} = 0`` allows a simplification of the phase angle difference ``\theta_{n,m}`` to the nodal phase angle difference ``\theta_n``. The nodal phase angles are all in reference to the one common slack node. The entire load flow problem then only contains one decision variable for each node, which significantly decreases model complexity.

The slack node can be chosen at random within the connected system.

The line susceptance matrix ``\text{B}_{l\times n}^{line}`` is an ``l \times n`` matrix, that can be created from a diagonalized vector of line susceptances ``\text{B}_{l,l}^d`` multiplied by the incidence matrix ``\text{A}_{l\times n}``.

The bus susceptance matrix ``\text{B}_{n \times m}^{bus}`` can be created by multiplying the transposed line susceptance matrix with the incidence matrix.

```math
\text{B}_{l\times n}^{line} = \text{B}_{l,l}^d \cdot \text{A}_{l\times n} \\
\text{B}_{n \times m}^{bus} = \text{A}_{l\times n}^T \cdot \text{B}_{l,l}^d \cdot \text{A}_{l\times n} \\
= (\text{B}_{l\times n}^{line})^T \cdot \text{A}_{l\times n}
```

In the incidence matrix ``\text{A}_{l\times n}`` the row of line ``l`` contains the value +1 at the column of node ``n`` if the line starts at node ``n`` and the value ``-1`` if the line ends in node ``n``, all other values are zero.

The diagonal elements of the ``\text{B}_{n \times m}^{bus}`` matrix contain the sum of all line susceptances of adjacent lines at node ``n``. If there is a line from node ``n`` to node ``m``, non-diagonal elements contain the value of the negative line susceptances, or zero if no connection exists.

Example for a simple three-node network:

```math
\text{B}_{l,l}^d = \nobreak
\begin{bmatrix}
 b_{l_1} & 0 \\
 0 & b_{l_2}
\end{bmatrix}
\text{A}_{l\times n} = \nobreak
\begin{bmatrix}
1 & -1 & 0 \\
0 & 1 & -1  
\end{bmatrix}
\text{B}_{l\times n}^{line} = \nobreak
\begin{bmatrix}
b_{l_1} & -b_{l_1} & 0 \\
0 & b_{l_2} & -b_{l_2}
\end{bmatrix}
\text{B}_{n \times m}^{bus} = \nobreak
\begin{bmatrix}
b_{l_1} & -b_{l_1} & 0 \\
-b_{l_1} & b_{l_1} + b_{l_2} & -b_{l_2}\\
0 & -b_{l_2} & b_{l_2}
\end{bmatrix}
```

The line directions in the incidence matrix may be chosen arbitrarily for this application, the direction only defines the sign of the power flow value.

## PTDF-Matrix Formulation
Removing the column and row corresponding to the slack node in the ``\text{B}_{n \times m}^{bus}`` matrix, the inverted matrix ``(\text{B}_{n \times m}^{bus})^{-1}`` may be used to solve for ``\theta`` to arrive at an alternative model formulation based on the power transfer distribution factor (PTDF) matrix. To ensure the Kirchhoff Current Law is still satisfied after the removal of the reference node, the following equation is added:

```math
PTDF_{l\times n} = \text{B}_{l\times n}^{line} \cdot (\text{B}_{n \times m}^{bus})^{-1} \\
F_l = \sum_n PTDF_{l\times n} \cdot INJ_n \qquad \forall l \in L \\
\sum_n INJ_n = 0
```

## Nodal results of a zonal day-ahead

A zonal day-ahead market has no nodal network formulation: it clears per zone and exchanges
between zones, so none of the variables above exist in that stage. The nodal picture is
nevertheless well defined once the market has cleared — every plant is assigned to a node,
so the cleared dispatch implies a nodal net injection, and the PTDF turns that injection
into line flows. POMATWO computes both after the clearing and persists them in the same
tables every other stage writes (`DayAhead_NETINPUT`, `DayAhead_LINEFLOW`,
`DayAhead_DCLINEFLOW`):

```math
NETINPUT_{n,t} = load_{n,t} + \sum_{s \in n} CHARGE_{s,t} - \sum_{p \in n} GEN_{p,t}
\qquad
LINEFLOW_{l,t} = \sum_n PTDF_{l,n} \cdot ACINJECTION_{n,t}
```

These are the flows the market outcome would cause **before** redispatch. They are
therefore deliberately **not** constrained to the line capacities and may exceed them —
an overload here is the congestion the redispatch stage then resolves. The `line_capacity`
column is reported alongside for comparison.

Three properties follow from the fact that these values are computed, not optimized:

- `DELTA` is `0`: a zonal clearing has no phase angles.
- Under the `NTC` exchange formulation no DC-line flows are modelled, so DC lines are
  assumed idle: `ACINJECTION` equals `NETINPUT` and no `DCLINEFLOW` rows are written. Under
  `FlowBased`, DC flows are model variables, so `ACINJECTION` is the true AC part
  (`NETINPUT` minus the DC injection) and `DCLINEFLOW` is exact.
- The zonal balance's `CU`/`LL` infeasibility slacks are zonal, not nodal, and do not enter
  the nodal net injection. Whenever they are active — which the penalty-cost hierarchy makes
  a signal that the run is infeasible, see `check_infeasibility` — a zone's summed net
  injection and its `EXCHANGE` differ by exactly those slacks.

A last caveat concerns `fixed_exchange`: a zone exchanging with a zone outside the modelled
system makes the modelled injections sum to something other than zero, and the PTDF then
attributes that residual to the slack node. Where fixed exchanges matter, model the
counterpart explicitly rather than reading the zonal day-ahead flows as physical.

**References:**  
- [Van den Bergh, Delarue (2014)](https://api.semanticscholar.org/CorpusID:111125894)
- [Monticelli (1999)](https://doi.org/10.1007/978-1-4615-4999-4_4)  
- [Egerer (2016)](https://hdl.handle.net/10419/129782)
- [Weinhold, Mieth (2021)](https://doi.org/10.1016/j.softx.2021.100870)