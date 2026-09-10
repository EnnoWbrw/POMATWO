# Visualizing Output Data
POMATWO supports different visualizations to analyze the model results. 

## Map axes
Every network map in the plotting extension — `create_lineplot`, `plot_network`, `plot_capacity_network`, `plot_line_utils_interactive` and `plot_shift_map_interactive` — is drawn in Web Mercator, the projection Tyler's raster tiles exist in, and shares one axis style:

- Ticks are labelled in **degrees** (`10°E`, `5.5°W`, `52°N`), not in projected metres, and the axes are labelled `Longitude` and `Latitude`.
- Each map carries a **kilometre scale bar** and a **north arrow**. On the interactive maps both follow zoom and pan, as do the degree ticks.
- The projection is **not** written on the figure by default, so that the axis subtitle stays free for scenario text. State the CRS in the figure caption instead: **`WGS 84 / Pseudo-Mercator (EPSG:3857)`** — or pass `map_axis = (projection_note = true,)` to put it in the subtitle.
- Mercator scale is **latitude-dependent**. The scale bar is computed for the centre latitude of the current view, so it is exact only at that latitude; across a north–south extent of several hundred kilometres read it as an approximation. (North is up everywhere in Mercator, so the north arrow needs no such caveat.)
- Turning the basemap off (`background_map = false`) removes only the raster tiles — the axis stays geographic and keeps all of the above.
- A network whose nodes carry **no coordinates at all** gets none of the decorations — degrees, a scale bar and a north arrow would each be a fabrication there. `plot_capacity_network` and `plot_shift_map_interactive` additionally lay the nodes out on a circle and note the fallback in the axis subtitle; `create_lineplot`, `plot_network` and `plot_line_utils_interactive` have no such fallback and draw every node on the mercator origin, so for them the suppressed decorations are the only signal.

### Controlling the styling: the `map_axis` keyword
Every entry point that produces a map (`create_lineplot`, `plot_network`, `plot_capacity_network`, `plot_line_utils_interactive`, `plot_shift_map_interactive`) takes an optional `map_axis` keyword and forwards it unchanged:

```julia
map_axis = true                          # default — full styling
map_axis = false                         # bare axis: raw Web Mercator metre ticks, no labels,
                                         # no scale bar, no north arrow
map_axis = (scalebar = false,)           # styling minus the bar
map_axis = (projection_note = true,)     # add the CRS as the axis subtitle
map_axis = (north_arrow_position = :lt,) # relocate the arrow
```

A `NamedTuple` is splatted into the internal styling function, so its five fields are all reachable without every signature growing five keywords:

| field | default | meaning |
|---|---|---|
| `scalebar` | `true` | draw the kilometre scale bar |
| `north_arrow` | `true` | draw the north arrow |
| `projection_note` | `false` | put `WGS 84 / Pseudo-Mercator (EPSG:3857)` in the axis subtitle |
| `scalebar_position` | `:rb` | corner of the bar: `:rb`, `:lb`, `:rt`, `:lt` |
| `north_arrow_position` | `:rt` | corner of the arrow: `:rt`, `:lt`, `:rb`, `:lb` |

Anything that is neither a `Bool` nor a `NamedTuple`, and any unknown `NamedTuple` field, raises an `ArgumentError` naming the accepted values — before a window opens or a tile is fetched.

!!! note "`map_axis` is a request, not an override"
    Whether the axis is geographic at all is decided by the data, not by this keyword. On a dataset whose nodes carry no coordinates, degrees, a scale bar and a north arrow would every one of them be a fabrication, so **`map_axis = true` still draws nothing there**. The keyword can only ever subtract from, or reconfigure, styling that the data has already earned.

Two interactions worth knowing:

- `projection_note = true` writes the axis subtitle. In `plot_line_utils_interactive` the subtitle is also the live colour/width key, which is rewritten on every slider move — so the CRS note is overwritten there almost immediately. Put the CRS in the caption for that plot.
- `plot_capacity_network` and `plot_shift_map_interactive` use the subtitle for their no-coordinates note, but only on the fallback layout, which is never styled anyway.

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

