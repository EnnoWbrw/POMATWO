# Visualizing Output Data
POMATWO supports different visualizations to analyze the model results. 
## Interactive Plots

### `plot_market_interactive(results; time_horizon=nothing, scalefactor=1/1000, kind=:DA)`
Creates an interactive plot for visualizing market results by zone, including generation dispatch, load, and price curves.

**Arguments**
- `results`: A data structure containing DA market simulation results (typically a `DataFiles` struct).
- `time_horizon`: (optional, keyword) A range of time steps (hours) to plot. If not provided, uses the entire time range in `results.GEN`.
- `scalefactor`: (optional, keyword, default: 1/1000) A scaling factor for power values (e.g., from MW to GW).
- `kind`: (optional, keyword, default: :DA) Specify what market stage should be visualized. Currently supported are `:DA` for Day-Ahead and `:REDISP` for Redispatch.
**Interactivity**
- Dropdown menu to select market zone.
- Plot updates automatically to show:
    - *Generation dispatch* (per technology)
    - *Load curve*
    - *Day-ahead price curve*
- Dual y-axes for power (GW) and price (EUR/MWh).

**Returns**
- `fig`: An interactive plot figure (`Makie.Figure`) for display or saving.

**Example**
```julia
fig = plot_market_interactive(results)
```



### `plot_DA_w_Redisp_interactive(results; time_horizon = nothing, scalefactor = 1/1000)`
Creates an interactive, comparative visualization of Day-Ahead (DA) and Redispatch market results by zone, showing generation, load, and prices before and after redispatch. This function enables side-by-side analysis of how redispatch alters zonal dispatch and market prices.

**Arguments**
- `results`: Data structure containing Day-Ahead and redispatch simulation results (typically a `DataFiles` struct).
- `time_horizon`: (optional, keyword) Range of time steps (hours) to plot. Defaults to the full time range in `results.GEN`.
- `scalefactor`: (optional, keyword, default: 1/1000) Factor to scale power values (e.g., MW to GW).

**Interactivity**
- Dropdown menu to select the market zone.
- The plot consists of two subplots:
    - *Top subplot:* Generation, load, and prices **after redispatch** (reflecting resolved network constraints).
    - *Bottom subplot:* Generation, load, and prices **in the Day-Ahead market** (as originally scheduled).
- Dual y-axes for both power (GW) and price (EUR/MWh).
- Plots update interactively when the selected zone changes.

**Returns**
- `fig`: The interactive plot (`Makie.Figure`) ready for display or saving.

**Example**
```julia
fig = plot_DA_w_Redisp_interactive(results)
```


### `plot_total_gen_interactive(results::DataFiles)`
Create an interactive bar plot of total generation by category for a selected `kind` and `zone`.

This function displays an interactive Makie figure with two dropdown menus: one for selecting the generation `kind` (e.g., day-ahead, redispatch, etc.) and one for selecting the `zone`. The bar plot updates automatically to reflect the selected `kind` and `zone`, showing total generation per category in GWh with category-specific colors.

**Arguments**
- `results`: The results data structure containing generation data, available kinds, zones, and category colors.

**Returns**
- `Figure`: A Makie Figure object with the interactive bar plot and dropdown menus.

**Example**
```julia
fig = plot_total_gen_interactive(results)
```

## Static Plots
