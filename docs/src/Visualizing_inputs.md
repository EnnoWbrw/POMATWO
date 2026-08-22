# Visualizing Input Data
## Interactive Plots
## Static Plots

### `plot_network(data::Dict{Symbol,String})`

Plots a simple network map of an energy system using line and node geographical data. AC and DC transmission lines are shown as straight connections between nodes, and all network nodes are marked.

 **Arguments**
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref))

 **Keyword arguments**
- `map_axis`: (default `true`) map-axis styling — `true`, `false` for a bare axis, or a `NamedTuple` such as `(scalebar = false,)`. See [Map axes](@ref).

 **Plot Details**
- *AC lines* are drawn as solid black lines.
- *DC lines* are drawn as dashed black lines.
- *Nodes* are plotted as black points.
- The axis is a map axis: degree ticks, `Longitude`/`Latitude` labels, a kilometre scale bar and a north arrow — see [Map axes](@ref) for the CRS statement the figure caption needs.
- If every node in the file sits on `lon = lat = 0`, the nodes collapse onto the mercator origin and none of the map decorations are drawn.

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