**Reading the stack**

Upward and downward bands are not the same kind of quantity, and the difference matters:

- *Upward, below the thin black rule*: the energy balance — dispatch per technology, lost load `LL`, and the zonal `exchange` when the zone imports.
- *Downward*: the remaining balance terms — storage charging and `exchange` when the zone exports. Summing these and subtracting from the upward stack gives the zonal load.
- *The pale `CU` cap above the rule*: curtailment. This is **not** a balance term. `GEN` in the results is already the post-curtailment feed-in (`FEEDIN = avail * gmax − CU`), so per non-dispatchable plant `GEN + CU` recovers `avail * gmax`, the full renewable potential. The cap is therefore the gap between what the technology could have delivered and what it did.

Because the cap sits outside the balance, the total stack height is balance + curtailment; reading it as delivered energy would overstate it. Curtailment is aggregated into a single `CU` series rather than split per technology, so the cap does not identify *which* technology was curtailed — use `results.GEN` for that.

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

Both subplots stack the same way as `plot_market_interactive` — see *Reading the stack* above. In the redispatch subplot the `Net injection` band replaces `exchange`, and the `CU` cap is `CU_REDISP`, for which the same identity holds (`GEN_REDISP + CU_REDISP = avail * gmax`).

**Returns**
- `fig`: The interactive plot (`Makie.Figure`) ready for display or saving.

**Example**
```julia
using GLMakie, Tyler, ColorSchemes
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
using GLMakie, Tyler, ColorSchemes
fig = plot_total_gen_interactive(results)
```


### `plot_line_utils_interactive(results_path; kwargs...)`
Interactive geographical map of transmission line utilization — the interactive counterpart of `create_lineplot`. Line color is `|flow| / line_capacity` aggregated over a selectable time window and line width is `line_capacity` itself — colour is a ratio, so on its own it draws a saturated distribution line and a saturated interconnector identically. DC lines are drawn dashed. Each line also carries a chevron showing the flow direction in that window, and the nodes carry one of two keys: on a redispatch state the nodal injection *change* the redispatch measures cause, on every other state the nodal *net injection* itself.

**Arguments**
- `results_path`: Path to the directory containing simulation results, or an `AbstractDict` mapping menu labels to already-loaded `DataFiles` objects.

**Keyword arguments**
- `data`: (default `nothing`) A dictionary of input file paths (see section [Input Data Load](@ref)). If given, node coordinates and line endpoints are read from the CSVs instead of from `params`.
- `exclude_dc_lines`: (default `false`) If `true`, only AC lines are visualized.
- `threshold`: (default `0.95`) Initial threshold (0-1 scale) of the counting mode.
- `mode`: (default `:avg`) Initial aggregation mode, `:avg`, `:hours` or `:flowsum`.
- `scale`: (default `:window`) Initial colour-scale reference of the average mode, `:window` or `:horizon`. Pass `:horizon` to make two figures of the same market state directly comparable.
- `state`: (default `nothing`) Initially selected market state; `nothing` selects the last stage of the pipeline.
- `background_map`: (default `true`) Draw Tyler/CartoDB raster tiles behind the network. The axis stays a map axis either way: degree ticks, `Longitude`/`Latitude` labels, scale bar and north arrow do not depend on the tiles.
- `extent`: (default `nothing`) Map window; `nothing` fits it to the node coordinates.
- `map_axis`: (default `true`) map-axis styling — `true`, `false` for a bare axis, or a `NamedTuple` such as `(scalebar = false,)`. See [Map axes](@ref).
- `show_redisp`: (default `true`) Enable the redispatch node markers.
- `redisp_ref`: (default `nothing`) Pin the marker reference magnitude in MWh instead of using the largest value in the selected window — use it to make two figures comparable.
- `show_injection`: (default `true`) Enable the net-injection arrows on market states without a `REDISP` table.
- `injection_ref`: (default `nothing`) Pin the arrow reference magnitude in MW — the `redisp_ref` of the arrows.
- `show_flow_direction`: (default `true`) Draw the per-line flow-direction arrowheads.
- `arrow_scale`: (default `1.0`) Multiplier on the arrow lengths, which are otherwise a fixed fraction of the node bounding box.
- `linewidth_by_capacity`: (default `true`) Scale line width with `line_capacity`. Set `false` to draw every line at `linewidth`, as before.
- `linewidth_range`: (default `(0.6, 4.5)`) Width of a zero-capacity and of the largest line. Capacity maps onto it proportionally, floored at the low end so a line whose capacity is zero or unknown stays hairline rather than vanishing.
- `figsize`, `linewidth` (only when `linewidth_by_capacity = false`), `max_markersize`, `min_markersize`, `zero_tol`.

