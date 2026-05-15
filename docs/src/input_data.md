# Model Data

## Input Data Load
```@docs
load_data(data::Dict)
```

## Model Input Data Structure

Data is provided as separate CSV files, one per key in the `data` dictionary passed to [`load_data`](@ref). Column names must exactly match the identifiers described below (case-sensitive). The tables indicate whether each column is **required** or **optional**; optional columns are ignored if absent but change model behaviour when present.

!!! danger "Index Linking"
    Input tables reference each other via unique string identifiers (`index`).
    These must be consistent across all files. Mismatched references are caught as errors during loading.

---

### File Structure `:plants`

One row per power plant.

| Column             | Required | Type    | Description |
|--------------------|----------|---------|-------------|
| `index`            | ✔        | String  | Unique plant identifier. Must be unique across all rows. |
| `plant_type`       | ✔        | String  | Plant type identifier. |
| `node`             | ✔        | String  | Node the plant is connected to. |
| `g_max`            | ✔        | Float   | Maximum generation capacity (MW). Must be positive. |
| `eta`              | ✔        | Float   | Efficiency factor. Must be in [0, 1]. |
| `storage_capacity` | optional | Float   | Storage energy capacity (MWh). Both `storage_capacity` **and** `storage_power` must be present and non-missing together to activate storage for this plant. |
| `storage_power`    | optional | Float   | Maximum charge/discharge power of the storage unit (MW). See `storage_capacity`. |
| `mc`               | optional | Float   | Marginal cost (€/MWh). Loaded as a fixed profile. Takes priority over the calculated marginal cost — if present, no calculation is performed for this plant. |
| `availability`     | optional | Float   | Fixed availability factor in [0, 1]. Loaded as a fixed profile. Takes lowest priority; plant-level availability files (`:avail`) override this. |

!!! warning "Marginal cost must be determinable for every plant"
    After loading, the marginal cost is computed for every plant that has no `mc` value in the `:plants` file using:

    $$mc = \frac{\text{fuel\_price}}{\eta} + \frac{\text{co2\_price} \times \text{co2content}}{\eta}$$

    This requires `fuel_price` to be defined for the plant's type — either via the `fuel_price` column in [File Structure `:types`](@ref) or via the optional [`:fuel_prices`](@ref) input file. `co2content` defaults to `0` if absent (zero CO₂ cost). Loading will fail at the post-processing stage if `fuel_price` is missing for any plant type whose plants lack a direct `mc`.

    The CO₂ price is read from the entry keyed `"co2"` in the fuel price table — i.e. a column named `co2` in the [`:fuel_prices`](@ref) file. If that column is absent, the CO₂ price defaults to `0` (no CO₂ cost component).

!!! note "Index Linking"
    - `plant_type` must match an `index` in [File Structure `:types`](@ref).
    - `node` must match an `index` in [File Structure `:nodes`](@ref).

!!! note "Multiple files"
    `:plants` may point to a `Vector` of file paths. Each file is loaded and merged into the same plant set.

#### Example
```csv
index,plant_type,node,g_max,eta,storage_capacity,storage_power,mc
p1,wind,n1,140,1,,,
p2,coal,n2,300,1,,,20
p3,battery,n1,50,0.9,200,50,
```

---

### File Structure `:types`

One row per plant type. Controls dispatch classification and cost parameters.

| Column         | Required | Type    | Description |
|----------------|----------|---------|-------------|
| `index`        | ✔        | String  | Plant type name. Must be unique. |
| `dispatchable` | ✔        | Integer | `1` = dispatchable, `0` = non-dispatchable (e.g. must-run renewables). |
| `storage`      | optional | Integer | `1` = storage type, `0` otherwise. |
| `prosumer`     | optional | Integer | `1` = prosumer type, `0` otherwise. |
| `fuel_price`   | optional | Float   | Fuel cost (€/MWh). Loaded as a fixed profile. |
| `co2content`   | optional | Float   | CO₂ content (t/MWh). |
| `color`        | optional | String  | Hex colour code for visualisation (e.g. `#1f77b4`). |

!!! note "Index Linking"
    `index` is referenced by `plant_type` in [File Structure `:plants`](@ref).

#### Example
```csv
index,dispatchable,storage,fuel_price,co2content,color
coal,1,0,25,0.34,#4d4d4d
wind,0,0,0,0,#2ca02c
battery,1,1,0,0,#1f77b4
```

---

### File Structure `:zones`

One row per market zone.

