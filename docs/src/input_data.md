# Model Data

## Input Data Load
```@docs
load_data(data::Dict)
```

## Model Input Data Structure
The data that is read in using the [load_data](@ref) function has to be provided via seperate csv files. In the following section, the structure of those files is described. Generally the column headers have to be identical to what is described as `Column` in the tables below. Table rows are created to add a data entry and should follow thy `type` convention also specified below.

### File Structure `:plants`

Describes information about power plants and their attributes. Each row represents a different plant with the following columns:

| Column             | Type     | Description |
|--------------------|----------|-------------|
| `index`            | String   | Unique identifier for the plant. |
| `plant_type`       | String   | Type of power plant (e.g., wind, coal, etc.). |
| `node`             | String   | Identifier for the network node to which the plant is connected. |
| `g_max`            | Integer  | Maximum generation capacity of the plant (in MW). |
| `eta`              | Integer  | Efficiency factor or binary flag for participation (typically 0 or 1). |
| `storage_capacity` | Integer  | Maximum storage capacity (in MWh), 0 if not applicable. |
| `lat`              | Float    | Latitude of the plant's location. |
| `lon`              | Float    | Longitude of the plant's location. |
| `storage_power`    | Float    | Power limit of the storage system (in MW), may be `NaN` if not applicable. |

### Example
```Julia
| index | plant_type | node | g_max | eta | storage_capacity | lat       | lon        | storage_power |
|-------|------------|------|-------|-----|------------------|-----------|------------|----------------|
| p1    | wind       | n1   | 140   | 1   | 0                | 49.978037 | 9.066645   |                |
| p2    | coal       | n2   | 300   | 1   | 0                | 51.489714 | 10.413338  |                |
```

!!! note
    Plants without storage systems have `storage_capacity = 0` and `storage_power = NaN`.

    The `eta` column may represent conversion efficiency or a binary indicator, depending on the modeling context.

---

### File Structure `:types`

Planttypes are described as follows:

| Column         | Type    | Description |
|----------------|---------|-------------|
| `index`        | String  | Name of the plant type (e.g., `coal`, `wind`). |
| `dispatchable` | Integer | Indicates if the plant type is dispatchable (`1`) or not (`0`). |
| `storage`      | Integer | Indicates if the plant type has storage capability (`1`) or not (`0`). |
| `fuel_price`   | Integer | Fuel cost (arbitrary units or €/MWh). |
| `co2content`   | Integer | CO₂ emissions per unit of energy. |
| `prosumer`     | Integer | Indicates if the plant type supports prosumer behavior (`1`) or not (`0`). |
| `color`        | String  | Hex color code used for visualization. |

### Example
```Julia
| index    | dispatchable | storage | fuel_price |
|----------|--------------|---------|------------|
| coal     | 1            | 0       | 25         |
| wind     | 1            | 0       | 7          |
```

---

### File Structure `:avail`, `:avail_planttype_nodal`, `:avail_planttype_zonal`

Availabilities for each time step can be defined. If no availabilities are defined the default of `1.0`is assumed. The values are used to scale the maximum generation or operational capacity of a plant or unit for each time step.

| Column   | Type    | Description |
|----------|---------|-------------|
| `prs_n1` | Float64 | Availability factor (between `0.0` and `1.0`) for the prosumer unit at node `n1`. This represents the fraction of maximum capacity that is available at each time step. |

### Example :avail
```Julia
| prs_n1 |
|--------|
| 0.1    |
| 0.8    |
| 0.7    |
| 0      |
```

!!! note
    Each row corresponds to a different time step.

    The column name (`prs_n1`) corresponds to a prosumer identifier and may vary or be part of a larger dataset with multiple columns (e.g., `prs_n1`, `prs_n2`, etc.).

    A value of `1.0` means full availability; `0.0` means the unit is unavailable at that time.

---

### File Structure `:demand`

Contains the time series of load demand at each node.

| Column | Type    | Description |
|--------|---------|-------------|
| `n1`   | Integer | Load demand in MW at node `n1` for each time step. *(Example shown; actual structure may include multiple nodes.)* |
| `n2`   | Integer | Load demand in MW at node `n2` for each time step. *(Example shown; actual structure may include multiple nodes.)* |
| `...`   | Integer | Load demand in MW at node `nx` for each time step. *(Example shown; actual structure may include multiple nodes.)* |

### Example
```Julia
| n1  |
|-----|
| 60  |
| 100 |
| 120 |
| 180 |

```

---

### File Structure `:zones`

Specifies the geographic or administrative zones involved in the model.