**Interactivity**
- *Market state menu*: one entry per pipeline stage that wrote a `LINEFLOW` table under `results_path` (`TwoDayAhead`, `DayAhead`, `ProsumerOptimizationState`, `Redispatch`, whichever are present). Every stage writes one, including a zonal day-ahead, whose nodal flows are reported from the cleared dispatch. Result directories written before per-stage result prefixes existed offer a single composite entry. States are loaded lazily and cached on first selection.
- *Time window slider*: an `IntervalSlider` over the model horizon; drag the two handles together for a single timestep. It starts on the full horizon, so the initial view reproduces `create_lineplot`.
- *Aggregation menu*:
    - `"average utilization"`: mean utilization over the window.
    - `"hours ≥ threshold"`: count of timesteps in the window at or above the threshold, colorbar 0 to the window length. This is the mode `create_lineplot` calls `type = "max"`.
    - `"absolute power flow sum"`: total Σ|flow| per line over the window, in MWh, independent of line capacity. Colour scale is always adaptive to the current window — the colour-scale menu below has no effect on this mode, same as the counting mode.
- *Colour scale menu* (average mode only): what the top of the colorbar means. Utilization above 1 is real rather than an artefact — a zonal day-ahead has no nodal variables, so its flows are reported from the cleared dispatch **without** applying line limits, and the overload is exactly what redispatch then resolves. Both settings floor the maximum at 1, so an uncongested state is not stretched to look loaded, and the active range is printed in the axis subtitle, which carries the live colour and width key.
    - `"adaptive (this window)"` (default): 0 to max(1, peak of the current window). Best contrast within a single view, but the scale moves while the slider is dragged, so two windows cannot be compared by colour.
    - `"fixed (whole horizon)"`: 0 to max(1, the largest single-timestep utilization in the state) — the only reference that can never clip, whatever window is selected. The cost is contrast, because a wide window averages peaks away: on a 168 h day-ahead run the worst single hour reaches 4.9 while the worst full-horizon average is 1.6, so the default view uses only the lower part of the colormap under this setting.

    The counting mode always scales to the window length, which is its natural ceiling; a horizon-wide count scale would render a short window as a single dark step.
- *Threshold slider*: the threshold of the counting mode, in 1 % steps.

**Node markers**

The nodes carry one of two mutually exclusive keys, depending on the selected market state. Below the legend, the size scale gives the reference magnitudes for the current window — MWh for the circles, MW for the arrows.

*Redispatch circles.* On a market state that carries a `REDISP` table, each node is drawn as a circle colored by the nodal net-injection change caused by the redispatch measures over the selected window — green for an increase (net upward redispatch), red for a decrease, gray for ≈ 0 — with marker **area** proportional to the magnitude in MWh.

The change is `Δinjection = (GEN_UP − GEN_DOWN) − (CHARGE_UP − CHARGE_DOWN)` summed over the plants at each node, in the export-positive (feed-in) convention: charging is a withdrawal, so additional storage charging *lowers* a node's injection. Note that the persisted `NETINPUT`/`ACINJECTION` result columns use the opposite, import-positive convention.

*Net-injection arrows.* On every other market state, each node carries a vertical arrow for its own net injection, `gen − load − charge`, averaged over the selected window in **MW** — green pointing up where the node generates more than it consumes, red pointing down where it consumes more, a gray dot at ≈ 0. Arrow **length** is proportional to the magnitude, linearly rather than by area as the circles are, because length is a linearly perceived channel where marker area is not. Lengths are in map coordinates, so the arrows stay anchored to the map under zoom, while the arrowheads are in pixels and keep a constant screen size.