| Column  | Required | Type   | Description |
|---------|----------|--------|-------------|
| `index` | ✔        | String | Zone identifier. Must be unique. |
| `CCM`   | optional | String | Capacity Calculation Method. `"fb"` = flow-based, `"ac_ntc"` = net transfer capacity on AC lines. If present, every zone must be assigned to exactly one category. If absent, all zones default to flow-based when a `FlowBased` exchange formulation is used. |

!!! warning "CCM consistency"
    When the `CCM` column is present, every zone must have a value of either `"fb"` or `"ac_ntc"`. Missing or invalid values are reported as errors. Additionally, every zone assigned `"ac_ntc"` must have at least one NTC value defined (in either direction) in [File Structure `:ntc`](@ref).

!!! note "Index Linking"
    `index` is referenced by the `zone` column in [File Structure `:nodes`](@ref) and by the first column of [`:avail_planttype_zonal`](@ref).

#### Example — without CCM column
```csv
index
DE
FR
PL
```

#### Example — with CCM column
```csv
index,CCM
DE,fb
FR,fb
PL,ac_ntc
```

---

### File Structure `:nodes`

One row per network node.

| Column      | Required | Type   | Description |
|-------------|----------|--------|-------------|
| `index`     | ✔        | String | Node identifier. Must be unique. |
| `zone`      | ✔        | String | Zone this node belongs to. |
| `slack`     | ✔        | String | Slack bus reference — see below. |
| `lat`       | optional | Float  | Latitude (decimal degrees). Used for visualisation. If missing, defaults to `0.0`. Also accepted as `latitude`. |
| `lon`       | optional | Float  | Longitude (decimal degrees). Used for visualisation. If missing, defaults to `0.0`. Also accepted as `longitude`. |

Additional columns (e.g. `name`) are permitted but ignored.

#### The `slack` column

Each node's `slack` value is the **index of the slack bus that balances its area**. A node that is itself the slack bus must reference its own index. This allows groups of nodes to share a single slack bus.

```
index | zone | slack
n1    | Z1   | n1     ← n1 is its own slack bus
n2    | Z2   | n3     ← n2 is balanced by n3
n3    | Z2   | n3     ← n3 is the slack bus for the {n2, n3} group
n4    | Z3   | n4     ← n4 is its own slack bus
```

Result: `params.slack = ["n1", "n3", "n4"]`, `params.slack_zone = Dict("n1"=>["n1"], "n3"=>["n2","n3"], "n4"=>["n4"])`.

!!! warning "Legacy 0/1 format"
    A `slack` column containing only `0` and `1` is still accepted but triggers a deprecation warning. In that format each node with `slack=1` becomes a standalone slack bus and no zone grouping is built. Migrate to the reference format above.

!!! note "Index Linking"
    - `zone` must match an `index` in [File Structure `:zones`](@ref).
    - `index` is referenced by `node` in [File Structure `:plants`](@ref), by node column names in [File Structure `:demand`](@ref), and by `node_i` / `node_j` in [File Structure `:lines`](@ref) and [File Structure `:dclines`](@ref).

#### Example
```csv
index,zone,slack,lat,lon
n1,DE,n1,47.907355,7.555917
n2,DE,n1,49.487800,7.722690
n3,PL,n3,47.868229,13.076006
```

---

### File Structure `:lines`

One row per AC transmission line.

| Column    | Required              | Type    | Description |
|-----------|-----------------------|---------|-------------|
| `index`   | ✔                     | String  | Line identifier. Must be unique. |
| `node_i`  | ✔                     | String  | From-node. |
| `node_j`  | ✔                     | String  | To-node. |
| `capacity`| ✔                     | Float   | Thermal capacity (MW). |
| `node_i`  | ✔                     | String  | Start node identifier. |
| `node_j`  | ✔                     | String  | End node identifier. |
| `voltage` | see note              | Float   | Nominal voltage (kV). Required when using absolute impedance/susceptance parameters (`r`, `x`, or `b`). Defaults to 220 kV with a warning if absent. |
| `x_pu`    | one group required¹   | Float   | Per-unit reactance. |
| `r_pu`    | one group required¹   | Float   | Per-unit resistance. Must be provided together with `x_pu`. |
| `x`       | one group required¹   | Float   | Absolute reactance (Ω). Requires `voltage`. |
| `r`       | one group required¹   | Float   | Absolute resistance (Ω). Requires `voltage` and must be provided with `x`. |
| `b_pu`    | one group required¹   | Float   | Per-unit susceptance. |
| `b`       | one group required¹   | Float   | Absolute susceptance (S). Requires `voltage`. |
| `circuits`| optional              | Integer | Number of parallel circuits. Divides impedance / multiplies susceptance. Defaults to `1`. |

