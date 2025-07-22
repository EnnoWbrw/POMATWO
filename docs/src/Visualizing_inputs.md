# Visualizing Input Data
## Interactive Plots
## Static Plots

### `plot_network(data::Dict{Symbol,String})`

Plots a simple network map of an energy system using line and node geographical data. AC and DC transmission lines are shown as straight connections between nodes, and all network nodes are marked.

 **Arguments**
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref))

 **Plot Details**
- *AC lines* are drawn as solid black lines.
- *DC lines* are drawn as dashed black lines.
- *Nodes* are plotted as black points.

**Returns**
- `fig`: The Makie figure object containing the network plot.

**Example**
```julia
datafiles = Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)

using GLMakie, ColorSchemes, Tyler

fig = plot_network(datafiles)
```