The values are the negated `NETINPUT` column, which every stage writes — a zonal day-ahead has no nodal variables, but its net input is reported from the cleared dispatch.

**Flow direction**

Each line carries an open `>` chevron at its midpoint pointing the way power flows in the selected window, taken from the **signed** flow sum. It is an unfilled stroke rather than a solid arrowhead on purpose: there is one per line against only a handful of node arrows, so filled heads would bury the line colours. A line whose flow reverses inside the window can cancel to ≈ 0; that is a real statement about the window (no net transfer), so the chevron is dropped rather than forced one way. In the model's sign convention a positive `LINEFLOW` runs from the line's `line_start` node to its `line_end` node.

**Returns**
- `fig`: An interactive plot figure (`Makie.Figure`) for display or saving.

**Example**
```julia
using GLMakie, Tyler, ColorSchemes, Colors

results_path = joinpath("results", scen_name)
fig = plot_line_utils_interactive(results_path)

# start on the congestion view, AC lines only
fig = plot_line_utils_interactive(results_path;
                                  mode = :hours, threshold = 0.9, exclude_dc_lines = true)

# compare two explicitly loaded stages
fig = plot_line_utils_interactive(Dict(
    "day-ahead"  => DataFiles(results_path, DayAhead),
    "redispatch" => DataFiles(results_path, Redispatch)))
```


## Reference-Day Plots

These two figures visualize a [`ReferenceDayBasecase`](@ref) run and require a run whose reference-day trace was collected (`REFDAY_SHIFT`, `REFDAY_MATCH` and `REFDAY_GROUPS` in the result tables).

### `plot_shift_map_interactive(results; kwargs...)`
Geographical map of the ShareShift impact for one reference-day scenario. The network topology is drawn with AC lines solid and DC lines dashed, plus one circle per node: green for a net injection increase, red for a decrease, gray for ≈ 0, with marker area proportional to `|Σ delta|` in the selected time window.

Deltas follow the injection convention of `REFDAY_SHIFT`: for the `load` component a positive delta means a load *decrease*. The `"total"` entry sums the real nodal components (`RES_prestep`, `load_prestep`, `RES`, `conv`, `load`, `sto`, `balance`); the per-zone `np_relax` residual is not a nodal delta and is reported in the info label only.

If **no** node in the run carries coordinates, the nodes are laid out on a circle instead, the basemap is suppressed and none of the map decorations are drawn (noted in the axis subtitle). Topology, line styling and the node markers all still read correctly; only the geography is gone. While *some* node has coordinates the behaviour is unchanged: a node without them cannot be placed and its deltas are dropped, with a warning naming the total dropped MW.

**Line layer.** The AC lines can be coloured by the assembled reference-day basecase flow, read from `REFDAY_LINEFLOW`: `none` (flat grey, the default), `|flow| (MW)`, `utilization` (`|flow| / fmax`), `|F0| (MW)` or `|F0| / fmax`. The two `F0` modes recompute the flow-based intercept from that same basecase under the GSK selected in the GSK menu ([`refday_f0`](@ref)), over **every** AC line rather than only the CNEs — the CNE list is itself a property of the run's own GSK, so it is the wrong filter for the question "what would the domain look like under a different one".

The GSK menu is populated from [`gsk_strategies`](@ref), which discovers every zero-argument `GSKStrategy` at call time; a strategy added to POMATWO later shows up without this plot being edited. A strategy needing constructor arguments (`CustomWeightsGSK`) is passed in through `gsk_options` instead.

`F0` is the intercept of a linearization, not a physical flow, so `|F0| > fmax` is legitimate — the colour scale does not clamp it and no overload is implied. DC lines stay dashed grey in every mode, because `REFDAY_LINEFLOW` covers AC lines only, and an AC line the basecase has no flow for sits at the bottom of the scale.

The `hours ≥ threshold` aggregation always compares against `|value| / fmax`, in the MW modes too: a threshold in MW would mean nothing across a network of mixed ratings.