| Column  | Type   | Description |
|---------|--------|-------------|
| `index` | String | Identifier for the zone (e.g., `DE`). |

### Example 
```Julia
| index  |
|--------|
| DE     |
```
---

### File Structure `:nodes`

Defines all nodes in the network along with their geographic and zone information.

| Column    | Type    | Description |
|-----------|---------|-------------|
| `index`   | String  | Node identifier. |
| `zone`    | String  | Zone the node belongs to. |
| `name`    | String  | Human-readable node name. |
| `lat`     | Float   | Latitude coordinate. |
| `lon`     | Float   | Longitude coordinate. |
| `slack`   | Integer | Indicator for slack bus (`1` if slack, otherwise `0`). |

### Example 
```Julia
| index  | zone | name                 | lat        | lon        | slack |
|--------|------|----------------------|------------|------------|-------|
| n1     | DE   | MUHLBACH             | 47.907355  | 7.555917   | 1     |
| n2     | DE   | Y-Otterbach          | 49.487800  | 7.722690   | 0     |
| n3     | DE   | Salzburg Elixhausen  | 47.868229  | 13.076006  | 0     |
```
---

### File Structure `:lines`

Describes the properties of AC transmission lines between nodes.

| Column        | Type    | Description |
|---------------|---------|-------------|
| `NE_name`     | String  | Line name. |
| `node_i`      | String  | From-node ID. |
| `node_j`      | String  | To-node ID. |
| `voltage`     | Integer | Nominal voltage level (kV). |
| `r`           | Float   | Line resistance (Ohms). |
| `x`           | Float   | Line reactance (Ohms). |
| `b`           | Integer | Line susceptance (unitless). |
| `I_nom`       | Integer | Nominal current rating. |
| `capacity`    | Integer | Transmission capacity (MW). |
| `index`       | String  | Line identifier (typically same as `NE_name`). |
| `lat_i`       | Float   | Latitude of from-node. |
| `lon_i`       | Float   | Longitude of from-node. |
| `lat_j`       | Float   | Latitude of to-node. |
| `lon_j`       | Float   | Longitude of to-node. |
| `node_i_name` | String  | Name of from-node. |
| `node_j_name` | String  | Name of to-node. |

### Example 
```Julia
| NE_name | node_i | node_j | voltage |   r    |    x    | b | I_nom | capacity | index |   lat_i   |   lon_i   |   lat_j   |   lon_j   | node_i_name | node_j_name |
|---------|--------|--------|---------|--------|---------|---|--------|----------|--------|-----------|-----------|-----------|-----------|--------------|--------------|
| l1      | n1     | n2     | 220     | 4.0937 | 18.349  | 1 | 790    | 30       | l1     | 47.907355 | 7.555917  | 49.487800 | 7.722690  | Eula         | Roehrsdorf   |
| l2      | n2     | n3     | 220     | 7.5895 | 31.888  | 1 | 790    | 100      | l2     | 49.487800 | 7.722690  | 47.868229 | 13.076006 | Roehrsdorf   | Weida        |
| l3      | n1     | n3     | 220     | 7.5895 | 31.888  | 1 | 790    | 100      | l3     | 47.907355 | 7.555917  | 547.868229| 13.076006 | Weida        | Eula         |
```

---

### File Structure `:dclines`

Describes the properties of DC transmission lines between nodes.

| Column     | Type   | Description |
|------------|--------|-------------|
| `index`    | String | Line identifier. |
| `node_i`   | String | From-node ID. |
| `node_j`   | String | To-node ID. |
| `lat_i`    | String | Latitude of from-node. |
| `lon_i`    | String | Longitude of from-node. |
| `lat_j`    | String | Latitude of to-node. |
| `lon_j`    | String | Longitude of to-node. |
| `capacity` | String | Capacity of the DC line. |

### Example 
```Julia
| index   | node_i | node_j | lat_i | lon_i   | lat_j  | lon_j  | capacity |
|---------|--------|--------|--------|--------|--------|--------|----------|
```
---

### Prosumers: File Structure `:prs_demand`

Contains the time series demand for prosumer nodes.

| Column   | Type    | Description |
|----------|---------|-------------|
| `prs_n1` | Integer | Electricity demand (in MW) for the prosumer at node `n1` for each time step. *(Additional prosumer columns may be present in the full dataset.)* |

### Example
```Julia
| prs_n1 |
|--------|
| 20     |
| 10     |
| 30     |
| 0      |
```

---


### Prosumers: File Structure generation

Prosumer generators are described analogously to plants [File Structure :plants](@ref).



## Parameters
Based on the given input data, a Parameters struct is created.
```@docs
POMATWO.Parameters
```