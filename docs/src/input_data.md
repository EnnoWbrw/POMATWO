# Model Data
## Input Data Load
```@docs
load_data(data::Dict)
```

## Model Input Data Structure
The data that is read in using the [load_data](@ref) function has to be provided via seperate csv files. In the following section, the structure of those files is described. Generally the column headers have to be identical to what is described as `Column` in the tables below. Table rows are created to add a data entry and should follow thy `type` convention also specified below.
### Data Structure: `plants.csv`

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

### Notes
- Plants without storage systems have `storage_capacity = 0` and `storage_power = NaN`.
- The `eta` column may represent conversion efficiency or a binary indicator, depending on the modeling context.

---

### Data Structure: `planttypes.csv`

Describes properties of each plant type used in the system.

| Column         | Type    | Description |
|----------------|---------|-------------|
| `index`        | String  | Name of the plant type (e.g., `coal`, `wind`). |
| `dispatchable` | Integer | Indicates if the plant type is dispatchable (`1`) or not (`0`). |
| `storage`      | Integer | Indicates if the plant type has storage capability (`1`) or not (`0`). |
| `fuel_price`   | Integer | Fuel cost (arbitrary units or €/MWh). |
| `co2content`   | Integer | CO₂ emissions per unit of energy. |
| `prosumer`     | Integer | Indicates if the plant type supports prosumer behavior (`1`) or not (`0`). |
| `color`        | String  | Hex color code used for visualization. |

---

### Data Structure: `zones.csv`

Specifies the geographic or administrative zones involved in the model.

| Column  | Type   | Description |
|---------|--------|-------------|
| `index` | String | Identifier for the zone (e.g., `DE`). |

---

### Data Structure: `nodes.csv`

Defines all nodes in the network along with their geographic and zone information.

| Column    | Type    | Description |
|-----------|---------|-------------|
| `index`   | String  | Node identifier. |
| `zone`    | String  | Zone the node belongs to. |
| `name`    | String  | Human-readable node name. |
| `lat`     | Float   | Latitude coordinate. |
| `lon`     | Float   | Longitude coordinate. |
| `slack`   | Integer | Indicator for slack bus (`1` if slack, otherwise `0`). |

---

### Data Structure: `nodal_load.csv`

Contains the time series of load demand at each node.

| Column | Type    | Description |
|--------|---------|-------------|
| `n1`   | Integer | Load demand in MW at node `n1` for each time step. *(Example shown; actual structure may include multiple nodes.)* |
| `n2`   | Integer | Load demand in MW at node `n2` for each time step. *(Example shown; actual structure may include multiple nodes.)* |
| `...`   | Integer | Load demand in MW at node `nx` for each time step. *(Example shown; actual structure may include multiple nodes.)* |
---

### Data Structure: `lines.csv`

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

---

### Data Structure `dclines.csv`

Placeholder table for DC transmission lines. Currently contains no entries.

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

## Parameters
Based on the given input data, a Parameters struct is created.
```@docs
POMATWO.Parameters
```