**Arguments**
- `results`: A `DataFiles` object of a reference-day run.

**Keyword arguments**
- `figsize`: (default `(1250, 1100)`)
- `background_map`: (default `true`) Draw Tyler/CartoDB raster tiles. The axis stays a map axis without them.
- `exclude_dc_lines`: (default `false`)
- `extent_pad`: (default `0.5`) Padding of the auto-fitted map window, in degrees.
- `map_axis`: (default `true`) map-axis styling — `true`, `false` for a bare axis, or a `NamedTuple` such as `(scalebar = false,)`. See [Map axes](@ref).
- `max_markersize`, `min_markersize`, `zero_tol`.
- `line_value`: (default `:none`) initial line mode — `:none`, `:flow`, `:utilization`, `:f0`, `:f0_utilization`.
- `line_agg`: (default `:mean`) — `:mean`, `:hours`, `:sum`.
- `line_scale`: (default `:window`) colour reference — `:window` (adaptive to the visible window) or `:horizon` (fixed over the whole horizon).
- `threshold`: (default `0.8`) initial utilization threshold of the `hours ≥ threshold` mode.
- `gsk`: (default `nothing` → `FlatGSK`) initially selected GSK, as a `GSKStrategy` or its type name.
- `gsk_options`: (default `gsk_strategies()`) the strategies the GSK menu offers.
- `linewidth`, `linewidth_by_capacity` (default `true`), `linewidth_range` (default `(0.6, 4.5)`).

**Interactivity**
- *Component menu*: `total` or an individual shift component (node markers).
- *Line value / GSK / Aggregation / Colour scale menus and threshold slider*: the line layer.
- *`IntervalSlider`*: a single timestep (handles together) or the sum over a window.

**Returns**
- `fig`: An interactive plot figure (`Makie.Figure`).

**Example**
```julia
using GLMakie, Tyler, ColorSchemes, Colors

variant = DataFiles(joinpath("results", "refday_gsk"))
fig = plot_shift_map_interactive(variant)

# open straight on the F0 domain under a capacity-weighted GSK
fig = plot_shift_map_interactive(variant;
                                 line_value = :f0_utilization, gsk = GmaxGSK())
```

### `plot_refday_dispatch_interactive(variant, source; kwargs...)`
Single-timestep comparison of one zone's dispatch across the reference-day pipeline, as four stacked bars:

1. **`ref`** — the source (basecase) run's dispatch at the reference hour matched to the selected timestep.
2. **`shift`** — the ShareShift decomposition at that timestep, one black-stroked segment per REFDAY_SHIFT component (`ΔRES_prestep`, `Δload_prestep`, `ΔRES`, `Δconv`, `Δload`, `Δsto`, `Δbalance`).
3. **`shifted ref`** — bar 1 plus bar 2, with the deltas merged into the bar's own categories.
4. **market result** — the dispatch of the market state picked in the `Market state` menu, at the same timestep.

**Sign convention.** Every segment is an export-positive net-position contribution: generation and storage discharge stack upward, load and storage charging downward, and a shift delta lands on the axis matching its effect on the net position. `REFDAY_SHIFT` is already in that convention — a positive `load` delta is a load *decrease* — so a load decrease appears on the positive axis and a load increase on the negative one, exactly as a generation increase and decrease do. The net-position marker of a bar is therefore the algebraic sum of its segments, and bar 3 is a plain per-category addition of bars 1 and 2.

**Categories.** Bars 1, 3 and 4 are stacked in `conventional` / `RES` / `storage` / `load`, plus `balance`, which only the shift produces. Plants are classified by the same function the reference-day basecase uses, driven by `matching.res_tags` — pass the run's own `MatchingConfig` and the conventional/RES/storage split is the one the shift itself applied.