¹ **At least one of the following groups must be present per line:** `(x_pu, r_pu)`, `(x, r)`, `b_pu`, or `b`. If both impedance and susceptance columns are provided, susceptance takes precedence (a warning is issued).

!!! note "Index Linking"
    `node_i` and `node_j` must match indices in [File Structure `:nodes`](@ref).

#### Example — per-unit parameters
```csv
index,node_i,node_j,capacity,voltage,x_pu,r_pu
l1,n1,n2,300,220,0.04,0.01
l2,n2,n3,200,220,0.06,0.015
```

#### Example — absolute parameters
```csv
index,node_i,node_j,capacity,voltage,x,r
l1,n1,n2,300,220,18.35,4.09
```

---

### File Structure `:dclines`

One row per DC transmission line (HVDC link).

| Column     | Required | Type   | Description |
|------------|----------|--------|-------------|
| `index`    | ✔        | String | Line identifier. Must be unique. |
| `node_i`   | ✔        | String | From-node. |
| `node_j`   | ✔        | String | To-node. |
| `capacity` | ✔        | Float  | Maximum power transfer (MW). |

Additional columns (e.g. coordinates) are permitted but ignored.

!!! note "Index Linking"
    `node_i` and `node_j` must match indices in [File Structure `:nodes`](@ref).

#### Example
```csv
index,node_i,node_j,capacity
dc1,n1,n3,500
```

---

### File Structure `:demand`

Nodal load time series. Two formats are accepted:

**Wide format** (one column per node, one row per time step):

```csv
n1,n2,n3
60,40,80
100,60,120
```

An optional leading column named `Hour` or `index` is automatically skipped.

**Stacked format** (columns: `[id_col, node, value]`):

```csv
hour,node,value
1,n1,60
1,n2,40
2,n1,100
```

Nodes that exist in `:nodes` but have no column in the demand file default to zero demand. Columns that reference unknown nodes are reported as errors.

!!! note "Index Linking"
    Column names (wide) or `node` values (stacked) must match indices in [File Structure `:nodes`](@ref).

---

### File Structure `:avail`, `:avail_planttype_nodal`, `:avail_planttype_zonal`

Availability factors scale a plant's maximum generation capacity at each time step. Values must be in `[0, 1]`. The model applies the availability with the highest specificity, with the following priority order:

| Key                      | Specificity | Description |
|:-------------------------|:-----------:|:------------|
| `:avail`                 | 1 (highest) | Per-plant time series, keyed by plant `index`. |
| `:avail_planttype_nodal` | 2           | Per-plant-type per-node time series. |
| `:avail_planttype_zonal` | 3           | Per-plant-type per-zone time series. |
| *(default)*              | 4 (lowest)  | Fixed value of `1.0` if no availability is provided. |

#### `:avail`

Wide format. Each column is named after a plant index; each row is one time step.

```csv
p1,p2,p3
0.1,0.2,1.0
0.8,0.9,1.0
0.7,0.8,1.0
```

A path to a **directory** is also accepted; all CSV files in the directory are loaded and merged.

!!! note "Index Linking"
    Column names must match plant indices from [File Structure `:plants`](@ref).

---

#### `:avail_planttype_nodal`

One file per plant type. The first column contains the plant type identifier (repeated for every row); remaining columns are named after nodes and contain the hourly availability factor.

```csv
plant_type,n1,n2,n3
solar,0.1,0.2,0.0
solar,0.8,0.9,0.0
solar,0.7,0.8,0.0
```

!!! danger "One plant type per file"
    Each file must contain exactly one unique value in the first column. Loading will fail with an error if multiple plant types are mixed in one file.

A path to a **directory** is also accepted; all CSV files in the directory are loaded.

!!! note "Index Linking"
    - The value in column 1 must match an `index` in [File Structure `:types`](@ref).
    - Remaining column names must match node indices in [File Structure `:nodes`](@ref).

---

#### `:avail_planttype_zonal`

One file per zone. The first column contains the zone identifier (repeated for every row); remaining columns are named after plant types and contain the hourly availability factor.

```csv
zone,solar,wind,coal
DE,0.1,0.4,1.0
DE,0.8,0.6,1.0
DE,0.7,0.8,1.0
```

!!! danger "One zone per file"
    Each file must contain exactly one unique value in the first column. Loading will fail with an error if multiple zones are mixed in one file.

A path to a **directory** is also accepted; all CSV files in the directory are loaded.