**Reading a state's dispatch.** Which table holds a state's dispatch differs by state, so the plot delegates to the shift's own accessors (`POMATWO._source_gen` / `_source_charge`) rather than reading `.GEN` itself. The day-ahead and `TwoDayAhead` states write `GEN` and `CHARGE`; **the redispatch stage writes neither** — its dispatch is `GEN_REDISP` / `CHARGE_REDISP` inside the `REDISP` table (`Redispatch_REDISP.arrow`), and there is no `Redispatch_GEN.arrow`. This matters twice: a redispatch `source` needs `source_type = "REDISP"`, and `Redispatch` is discovered for the state menu through its `REDISP` table.

**Arguments**
- `variant`: A `DataFiles` object of the reference-day run.
- `source`: A `DataFiles` object of the source (forecast) run, loaded with the **same market state** the `ReferenceDayBasecase` used — e.g. `DataFiles(dir, TwoDayAhead)` for `source_type = "2DA"`. Loading a different stage silently compares against the wrong baseline.

**Keyword arguments**
- `matching`: (default `MatchingConfig()`) The run's matching config. Only `res_tags` is read.
- `source_type`: (default `""`) Which market state `source` was loaded for — the same string the `ReferenceDayBasecase` was given (`""`/`"DA"`, `"2DA"`, `"REDISP"`, or a canonical state name). It decides which columns bar 1 is read from; a mismatch raises an error naming the state instead of drawing an empty bar.
- `results_dir`: (default `""`) Results directory whose market states fill the `Market state` menu; the states are discovered from the stage-prefixed result files. Without it the menu holds the passed `variant` alone.
- `scalefactor`: (default `1/1000`) Factor to scale power values (MW to GW).
- `figsize`: (default `(1300, 850)`)
- `px_per_unit`: (default `2`) Resolution multiplier of the PNG export.
- `export_path`: (default `"refday_dispatch.png"`) Path prefilled into the export textbox.
- `export_figsize`: (default `(1000, 650)`) Size of the exported figure, which carries no controls and so needs less width than the interactive one.

**Interactivity**
- Dropdown menu to select the market zone.
- Dropdown menu to select the market state drawn as bar 4.
- Slider selecting the single timestep shown.
- Export of the current view: a format menu, a path textbox and an `Export view` button. What is written is the **plotted area alone** — axis, legend and caption — rebuilt as a static figure, so the menus, textbox, button and slider (which live in the same `Figure`) stay out of the file. PNG is always available; `pdf` and `svg` appear in the menu only when `CairoMakie` is loaded in the session, since GLMakie cannot write vector formats. The result — the written path, or the error — is reported under the info label.

**Returns**
- `fig`: An interactive plot figure (`Makie.Figure`).

**Example**
```julia
using GLMakie, Tyler, ColorSchemes, Colors
using CairoMakie   # optional, unlocks the pdf/svg export formats

variant = DataFiles(joinpath("results", "refday_gsk"))
source  = DataFiles(joinpath("results", "forecast"), TwoDayAhead)
fig = plot_refday_dispatch_interactive(
    variant, source;
    source_type = "2DA",
    results_dir = joinpath("results", "refday_gsk"),
    matching = MatchingConfig(res_tags = ["solar", "wind"]))

# a redispatch basecase source: its dispatch lives in REDISP, not GEN
source = DataFiles(joinpath("results", "forecast"), Redispatch)
fig = plot_refday_dispatch_interactive(variant, source; source_type = "REDISP")
```


## Static Plots

### `create_lineplot(results_path, data, type="max", exclude_dc_lines=false, threshhold=0.95)`
Creates a geographical network map showing transmission line utilization with color-coded lines based on either maximum utilization frequency or average utilization.

`create_lineplot` has two methods. Drop the `data` argument — `create_lineplot(results_path, "avg")` — to read the line geometry from `results.params` instead of from the input CSVs; everything described here applies to both. The `data` argument is untyped, so pass it as a `Dict{Symbol,String}`: a `String` in that position is taken for the `type` of the results-only method.

**Arguments**
- `results_path`: Path to the directory containing simulation results.
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref)).
- `type`: (optional, default: `"max"`) Visualization mode:
    - `"max"`: Color lines by the count of timesteps where utilization >= `threshhold`. Despite the name this is a count of congested hours, not a maximum — `plot_line_utils_interactive` calls the same mode `"hours ≥ threshold"`.
    - `"avg"`: Color lines by the average utilization across all timesteps.
- `exclude_dc_lines`: (optional, default: `false`) If `true`, only AC lines are visualized.
- `threshhold`: (optional, default: `0.95`) Utilization threshold (0-1 scale) for `"max"` mode counting.

**Keyword arguments**
- `background_map`: (default `true`) Draw Tyler/CartoDB raster tiles behind the network. Turning them off changes nothing about the axis: it stays geographic and keeps its degree ticks, scale bar and north arrow.
- `extent`: (default `nothing`) Map window as a `Tyler.Extents.Extent`. `nothing` fits it to the node coordinates; result sets whose nodes carry no coordinates fall back to a Germany cutout.
- `map_axis`: (default `true`) map-axis styling — `true`, `false` for a bare axis, or a `NamedTuple` such as `(scalebar = false,)`. See [Map axes](@ref).

**Plot Details**
- Lines are colored using the `ColorSchemes.lajolla` colormap.
- **Max mode**: Colorbar shows the count of hours where line utilization exceeds the threshold. The colorbar carries its own label stating what the colour means.
- **Avg mode**: Colorbar shows average utilization percentage (0-100%).
- Network nodes are displayed as black points.
- The axis is a map axis: degree ticks (`10°E`, `52°N`), `Longitude`/`Latitude` labels, a kilometre scale bar and a north arrow — see [Map axes](@ref) for the CRS statement the caption needs.
- Aggregates over the entire result horizon and reads the composite result view (the latest stage that wrote each table). Use `plot_line_utils_interactive` to select a time window and a specific market state.

**Returns**
- `fig`: A Makie figure object with the network map, color-coded lines, and colorbar.

**Example**
```julia
using GLMakie, Tyler, ColorSchemes

datafiles = Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)
results_path = "path/to/results"

# Visualize lines by max utilization frequency
fig = create_lineplot(results_path, datafiles, "max", false, 0.95)

# Visualize lines by average utilization
fig = create_lineplot(results_path, datafiles, "avg")

# Same plot without the input CSVs: geometry from the results' own parameters
fig = create_lineplot(results_path, "avg")
```

### `plot_capacity_network(data::Dict{Symbol,String}; kwargs...)`

Static map of the transmission network and the installed generation capacity at each node,
built **purely from the input CSVs** — no simulation results are read, so a dataset can be
checked before it is solved.

Line width carries line capacity, DC lines are dashed, and each node carries a stacked bar
of its installed capacity per plant type, its total labelled above and the node index
labelled underneath.

**Arguments**
- `data`: dictionary of input file paths (see section [Input Data Load](@ref)). `:nodes`, `:plants` and `:types` are required; `:lines` and `:dclines` are optional and each is skipped when the key is absent, the file does not exist, or it holds only a header.

**Keyword arguments**
- `background_map`: (default `true`) draw Tyler/CartoDB raster tiles behind the network. Ignored when the node file carries no coordinates — the circular fallback layout is not geographic and gets no basemap. Turning the tiles off on a geographic dataset keeps the map axis: degree ticks, `Longitude`/`Latitude` labels, scale bar and north arrow stay.
- `extent`: (default `nothing`) map window as a `Tyler.Extents.Extent`. `nothing` fits it to the node coordinates.
- `figsize`: (default `(1000, 1100)`) figure size in pixels.
- `exclude_dc_lines`: (default `false`) if `true`, DC lines are not drawn.
- `linewidth_range`: (default `(0.6, 4.5)`) width in points of the smallest and the largest line capacity.
- `bar_height_frac`: (default `0.12`) height of the tallest node bar as a fraction of the node bounding box.
- `bar_width_frac`: (default `0.02`) bar width as a fraction of the node bounding box.
- `show_node_labels`: (default `true`) print the node index below each node.
- `show_capacity_labels`: (default `true`) print the total installed capacity above each node's bar. Nodes without capacity get no label.
- `show_line_labels`: (default `true`) print the line index at each line's midpoint.
- `label_fontsize`: (default `10`) font size of every label set, in points.
- `map_axis`: (default `true`) map-axis styling — `true`, `false` for a bare axis, or a `NamedTuple` such as `(scalebar = false,)`. See [Map axes](@ref).