!!! note "Index Linking"
    - The value in column 1 must match a zone `index` in [File Structure `:zones`](@ref).
    - Remaining column names must match plant type indices in [File Structure `:types`](@ref).

---

### File Structure `:ntc`

Net Transfer Capacities between zones. One row per directional zone pair.

| Column   | Required | Type   | Description |
|----------|----------|--------|-------------|
| `zone_i` | ✔        | String | Exporting zone. |
| `zone_j` | ✔        | String | Importing zone. |
| `ntc`    | ✔        | Float  | Maximum transfer from `zone_i` to `zone_j` (MW). Rows with a missing `ntc` value are skipped with a warning. |

!!! note "Index Linking"
    `zone_i` and `zone_j` must match indices in [File Structure `:zones`](@ref).

#### Example
```csv
zone_i,zone_j,ntc
DE,FR,1000
FR,DE,800
```

---

### Prosumers: File Structure `:plants` (prosumer generators)

Prosumer generators are defined in the same file format as [File Structure `:plants`](@ref). The `plant_type` must map to a type with `prosumer = 1` in [File Structure `:types`](@ref).

---

### Prosumers: File Structure `:prs_demand`

Time series of prosumer demand. Wide format — one column per prosumer plant index, one row per time step. Also accepts the stacked format (columns `[id_col, plant_index, value]`).

```csv
prs_p1,prs_p2
20,5
10,8
30,12
0,0
```

!!! note "Index Linking"
    Column names must match plant indices of prosumer plants defined in [File Structure `:plants`](@ref).

---

### File Structure `:fuel_prices`

Time-varying fuel prices and CO₂ price. Wide format — one column per fuel type, one row per time step. No missing values are allowed.

| Column          | Description |
|-----------------|-------------|
| *(any string)*  | Fuel type name matching a `plant_type` entry in [File Structure `:types`](@ref), or `co2` for the carbon price. |

The column name must match either:
- a plant-type `index` from [File Structure `:types`](@ref) (overrides the fixed `fuel_price` set there), or
- the literal string `co2`, which is used as the CO₂ price in the marginal cost calculation (see [File Structure `:plants`](@ref) warning).

!!! note
    If `:fuel_prices` is omitted, fuel prices must be supplied via the `fuel_price` column in [File Structure `:types`](@ref) (as fixed profiles). The CO₂ price defaults to `0` if no `co2` column is present in either source.

#### Example
```csv
coal,gas,co2
25.0,45.0,30.0
25.0,47.0,31.0
26.0,46.0,30.5
```

---

### File Structure `:inflow`

Storage inflow time series (e.g. hydro natural inflow). Wide format — one column per storage plant index, one row per time step.

| Column         | Description |
|----------------|-------------|
| *(plant index)*| Storage plant identifier. Values are the hourly inflow (MWh). |

A path to a **directory** or a `Vector` of file paths is also accepted; all CSV files are loaded and merged into the same inflow table.

!!! note "Index Linking"
    Column names must match plant indices from [File Structure `:plants`](@ref) that have storage activated.

#### Example
```csv
hydro1,hydro2
120.0,85.0
115.0,90.0
130.0,80.0
```

---

### File Structure `:fixed_exchange`

Fixed (exogenous) power exchange schedules for one target zone. Wide format — one column per source zone, one row per time step. No missing values are allowed.

!!! warning "Single target zone"
    This file is intended to hold exchange flows **relative to a single target zone** (the zone whose balance is affected). Each column name is a counterpart zone. Using multiple target zones in one file is not supported.

| Column         | Description |
|----------------|-------------|
| *(zone index)* | Counterpart zone. Positive values = import into the target zone, negative = export. |

!!! note "Index Linking"
    Column names must match zone indices from [File Structure `:zones`](@ref).

#### Example
```csv
DE,FR
200.0,-100.0
150.0,-80.0
```

---

### File Structure `:historical_generation`

Historical (observed) generation by zone, used for model calibration or result comparison. Wide format — one column per zone, one row per time step. No missing values are allowed.

!!! warning "Zonal level"
    Data is expected at the **zonal** aggregation level. One file per target zone is the intended usage pattern.

| Column         | Description |
|----------------|-------------|
| *(zone index)* | Zone identifier. Values are historical generation totals (MWh). |

!!! note "Index Linking"
    Column names must match zone indices from [File Structure `:zones`](@ref).

#### Example
```csv
DE,FR
12000.0,8500.0
11800.0,8200.0
```

---





## Parameters
Based on the given input data, a Parameters struct is created.
```@docs
POMATWO.Parameters
```