**Plot Details**
- Line width is proportional to the `capacity` column with a floor, so a line of unknown or zero capacity is hairline rather than invisible. AC and DC share one scale: equal capacities are drawn equally thick regardless of line type.
- Bar height uses one scale across all nodes, so bars are comparable between nodes. Only `g_max` is counted — a storage plant carrying its power in `storage_power` alone contributes nothing.
- Plant types are stacked in alphabetical order, identically at every node. Colors come from the `color` column of the plant-type file; types without one fall back to a distinguishable palette color.
- A node with no plants keeps its dot and its label and grows no bar.
- The number above a bar is the sum of that bar's segments — the same `g_max` total the bar height encodes. It carries no unit: the axis title already states MW, and repeating it at every node only adds clutter.
- On a geographic dataset the axis is a map axis: degree ticks, `Longitude`/`Latitude` labels, a kilometre scale bar and a north arrow — see [Map axes](@ref).
- When the node file has no `lon`/`lat` columns (or every node sits on the `0, 0` sentinel), nodes are laid out on a circle instead, the basemap is suppressed and none of the map decorations are drawn — a subtitle says so. Topology, line widths, bars and labels all still read correctly; only the geography is gone.
- The axis title states the absolute magnitude of the tallest bar and the widest line, without which neither encoding is readable in absolute terms.

**Returns**
- `fig`: A Makie `Figure`.

**Example**
```julia
using POMATWO, GLMakie, Tyler, ColorSchemes, Colors

datafiles = Dict{Symbol,String}(
    :nodes => joinpath(datapath, "nodes.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :plants => joinpath(datapath, "plants.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)

fig = plot_capacity_network(datafiles)

# no basemap, taller bars, AC only
fig = plot_capacity_network(datafiles;
    background_map = false, bar_height_frac = 0.2, exclude_dc_lines = true)
```

### `plot_market_statistics(results::DataFiles, zone::String="DE"; save_path=nothing)`

Create a comprehensive multi-panel visualization of market statistics for a specified zone.

Generates a 3×3 grid figure displaying time series, distribution histograms, box plots, 
and summary statistics for exchange flows, lost load events, and market prices. The 
visualization provides both temporal dynamics and statistical distributions of key 
market parameters.

**Arguments**
- `results::DataFiles`: DataFiles object containing model results with EXCHANGE and ZonalMarketBalance data.
- `zone::String="DE"`: Zone identifier for which to create visualizations. Defaults to "DE".
- `save_path=nothing`: (keyword) Optional file path to save the figure (e.g., "market_stats.png"). 
  If `nothing`, the figure is not saved to disk.

**Plot Layout**

The figure consists of a 3×3 grid:

- **Row 1 - Time Series:**
  - Exchange flow over time (MW)
  - Lost Load events over time (MW)
  - Market prices over time (€/MWh)

- **Row 2 - Distributions:**
  - Exchange histogram with mean line
  - Lost Load histogram with mean line
  - Price histogram with mean line

- **Row 3 - Statistical Summary:**
  - Box plots of all three parameters (Z-score normalized for comparability)
  - Text summary panel with key statistics (mean, median, std, min, max, sum, event count)

**Returns**
- `Figure`: A Makie Figure object (1800×1200 pixels) containing all visualization panels.

**Notes**
- Time series use sequential indices to avoid gaps in visualization.
- Box plots are Z-score normalized to enable comparison across different scales.
- Colors are consistent across all panels: steelblue (Exchange), coral (Lost Load), 
  mediumseagreen (Price).
- If `save_path` is provided, the figure is saved and a confirmation message is printed.

**Example**
```julia
using GLMakie, Tyler, ColorSchemes

results = DataFiles("path/to/results")

# Display the figure interactively
fig = plot_market_statistics(results, "DE")

# Save to file
fig = plot_market_statistics(results, "FR"; save_path="france_market_stats.png")
```