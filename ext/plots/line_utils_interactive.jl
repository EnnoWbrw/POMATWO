# =============================================================================
# Interactive transmission-line utilization map.
#
# The interactive counterpart of `create_lineplot` (plotting_functions.jl): the
# same |flow| / line_capacity colouring, but with a market-state menu, a time
# window slider, an aggregation menu and a threshold control — plus per-line
# flow-direction arrowheads and one of two node keys: on a redispatch state the
# nodal injection *change* caused by the redispatch measures (circles), on every
# other state the nodal *net injection* itself (arrows).
#
# `create_lineplot` collapses the time axis in `_line_utilization_table`
# (`@by :index`), so a slider needs its own data prep: `_line_util_matrix`
# keeps the per-(line, timestep) values in a `lines × times` matrix, where a
# time window is a set of contiguous columns and every reduction runs over a
# `view` without copying.
# =============================================================================

# Display order of the market-state menu, following the pipeline. States not
# listed here (a future MarketState) are appended alphabetically.
const _STATE_ORDER = ("TwoDayAhead", "DayAhead", "ProsumerOptimizationState", "Redispatch")

# Menu entry for a legacy result directory, which has no stage-prefixed files
# at all and is read through the composite `DataFiles(dir)` view.
const _COMPOSITE_STATE = "composite (all stages)"

const _MODE_AVG = "average utilization"
const _MODE_HOURS = "hours ≥ threshold"
const _MODE_FLOWSUM = "absolute power flow sum"

# Colour-scale reference of the average mode. Neither setting is universally better, so
# both are offered:
#
#   window  — 0–max(1, peak of the current window). Best contrast inside one view, but the
#             scale moves as the slider is dragged, so two windows cannot be compared by
#             colour.
#   horizon — 0–max(1, the largest single-timestep utilization anywhere in the state). Fixed,
#             so colour means the same thing in every window; at the cost of contrast,
#             because a wide window averages peaks away (measured on a real 168 h day-ahead
#             run: worst 1 h window 4.9, worst 168 h window 1.6 — a 3x spread).
const _SCALE_WINDOW = "adaptive (this window)"
const _SCALE_HORIZON = "fixed (whole horizon)"

# Redispatch marker colours, matching the shift map in refday_plots.jl. The net-injection
# arrows reuse them: the two node keys are never visible at the same time, and green-up /
# red-down means the same thing in both (more feed-in / less feed-in).
const _REDISP_UP_COLOR = RGBAf(0.13, 0.55, 0.13, 0.85)
const _REDISP_DOWN_COLOR = RGBAf(0.70, 0.13, 0.13, 0.85)
const _REDISP_ZERO_COLOR = RGBAf(0.40, 0.40, 0.40, 0.50)

# Node colour when neither key applies — the plain dots of create_lineplot.
const _NODE_PLAIN_COLOR = RGBAf(0.0, 0.0, 0.0, 1.0)

# Anchor dot under a net-injection arrow, so a node stays locatable at ≈ 0 injection.
const _NODE_ANCHOR_SIZE = 4.0f0

const _FLOW_DIR_COLOR = RGBAf(0.10, 0.10, 0.10, 0.85)

# Arrow lengths live in data (web-mercator) space and are derived from the node bounding
# box, as fractions of it. Tip and shaft *widths* stay in pixels (`markerspace = :pixel`),
# so the heads keep a constant screen size while the length stays anchored to the map.
const _ARROW_MAX_FRAC = 0.07   # longest net-injection arrow, as a fraction of the node span
const _ARROW_MIN_FRAC = 0.10   # shortest arrow, as a fraction of the longest one
# Line-direction chevron, as a fraction of the node span. The default view fits the node
# bounding box, so a fraction of the span is a roughly constant number of pixels whatever
# the network's geographic extent.
const _FLOW_CHEV_FRAC = 0.005  # chevron half-length
const _FLOW_CHEV_ASPECT = 0.7  # arm half-width, as a fraction of the half-length

"""
    _states_with_lineflow(results_path) -> Vector{String}

Stage prefixes that actually wrote a `LINEFLOW` table under `results_path`, in
pipeline order. Every stage writes one — a zonal day-ahead has no nodal
variables but `report_nodal_flows!` reports the flows its clearing implies — so
this lists the stages the run really went through.

Empty for a result directory written before per-stage prefixes existed; the
caller then falls back to [`_COMPOSITE_STATE`](@ref).
"""
function _states_with_lineflow(results_path)
    subrun_folders = filter(
        x -> occursin(r"subrun", x),
        filter(isdir, readdir(results_path, join = true)),
    )

    found = Set{String}()
    for folder in subrun_folders, f in readdir(folder)
        m = match(r"^(.+)_LINEFLOW\.arrow$", f)
        m === nothing && continue
        T = POMATWO.trymarket_state_type(m.captures[1])
        T === nothing || push!(found, POMATWO.result_prefix(T))
    end

    ordered = [s for s in _STATE_ORDER if s in found]
    append!(ordered, sort!(collect(setdiff(found, _STATE_ORDER))))
    return ordered
end

"""
    _line_util_matrix(results, exclude_dc_lines) -> (lines, times, U, F, S)

Per-timestep line utilization `U[l, t] = |flow| / line_capacity`, raw
`F[l, t] = |flow|` (MW) and **signed** `S[l, t] = flow` (MW), all three
`length(lines) × length(times)` `Float32` matrices. AC lines first, then DC
unless excluded — the same line set `_line_utilization_table` builds, but
without collapsing the time axis. Lines with zero capacity stay at 0 in all
three, as `U` does there — `F` and `S` are filled in the same guarded pass for
consistency even though neither has a capacity dependency of its own (see
[`_fill_util!`](@ref)).

`S` keeps the model's sign: `S > 0` means power flows from the line's
`line_start` node to its `line_end` node. That follows from `add_dclf`
(`src/technologies.jl`), which sets `incidence[l, line_start] = -1`,
`incidence[l, line_end] = +1` and writes
`ACINJECTION[n,t] = Σ_l incidence[l,n] * LINEFLOW[l,t]` — with `ACINJECTION`
import-positive, a positive flow adds power *into* the end node. Same for
`DCLINEFLOW` with `dc_start` / `dc_end`.

`lines × times` (not the transpose) so that a time window is a set of contiguous
columns and `view(U, :, cols)` needs no copy.
"""
function _line_util_matrix(results, exclude_dc_lines)
    tables = Tuple{DataFrame,Symbol}[]
    isempty(results.LINEFLOW) || push!(tables, (results.LINEFLOW, :LINEFLOW))
    if !exclude_dc_lines && !isempty(results.DCLINEFLOW)
        push!(tables, (results.DCLINEFLOW, :DCLINEFLOW))
    end
    isempty(tables) && return String[], Int[],
        zeros(Float32, 0, 0), zeros(Float32, 0, 0), zeros(Float32, 0, 0)

    times = sort!(unique(reduce(vcat, [Int.(df.Time) for (df, _) in tables])))
    lines = reduce(vcat, [unique(String.(df.index)) for (df, _) in tables])
    tpos = Dict(t => i for (i, t) in enumerate(times))
    lpos = Dict(l => i for (i, l) in enumerate(lines))

    U = zeros(Float32, length(lines), length(times))
    F = zeros(Float32, length(lines), length(times))
    S = zeros(Float32, length(lines), length(times))
    for (df, col) in tables
        _fill_util!(U, F, S, df.index, df.Time, df[!, col], df.line_capacity, lpos, tpos)
    end
    return lines, times, U, F, S
end

"""
Function barrier for the `_line_util_matrix` fill loop.

`df.index` and friends are inferred as `AbstractVector` — DataFrames are type-unstable by
construction — so pulling them into locals is not enough: every `col[k]` in the loop body
stays a dynamic call returning `Any` and boxes. Taking them as arguments lets this method
specialise on the concrete column types, which is what makes the loop allocation-free.

Fills `U`, `F` and `S` from one read of the flow value, so neither the flow-sum mode nor
the direction arrows need a second pass over the DataFrame. All three skip zero-capacity
lines, keeping the matrices over the same line set even though `F` and `S` have no
capacity dependency of their own.
"""
function _fill_util!(U, F, S, idx, tt, flow, cap, lpos, tpos)
    @inbounds for k in eachindex(idx, tt, flow, cap)
        c = Float64(cap[k])
        iszero(c) && continue
        li = get(lpos, String(idx[k]), 0)
        ti = get(tpos, Int(tt[k]), 0)
        (li == 0 || ti == 0) && continue
        f = Float64(flow[k])
        U[li, ti] = abs(f) / c
        F[li, ti] = abs(f)
        S[li, ti] = f
    end
    return U
end

"""
    _redisp_injection_matrix(results, nodes, times) -> Matrix{Float32}

Nodal net-injection change caused by the redispatch measures, `nodes × times` in
MW and **export-positive** (positive = more feed-in, the physical convention —
note the persisted `NETINPUT`/`ACINJECTION` tables use the opposite one).

Derived from the two identities the redispatch builders define in
`technologies.jl`:

    GEN_REDISP    = GEN_UP    − GEN_DOWN    + g       ⟹  Δgen    = GEN_UP − GEN_DOWN
    CHARGE_REDISP = CHARGE_UP − CHARGE_DOWN + charge  ⟹  Δcharge = CHARGE_UP − CHARGE_DOWN

so `Δinjection = Δgen − Δcharge`: charging is a withdrawal, hence extra charging
*lowers* feed-in. A storage unit contributes to both terms in the same hour and
both are kept. `CU_REDISP` is a derived expression of `GEN_UP`/`GEN_DOWN`
(`CU = cu − GEN_UP + GEN_DOWN`) and must not be added on top. Prosumers are
exempt from redispatch by design and never appear in `REDISP`. The `CU`/`LL`
slacks of `NodalMarketRedispBalance` are infeasibility rather than a measure and
are excluded — [`_redisp_slack_volume`](@ref) reports them separately.

All-zero when the results carry no `REDISP` table.
"""
function _redisp_injection_matrix(results, nodes, times)
    D = zeros(Float32, length(nodes), length(times))
    r = results.REDISP
    (r isa DataFrame && !isempty(r)) || return D

    p2n = results.params.plant2node
    npos = Dict(n => i for (i, n) in enumerate(nodes))
    tpos = Dict(t => i for (i, t) in enumerate(times))

    has_charge = hasproperty(r, :CHARGE_UP) && hasproperty(r, :CHARGE_DOWN)
    zero_col = _ZeroColumn(nrow(r))
    unmapped = _fill_redisp!(
        D, r.index, r.Time, r.GEN_UP, r.GEN_DOWN,
        has_charge ? r.CHARGE_UP : zero_col,
        has_charge ? r.CHARGE_DOWN : zero_col,
        p2n, npos, tpos)
    unmapped > 0 && @warn "$unmapped REDISP row(s) dropped: plant has no node mapping or no coordinates."

    return D
end

"Constant-zero stand-in for an absent optional column, so the fill loop stays branch-free."
struct _ZeroColumn <: AbstractVector{Float64}
    len::Int
end
Base.size(z::_ZeroColumn) = (z.len,)
Base.getindex(::_ZeroColumn, ::Int) = 0.0

"Function barrier for `_redisp_injection_matrix` — see [`_fill_util!`](@ref) for why."
function _fill_redisp!(D, idx, tt, gen_up, gen_down, chg_up, chg_down, p2n, npos, tpos)
    unmapped = 0
    @inbounds for k in eachindex(idx, tt, gen_up, gen_down)
        n = get(p2n, String(idx[k]), "")
        i = isempty(n) ? 0 : get(npos, n, 0)
        j = get(tpos, Int(tt[k]), 0)
        if i == 0 || j == 0
            unmapped += 1
            continue
        end
        delta = Float64(coalesce(gen_up[k], 0.0)) - Float64(coalesce(gen_down[k], 0.0))
        delta -= Float64(coalesce(chg_up[k], 0.0)) - Float64(coalesce(chg_down[k], 0.0))
        D[i, j] += Float32(delta)
    end
    return unmapped
end

"Total absolute `CU`/`LL` slack of the redispatch nodal balance — not attributable to a measure."
function _redisp_slack_volume(results)
    df = results.NodalMarketRedispBalance
    (df isa DataFrame && !isempty(df)) || return 0.0
    total = 0.0
    for col in (:CU, :LL)
        hasproperty(df, col) || continue
        # Function form: `sum(abs, Float64.(coalesce.(col, 0.0)))` materialised two
        # full-length temporaries before summing anything.
        total += sum(x -> abs(Float64(coalesce(x, 0.0))), df[!, col]; init = 0.0)
    end
    return total
end

"""
    _net_injection_matrix(results, nodes, times) -> Union{Matrix{Float32},Nothing}

Nodal net injection, `nodes × times` in MW and **export-positive**: positive means the node
generates more than it consumes, i.e. `gen − load − charge`.

The persisted `NETINPUT` column is **import-positive** (`load + charge − gen`; it sits on
the supply side of `link_balance` in `energy_balances.jl`), so this is simply its negation.
Writing it without the minus is the historical sign bug the `CLAUDE.md` NETINPUT block
warns about — a map drawn that way looks entirely plausible and is exactly wrong.

Every pipeline stage writes a `NETINPUT` table: the nodal ones from `add_dclf`, a zonal
day-ahead from `report_nodal_flows!`, which reconstructs the flows its clearing implies.
`nothing` when the table is missing or empty, which is the caller's signal to fall back to
plain node dots.

Unlike [`_redisp_injection_matrix`](@ref) the rows are already keyed by node, so there is
no `plant2node` hop; the unmapped counter only fires for a node without coordinates.
"""
function _net_injection_matrix(results, nodes, times)
    r = results.NETINPUT
    (r isa DataFrame && !isempty(r) && hasproperty(r, :NETINPUT)) || return nothing

    D = zeros(Float32, length(nodes), length(times))
    npos = Dict(n => i for (i, n) in enumerate(nodes))
    tpos = Dict(t => i for (i, t) in enumerate(times))

    unmapped = _fill_netinput!(D, r.index, r.Time, r.NETINPUT, npos, tpos)
    unmapped > 0 && @warn "$unmapped NETINPUT row(s) dropped: node has no coordinates."

    return D
end

"Function barrier for `_net_injection_matrix` — see [`_fill_util!`](@ref) for why."
function _fill_netinput!(D, idx, tt, ni, npos, tpos)
    unmapped = 0
    @inbounds for k in eachindex(idx, tt, ni)
        i = get(npos, String(idx[k]), 0)
        j = get(tpos, Int(tt[k]), 0)
        if i == 0 || j == 0
            unmapped += 1
            continue
        end
        # negation: NETINPUT is import-positive, the arrows are export-positive
        D[i, j] -= Float32(coalesce(ni[k], 0.0))
    end
    return unmapped
end

"""
    _line_capacities(results, exclude_dc_lines) -> Dict{String,Float64}

`line_capacity` per line id, AC plus DC unless excluded. The column is constant per line —
`df_lineflow` broadcasts `acline_capacity[l]` / `dcline_capacity[l]` across that line's rows
— so the first row of each line is taken and the rest skipped.

Read from the result tables rather than `params.acline_capacity` so that it is by
construction the same number the utilization colour divides by, and so it still works when
the geometry came from input CSVs via the `data` keyword.
"""
function _line_capacities(results, exclude_dc_lines)
    caps = Dict{String,Float64}()
    tables = DataFrame[]
    isempty(results.LINEFLOW) || push!(tables, results.LINEFLOW)
    if !exclude_dc_lines && !isempty(results.DCLINEFLOW)
        push!(tables, results.DCLINEFLOW)
    end
    for df in tables
        idx, cap = df.index, df.line_capacity
        @inbounds for k in eachindex(idx, cap)
            l = String(idx[k])
            haskey(caps, l) || (caps[l] = Float64(cap[k]))
        end
    end
    return caps
end

"""
    _dc_line_ids(results, data, exclude_dc_lines) -> Set{String}

Ids of the DC lines, so they can be drawn dashed. Empty when DC lines are excluded.

`params.sets.DC` is the authoritative source and the `DCLINEFLOW` table is only a backstop
for a result directory whose `params.jld2` failed to load: under `NTC` a zonal day-ahead
assumes the DC lines idle and writes **no** `DCLINEFLOW` rows at all, so the table alone
would silently classify every DC line as AC.
"""
function _dc_line_ids(results, data, exclude_dc_lines)
    exclude_dc_lines && return Set{String}()
    if data !== nothing
        df = CSV.read(data[:dclines], DataFrame; select = [:index])
        return Set{String}(String(x) for x in df.index)
    end
    ids = Set{String}(String(l) for l in results.params.sets.DC)
    if results.DCLINEFLOW isa DataFrame && !isempty(results.DCLINEFLOW)
        for l in results.DCLINEFLOW.index
            push!(ids, String(l))
        end
    end
    return ids
end

"Index of each entry of `lines` that has geometry, in the fixed order of `segment_lines`."
function _segment_index(lines, segment_lines)
    lpos = Dict(l => i for (i, l) in enumerate(lines))
    return [get(lpos, l, 0) for l in segment_lines]
end

"""
Larger side of the node bounding box, in web-mercator units — the length unit the arrows
are scaled against, so an arrow covers the same fraction of the map on a national and on a
three-node network. Falls back to 1.0 for a degenerate (single-node or empty) layout, which
only matters for a map that has nothing to draw arrows between anyway.
"""
function _node_span(points)
    isempty(points) && return 1.0
    xlo = xhi = Float64(points[1][1])
    ylo = yhi = Float64(points[1][2])
    for p in points
        x, y = Float64(p[1]), Float64(p[2])
        xlo = min(xlo, x); xhi = max(xhi, x)
        ylo = min(ylo, y); yhi = max(yhi, y)
    end
    span = max(xhi - xlo, yhi - ylo)
    return span > 0 ? span : 1.0
end

_fmt_val(x) = abs(x) >= 100 ? string(round(Int, x)) : string(round(x, digits = 2))

"""
    plot_line_utils_interactive(results_path; kwargs...)

Interactive map of transmission line utilization — the interactive counterpart
of [`create_lineplot`](@ref).

Line colour is `|flow| / line_capacity` aggregated over the selected time
window, with the network drawn over Tyler/CartoDB raster tiles. Line **width**
carries `line_capacity` itself, so a saturated 220 kV line and a saturated
interconnector are not drawn as the same thing — colour is a ratio and by itself
says nothing about how much power is at stake. DC lines are dashed.

# Interactivity
- **Market state menu** — one entry per pipeline stage that wrote a `LINEFLOW`
  table under `results_path` (`TwoDayAhead`, `DayAhead`,
  `ProsumerOptimizationState`, `Redispatch`, whichever are present); a legacy
  result directory offers a single composite entry. States are loaded lazily and
  cached on first selection.
- **`IntervalSlider`** — the time window; drag the handles together for a single
  timestep. Starts on the full horizon, so the first frame reproduces
  `create_lineplot`.
- **Mode menu**
    - `"average utilization"` — mean utilization over the window.
    - `"hours ≥ threshold"` — count of timesteps in the window at or above the
      threshold, colorbar 0–(window length). This is what `create_lineplot`
      calls `type = "max"`; it is a count of congested hours, not a maximum.
    - `"absolute power flow sum"` — total `Σ|flow|` per line over the window, in
      MWh, independent of `line_capacity`. Colour scale is always adaptive to the
      current window; the colour-scale menu below has no effect on this mode
      (same as the counting mode), since a sum has no capacity-derived ceiling to
      fix a horizon scale against.
- **Colour scale menu** (average mode only) — what the top of the colorbar means.
  Utilization above 1 is real, not an artefact: a zonal day-ahead has no nodal
  variables, so `report_nodal_flows!` reports the flows its clearing implies without
  applying line limits, and the overload is what redispatch then resolves. Both
  settings floor the maximum at 1 so an uncongested state is not stretched to look
  loaded.
    - `"adaptive (this window)"` (default) — 0–max(1, peak of the current window).
      Best contrast within one view; the scale moves as the slider is dragged, so two
      windows cannot be compared by colour.
    - `"fixed (whole horizon)"` — 0–max(1, largest single-timestep utilization in the
      state). Colour means the same in every window, at the cost of contrast: a wide
      window averages peaks away. On a real 168 h day-ahead run the worst 1 h window
      reaches 4.9 while the worst 168 h window is 1.6, so the default view uses only
      the lower third of the colormap under this setting.

  The counting mode always scales to the window length, which is its natural ceiling;
  a horizon-wide count scale would render a short window as one dark step.
- **Threshold slider** — the threshold of the counting mode, in 1 % steps.

# Node markers
The nodes carry one of two mutually exclusive keys, depending on the selected state.

**Redispatch circles** — on a state that carries a `REDISP` table, each node is a
circle coloured by the nodal net-injection change the redispatch measures cause
over the window (green = increase, red = decrease, gray ≈ 0), with marker
**area** proportional to the magnitude in MWh. Storage is included on both sides
(`ΔGEN` and, with the opposite sign, `Δcharge`; see
[`_redisp_injection_matrix`](@ref)).

**Net-injection arrows** — on every other state, each node carries a vertical
arrow for its own net injection, `gen − load − charge`, averaged over the window
in **MW**: green pointing up where the node generates more than it consumes, red
pointing down where it consumes more, a gray dot at ≈ 0. Arrow **length** is
proportional to the magnitude — linearly, unlike the circles, because length is a
linearly perceived channel where marker area is not. Lengths are in map
coordinates, so the arrows stay anchored to the map under zoom; the heads are in
pixels and keep a constant screen size. The data comes from the `NETINPUT` table,
which every stage writes — a zonal day-ahead has no nodal variables, but
`report_nodal_flows!` reports the net input its clearing implies.

Below the legend, the size scale gives the reference magnitudes for the current
window — MWh for the circles, MW for the arrows.

# Flow direction
Each line carries an open `>` chevron at its midpoint pointing the way power
flows in the selected window, from the **signed** flow sum. It is deliberately an
unfilled stroke rather than a solid arrowhead: there is one per line and only a
handful of node arrows, so filled heads would bury the line colours. A line whose
flow reverses
inside the window can cancel to ≈ 0; that is a real statement about the window
(no net transfer), so the head is dropped rather than forced one way. Sign
convention: a positive `LINEFLOW` runs from the line's `line_start` node to its
`line_end` node (see [`_line_util_matrix`](@ref)).

# Arguments
- `results_path`: directory containing the results of a model run, or an
  `AbstractDict` mapping menu labels to already-loaded [`DataFiles`](@ref).

# Keyword arguments
- `data`: (default `nothing`) `Dict{Symbol,String}` of the input CSVs. When
  given, node coordinates and line endpoints are read from `data[:nodes]` /
  `data[:lines]` / `data[:dclines]` instead of `params`.
- `exclude_dc_lines`: (default `false`) show AC lines only.
- `threshold`: (default `0.95`) initial threshold of the counting mode.
- `mode`: (default `:avg`) initial mode, `:avg`, `:hours` or `:flowsum`.
- `scale`: (default `:window`) initial colour-scale reference, `:window` or `:horizon`.
  Pass `:horizon` to make two figures of the same state directly comparable.
- `state`: (default `nothing`) initially selected menu entry; `nothing` picks the
  last stage of the pipeline.
- `background_map`: (default `true`) draw the raster tiles.
- `extent`: (default `nothing`) map window; `nothing` fits it to the node
  coordinates.
- `show_redisp`: (default `true`) enable the redispatch node markers.
- `redisp_ref`: (default `nothing`) pin the marker reference magnitude in MWh
  instead of taking the largest value in the window — use it to make two figures
  comparable.
- `show_injection`: (default `true`) enable the net-injection arrows on states
  without a `REDISP` table.
- `injection_ref`: (default `nothing`) pin the arrow reference magnitude in MW,
  the `redisp_ref` of the arrows.
- `show_flow_direction`: (default `true`) draw the per-line direction arrowheads.
- `arrow_scale`: (default `1.0`) multiplier on the arrow lengths, which are
  otherwise a fixed fraction of the node bounding box.
- `linewidth_by_capacity`: (default `true`) scale line width with
  `line_capacity`. Set `false` to draw every line at `linewidth`, as before.
- `linewidth_range`: (default `(0.6, 4.5)`) width of a zero-capacity and of the
  largest line. Capacity maps onto it proportionally, floored at the low end so a
  line whose capacity is zero or unknown stays hairline rather than vanishing.
- `figsize`, `linewidth` (only when `linewidth_by_capacity = false`),
  `max_markersize`, `min_markersize`, `zero_tol`.

# Returns
- `fig`: the Makie figure.

# Example
```julia
using POMATWO, GLMakie, Tyler, ColorSchemes, Colors

results_path = joinpath("results", scen_name)
fig = plot_line_utils_interactive(results_path)

# start on the congestion view, AC lines only
fig = plot_line_utils_interactive(results_path; mode = :hours, threshold = 0.9,
                                  exclude_dc_lines = true)
```
"""
function POMATWO.plot_line_utils_interactive(
    results_path::AbstractString;
    data = nothing,
    kwargs...,
)
    states = _states_with_lineflow(results_path)
    loader = if isempty(states)
        # legacy layout: no stage-prefixed files, read through the composite view
        states = [_COMPOSITE_STATE]
        _ -> DataFiles(results_path)
    else
        s -> DataFiles(results_path, POMATWO.market_state_type(s))
    end
    return _plot_line_utils_interactive(states, loader, data; kwargs...)
end

"""
    plot_line_utils_interactive(states::AbstractDict; kwargs...)

Variant for already-loaded results: `states` maps the menu label to a
[`DataFiles`](@ref), e.g.

```julia
plot_line_utils_interactive(Dict("day-ahead" => DataFiles(dir, DayAhead),
                                 "redispatch" => DataFiles(dir, Redispatch)))
```

Menu order follows [`_STATE_ORDER`](@ref) for canonical state names and is
alphabetical otherwise.
"""
function POMATWO.plot_line_utils_interactive(
    states::AbstractDict{<:AbstractString,DataFiles};
    data = nothing,
    kwargs...,
)
    keys_ = collect(keys(states))
    ordered = [s for s in _STATE_ORDER if s in keys_]
    append!(ordered, sort!(collect(setdiff(keys_, _STATE_ORDER))))
    return _plot_line_utils_interactive(ordered, s -> states[s], data; kwargs...)
end

function _plot_line_utils_interactive(
    state_names::Vector{String},
    load_state,
    data;
    exclude_dc_lines::Bool = false,
    threshold::Float64 = 0.95,
    mode::Symbol = :avg,
    scale::Symbol = :window,
    state = nothing,
    background_map::Bool = true,
    extent = nothing,
    show_redisp::Bool = true,
    redisp_ref = nothing,
    show_injection::Bool = true,
    injection_ref = nothing,
    show_flow_direction::Bool = true,
    arrow_scale = 1.0,
    figsize = (1200, 1100),
    linewidth = 2.0,
    linewidth_by_capacity::Bool = true,
    linewidth_range = (0.6, 4.5),
    max_markersize = 40.0,
    min_markersize = 2.5,
    zero_tol = 1e-6,
)
    isempty(state_names) && error("No market state with a LINEFLOW table found.")
    mode in (:avg, :hours, :flowsum) ||
        throw(ArgumentError("mode must be :avg, :hours or :flowsum, got :$mode"))
    scale in (:window, :horizon) ||
        throw(ArgumentError("scale must be :window or :horizon, got :$scale"))
    initial_state = state === nothing ? last(state_names) : String(state)
    initial_state in state_names || throw(ArgumentError(
        "state \"$initial_state\" not available. Found: $(join(state_names, ", "))"))

    # --- topology (shared by every state) ------------------------------------
    first_results = load_state(initial_state)
    line_from_to, node_lonlat, node_coords = data === nothing ?
        _line_endpoints_from_results(first_results, exclude_dc_lines) :
        _line_endpoints_from_data(data, exclude_dc_lines)
    isempty(line_from_to) && error(
        "No line has usable node coordinates — nothing to draw. Check the lon/lat " *
        "columns of the node input file.")

    # Fixed drawing order: the segment geometry is built once and never rebuilt,
    # only the per-segment colour values change.
    segment_lines = sort!(collect(keys(line_from_to)))
    segments = Vector{Point2f}(undef, 2 * length(segment_lines))
    for (i, l) in enumerate(segment_lines)
        from, to = line_from_to[l]
        segments[2i-1] = from
        segments[2i] = to
    end
    # Per-line width from `line_capacity`, so a thin overloaded line and a thick one are
    # visibly different problems. Capacity comes from the results tables rather than
    # `params.acline_capacity`, so it is by construction the same number the colour
    # normalises by, and it is available even when the geometry came from `data` CSVs.
    line_widths = if linewidth_by_capacity
        caps = _line_capacities(first_results, exclude_dc_lines)
        capmax = isempty(caps) ? 0.0 : maximum(values(caps))
        wlo, whi = Float32(first(linewidth_range)), Float32(last(linewidth_range))
        # Proportional to capacity with a floor, so a zero- or unknown-capacity line is
        # hairline rather than invisible.
        [capmax <= 0 ? wlo :
         clamp(wlo + (whi - wlo) * Float32(get(caps, l, 0.0) / capmax), wlo, whi)
         for l in segment_lines]
    else
        nothing
    end

    # AC and DC are drawn as two `linesegments!` plots over disjoint subsets of the same
    # geometry, because `linestyle` is a per-plot attribute — it cannot be varied per
    # segment the way colour and width can. DC is dashed, matching `create_lineplot` and
    # the refday shift map.
    dc_ids = _dc_line_ids(first_results, data, exclude_dc_lines)
    ac_idx = [i for (i, l) in enumerate(segment_lines) if !(l in dc_ids)]
    dc_idx = [i for (i, l) in enumerate(segment_lines) if l in dc_ids]

    "Endpoint pairs of the lines at `idx`, in `segments` order."
    function _group_points(idx)
        pts = Vector{Point2f}(undef, 2 * length(idx))
        for (k, i) in enumerate(idx)
            pts[2k-1] = segments[2i-1]
            pts[2k] = segments[2i]
        end
        return pts
    end
    # `linesegments!` wants one width per POINT, hence each line's width twice.
    _group_widths(idx) = line_widths === nothing ? Float32(linewidth) :
                         Float32[line_widths[i] for i in idx for _ in 1:2]

    nodes = sort!(collect(keys(node_lonlat)))
    node_points = [node_lonlat[n] for n in nodes]

    # Arrow lengths are in data (web-mercator) space, so they need a length unit that means
    # the same thing on a national and on a three-node map: the larger side of the node
    # bounding box. Computed once — the geometry never moves.
    node_span = _node_span(node_points)
    max_arrow = Float32(_ARROW_MAX_FRAC * node_span * arrow_scale)
    min_arrow = Float32(_ARROW_MIN_FRAC * max_arrow)

    # --- per-state data, built on first selection ----------------------------
    cache = Dict{String,NamedTuple}()
    function state_data(name)
        get!(cache, name) do
            res = load_state(name)
            line_ids, times, U, F, S = _line_util_matrix(res, exclude_dc_lines)
            isempty(times) && error("Market state \"$name\" has no line flow data.")
            has_redisp = show_redisp && !isempty(res.REDISP)
            return (
                line_ids = line_ids,
                times = times,
                U = U,
                F = F,
                S = S,
                seg = _segment_index(line_ids, segment_lines),
                D = has_redisp ? _redisp_injection_matrix(res, nodes, times) : nothing,
                # The net-injection arrows are the alternative node key, so they are only
                # built where the redispatch circles are not.
                NI = has_redisp || !show_injection ? nothing :
                     _net_injection_matrix(res, nodes, times),
                slack = has_redisp ? _redisp_slack_volume(res) : 0.0,
                # per-state scratch: the window reduction writes here instead of
                # allocating a fresh vector on every slider pixel
                vals = zeros(Float32, size(U, 1)),
                # Largest single-timestep utilization in this state. It bounds the mean of
                # ANY window, so it is the one reference that never clips — see
                # `_SCALE_HORIZON`. Computed once here, not per slider tick.
                umax = isempty(U) ? 0.0 : Float64(maximum(U)),
            )
        end
    end
    init = state_data(initial_state)

    # --- layout --------------------------------------------------------------
    extent === nothing && (extent = _auto_map_extent(node_coords))
    fig, ax = create_lineplot_layout(figsize; background_map = background_map, extent = extent)

    crange = Observable((0.0f0, 1.0f0))
    ac_vals = Observable(zeros(Float32, 2 * length(ac_idx)))
    dc_vals = Observable(zeros(Float32, 2 * length(dc_idx)))
    for (idx, vals, style) in ((ac_idx, ac_vals, nothing), (dc_idx, dc_vals, :dash))
        isempty(idx) && continue
        linesegments!(
            ax, _group_points(idx);
            color = vals,
            colormap = ColorSchemes.lajolla.colors,
            colorrange = crange,
            linewidth = _group_widths(idx),
            linestyle = style,
        )
    end

    # Per-line flow direction: an open ">" chevron at the segment midpoint, built as two
    # line segments rather than a filled arrowhead. On a real network there is one of these
    # per line and only a handful of node arrows, so a filled head turns the map into a
    # field of black triangles — an unfilled stroke recedes and leaves the line colour,
    # which is the primary signal, readable. `Arrows2D` cannot draw it: its `tip` attribute
    # is converted to a mesh, so any tip shape comes out filled.
    #
    # Building the geometry here also sidesteps the `scatter` marker-rotation attribute,
    # whose name moved between Makie versions. Drawn before the nodes so a node stays on top.
    flow_mid = [Point2f(
        0.5f0 * (segments[2i-1][1] + segments[2i][1]),
        0.5f0 * (segments[2i-1][2] + segments[2i][2]),
    ) for i in 1:length(segment_lines)]
    # Unit direction from→to per segment; the window reduction only picks its sign.
    flow_unit = [let d = segments[2i] - segments[2i-1], n = hypot(d[1], d[2])
            n > 0 ? Vec2f(d[1] / n, d[2] / n) : Vec2f(0, 0)
        end for i in 1:length(segment_lines)]
    chev_len = Float32(_FLOW_CHEV_FRAC * node_span * arrow_scale)
    chev_wid = Float32(_FLOW_CHEV_ASPECT * chev_len)
    # Two segments (4 points) per line: each arm runs from its outer end to the apex. A
    # line with no net flow collapses to its midpoint, which draws nothing — that keeps the
    # buffer length fixed instead of resizing it per slider tick.
    flow_pts = Observable([flow_mid[cld(k, 4)] for k in 1:4*length(segment_lines)])
    if show_flow_direction
        linesegments!(ax, flow_pts; color = _FLOW_DIR_COLOR, linewidth = 1.2)
    end

    # Node marker buffers, rewritten in place by `redraw!` rather than reallocated.
    node_color = Observable(fill(_NODE_PLAIN_COLOR, length(nodes)))
    node_size = Observable(fill(Float32(min_markersize), length(nodes)))
    dvbuf = zeros(Float32, length(nodes))
    nibuf = zeros(Float32, length(nodes))
    scatter!(
        ax, node_points;
        color = node_color,
        markersize = node_size,
        strokecolor = :white,
        strokewidth = 0.4,
    )

    # Net-injection arrows: the node key of every non-redispatch state. Length carries the
    # magnitude in data space, tip and shaft widths stay in pixels (`markerspace = :pixel`),
    # so the heads keep a constant screen size while the arrow stays anchored to the map.
    inj_dirs = Observable(fill(Vec2f(0, 0), length(nodes)))
    inj_color = Observable(fill(_REDISP_ZERO_COLOR, length(nodes)))
    arrows2d!(
        ax, node_points, inj_dirs;
        color = inj_color,
        align = :tail,
        shaftwidth = 4,
        tipwidth = 13,
        tiplength = 10,
        minshaftlength = 0,
    )

    cbar = Colorbar(
        fig[1, 3];
        colormap = ColorSchemes.lajolla.colors,
        colorrange = crange,
        label = "line utilization",
    )

    # --- controls ------------------------------------------------------------
    state_menu = Menu(fig, options = state_names, default = initial_state)
    mode_menu = Menu(fig, options = [_MODE_AVG, _MODE_HOURS, _MODE_FLOWSUM],
                     default = mode === :avg ? _MODE_AVG : mode === :hours ? _MODE_HOURS : _MODE_FLOWSUM)
    scale_menu = Menu(fig, options = [_SCALE_WINDOW, _SCALE_HORIZON],
                      default = scale === :window ? _SCALE_WINDOW : _SCALE_HORIZON)
    thr_grid = SliderGrid(fig, (
        label = "threshold",
        range = 0:0.01:1,
        startvalue = threshold,
        format = x -> string(round(Int, 100x)) * " %",
    ))
    thr_slider = thr_grid.sliders[1]

    islider = IntervalSlider(fig[2, 1], range = init.times,
                             startvalues = (first(init.times), last(init.times)))
    info = Label(fig[3, 1], ""; tellwidth = false, fontsize = 13)

    # Size scale for the node key. A Makie `Legend` label cannot be rebound, and the
    # reference magnitude follows the selected window, so the live numbers live in their own
    # decoration-free axis instead. Both keys share the axis — they are mutually exclusive,
    # and a second axis would leave a permanent 110 px gap in the panel.
    scale_frac = (0.25, 0.5, 1.0)
    scale_y = [1.0, 2.4, 4.2]
    refmag = Observable(1.0)
    inj_refmag = Observable(1.0)
    scale_ax = Axis(fig; aspect = DataAspect(), height = 110)
    hidedecorations!(scale_ax)
    hidespines!(scale_ax)
    xlims!(scale_ax, -1.0, 6.0)
    ylims!(scale_ax, 0.0, 5.6)
    # Handles are kept because these plots live in `scale_ax.scene`, a child of the axis —
    # toggling `scale_ax.blockscene.visible` hides the (already hidden) decorations but
    # leaves the bubbles and their numbers on screen. They have to be toggled themselves.
    scale_marks = scatter!(
        scale_ax, fill(0.0, 3), scale_y;
        color = :gray70,
        markersize = Float32[
            min_markersize + (max_markersize - min_markersize) * sqrt(f) for f in scale_frac
        ],
        strokecolor = :black,
        strokewidth = 0.4,
    )
    scale_nums = text!(
        scale_ax, fill(1.2, 3), scale_y;
        text = @lift([_fmt_val(f * $refmag) for f in scale_frac]),
        align = (:left, :center),
        fontsize = 12,
    )

    # Arrow scale, in the same axis. The arrows are sized LINEARLY in the magnitude, unlike
    # the circles above (whose *area* is proportional, hence the `sqrt`): length is a
    # linearly perceived channel, so a sqrt length would understate every difference.
    inj_scale_arrows = arrows2d!(
        scale_ax, [Point2f(0.0, y) for y in scale_y],
        [Vec2f(0, 1.9f0 * f) for f in scale_frac];
        color = :gray50,
        align = :center,
        shaftwidth = 4,
        tipwidth = 13,
        tiplength = 10,
        minshaftlength = 0,
    )
    inj_scale_nums = text!(
        scale_ax, fill(1.2, 3), scale_y;
        text = @lift([_fmt_val(f * $inj_refmag) for f in scale_frac]),
        align = (:left, :center),
        fontsize = 12,
    )

    # Only worth a key when the network actually has DC lines; `Legend` contents are fixed
    # at construction, and `dc_idx` is already known by here.
    dc_key = isempty(dc_idx) ? Any[] :
             Any[LineElement(color = :gray30, linestyle = :dash, linewidth = 2)]
    dc_key_label = isempty(dc_idx) ? String[] : ["DC line (dashed)"]

    legend = Legend(
        fig,
        [
            MarkerElement(marker = :circle, color = _REDISP_UP_COLOR, markersize = 15),
            MarkerElement(marker = :circle, color = _REDISP_DOWN_COLOR, markersize = 15),
            MarkerElement(marker = :circle, color = _REDISP_ZERO_COLOR, markersize = 8),
            # a Char marker, so the key is an open chevron like the map's, not a filled head
            MarkerElement(marker = '>', color = _FLOW_DIR_COLOR, markersize = 12),
            dc_key...,
        ],
        [
            "injection increase (net redispatch up)",
            "injection decrease (net redispatch down)",
            "≈ 0",
            "line flow direction",
            dc_key_label...,
        ],
        "Redispatch [MWh]",
    )
    # A second `Legend` rather than a rebound one, for the same reason the numbers live in
    # an axis: `Legend` labels are fixed at construction.
    inj_legend = Legend(
        fig,
        [
            MarkerElement(marker = :utriangle, color = _REDISP_UP_COLOR, markersize = 15),
            MarkerElement(marker = :dtriangle, color = _REDISP_DOWN_COLOR, markersize = 15),
            MarkerElement(marker = :circle, color = _REDISP_ZERO_COLOR, markersize = 8),
            # a Char marker, so the key is an open chevron like the map's, not a filled head
            MarkerElement(marker = '>', color = _FLOW_DIR_COLOR, markersize = 15),
            dc_key...,
        ],
        [
            "generation > load (net export)",
            "load > generation (net import)",
            "≈ 0",
            "line flow direction",
            dc_key_label...,
        ],
        "Net injection [MW]",
    )
    scale_label = Label(fig, "Δ injection reference [MWh]", fontsize = 12)

    fig[1, 2] = vgrid!(
        Label(fig, "Market state", fontsize = 16), state_menu,
        Label(fig, "Aggregation", fontsize = 16), mode_menu,
        Label(fig, "Colour scale", fontsize = 16), scale_menu,
        thr_grid,
        legend, inj_legend, scale_label, scale_ax;
        tellheight = false,
    )

    # --- update --------------------------------------------------------------
    """
    Switch the node key between the redispatch circles (`:redisp`), the net-injection
    arrows (`:injection`) and neither (`:none`).

    The two legends share the panel and the size scale shares one axis, so everything that
    belongs to the inactive key has to be hidden explicitly. Handles are kept for the
    in-axis plots because they live in `scale_ax.scene`, a child of the axis — toggling
    `scale_ax.blockscene.visible` hides the (already hidden) decorations but leaves the
    marks and their numbers on screen.
    """
    function set_key!(which::Symbol)
        redisp = which === :redisp
        inj = which === :injection
        legend.blockscene.visible[] = redisp
        inj_legend.blockscene.visible[] = inj
        scale_label.blockscene.visible[] = redisp || inj
        scale_ax.blockscene.visible[] = redisp || inj
        scale_marks.visible[] = redisp
        scale_nums.visible[] = redisp
        inj_scale_arrows.visible[] = inj
        inj_scale_nums.visible[] = inj
        scale_label.text = redisp ? "Δ injection reference [MWh]" :
                           "net injection reference [MW]"
        return nothing
    end

    function redraw!()
        st = state_data(state_menu.selection[])
        lo, hi = islider.interval[]
        cols = searchsortedfirst(st.times, lo):searchsortedlast(st.times, hi)
        isempty(cols) && return nothing
        nhours = length(cols)

        ishours = mode_menu.selection[] == _MODE_HOURS
        isflowsum = mode_menu.selection[] == _MODE_FLOWSUM
        thr = Float32(thr_slider.value[])

        # Reduce into the per-state buffer. `count(…; dims = 2)` yields `Int` and
        # `mean(…; dims = 2)` `Float32`, so the previous branch join made `vals` a `Union`
        # (and allocated a matrix plus a `vec` per slider pixel). The loop nests time
        # outermost so the column-major matrix is walked in memory order.
        vals = st.vals
        U = st.U
        fill!(vals, 0.0f0)
        if ishours
            @inbounds for j in cols, i in eachindex(vals)
                U[i, j] >= thr && (vals[i] += 1.0f0)
            end
        elseif isflowsum
            F = st.F
            @inbounds for j in cols, i in eachindex(vals)
                vals[i] += F[i, j]
            end
        else
            @inbounds for j in cols, i in eachindex(vals)
                vals[i] += U[i, j]
            end
            vals ./= nhours
        end

        # `seg[i] == 0` marks a line that has geometry but no flow in this state.
        # `ac_idx`/`dc_idx` index into `segment_lines`, so `st.seg` is read through them.
        @inbounds for (buf, idx) in ((ac_vals[], ac_idx), (dc_vals[], dc_idx))
            for (k, i) in enumerate(idx)
                s = st.seg[i]
                v = s == 0 ? 0.0f0 : vals[s]
                buf[2k-1] = v
                buf[2k] = v
            end
        end
        notify(ac_vals)
        notify(dc_vals)

        peak = isempty(vals) ? 0.0 : Float64(maximum(vals))
        # Utilization above 1 is real, not an artefact: a zonal day-ahead has no nodal
        # variables, so `report_nodal_flows!` reports the flows its clearing implies
        # WITHOUT applying line limits — the overload is exactly what redispatch then
        # resolves. A hard 0–1 colour scale saturated every one of those lines to the same
        # colour and hid how bad the worst were. The floor stays at 1 so an uncongested
        # state is not stretched to look loaded.
        fixed_scale = scale_menu.selection[] == _SCALE_HORIZON
        cmax = max(1.0, fixed_scale ? st.umax : peak)
        # The counting mode is deliberately left window-relative: its value cannot exceed
        # the window length, so normalising to it is the only reading that stays legible —
        # a horizon-wide count scale would render a short window as a single dark step.
        # The flow-sum mode has no capacity-derived ceiling to fix a scale against either
        # (a wider window only ever grows the sum, unlike utilization), so it is always
        # window-adaptive too — the scale menu has no effect on it.
        crange[] = if ishours
            (0.0f0, Float32(max(nhours, 1)))
        elseif isflowsum
            (0.0f0, Float32(max(peak, 1e-6)))
        else
            (0.0f0, Float32(cmax))
        end

        ax.xlabel = (if ishours
            "Line colour: timesteps with utilization ≥ $(round(Int, 100 * thr)) % in the selected window"
        elseif isflowsum
            "Line colour: total |flow| in the selected window (MWh), scale 0–$(round(peak, digits = 2))"
        else
            "Line colour: average line utilization in the selected window " *
            "(scale 0–$(round(cmax, digits = 2)), $(fixed_scale ? "fixed over the horizon" : "adaptive to this window"))"
        end) * (linewidth_by_capacity ? "\nLine width: line capacity (MW)" : "")
        cbar.label = isflowsum ? "abs. flow [MWh]" : "line utilization"

        # Signed flow sum over the window drives the direction arrowheads. A line whose flow
        # reverses inside the window can cancel to ≈ 0; that is a real statement about the
        # window ("no net transfer"), so the head is dropped rather than forced one way.
        if show_flow_direction
            S = st.S
            pbuf = flow_pts[]
            @inbounds for (i, s) in enumerate(st.seg)
                net = 0.0f0
                if s != 0
                    for j in cols
                        net += S[s, j]
                    end
                end
                m = flow_mid[i]
                if abs(net) <= zero_tol
                    # collapsed: all four points on the midpoint, nothing drawn
                    pbuf[4i-3] = pbuf[4i-2] = pbuf[4i-1] = pbuf[4i] = m
                    continue
                end
                # `u` points from→to, so a negative net flow just flips it
                sgn = net > 0 ? 1.0f0 : -1.0f0
                ux, uy = sgn * flow_unit[i][1], sgn * flow_unit[i][2]
                # perpendicular of (ux, uy)
                px, py = -uy, ux
                apex = Point2f(m[1] + chev_len * ux, m[2] + chev_len * uy)
                back = -chev_len
                pbuf[4i-3] = Point2f(apex[1] + back * ux + chev_wid * px,
                                     apex[2] + back * uy + chev_wid * py)
                pbuf[4i-2] = apex
                pbuf[4i-1] = Point2f(apex[1] + back * ux - chev_wid * px,
                                     apex[2] + back * uy - chev_wid * py)
                pbuf[4i] = apex
            end
            notify(flow_pts)
        end

        node_text = ""
        cbuf, sbuf = node_color[], node_size[]
        abuf, acbuf = inj_dirs[], inj_color[]
        if st.D === nothing && st.NI === nothing
            set_key!(:none)
            fill!(cbuf, _NODE_PLAIN_COLOR)
            fill!(sbuf, 5.0f0)
            fill!(abuf, Vec2f(0, 0))
        elseif st.D === nothing
            set_key!(:injection)
            # Mean over the window, in MW — not a sum in MWh like the redispatch circles, so
            # that a 1 h and a 168 h window put arrows on the same scale.
            NI = st.NI
            fill!(nibuf, 0.0f0)
            @inbounds for j in cols, i in eachindex(nibuf)
                nibuf[i] += NI[i, j]
            end
            nibuf ./= nhours
            maxabs = 0.0
            @inbounds for x in nibuf
                maxabs = max(maxabs, abs(Float64(x)))
            end
            ref = injection_ref === nothing ? maxabs : Float64(injection_ref)
            inj_refmag[] = ref
            aspan = max_arrow - min_arrow
            @inbounds for i in eachindex(nibuf)
                x = nibuf[i]
                # Linear in the magnitude, unlike the sqrt/area circles below — see the
                # comment on `inj_scale_arrows`.
                len = ref <= zero_tol ? min_arrow :
                      min_arrow + aspan * clamp(Float32(abs(x) / ref), 0.0f0, 1.0f0)
                abuf[i] = abs(x) <= zero_tol ? Vec2f(0, 0) :
                          x > 0 ? Vec2f(0, len) : Vec2f(0, -len)
                acbuf[i] = abs(x) <= zero_tol ? _REDISP_ZERO_COLOR :
                           x > 0 ? _REDISP_UP_COLOR : _REDISP_DOWN_COLOR
                # The dot stays as an anchor, so a node at ≈ 0 injection (no arrow) is
                # still locatable on the map.
                cbuf[i] = abs(x) <= zero_tol ? _REDISP_ZERO_COLOR : _NODE_PLAIN_COLOR
                sbuf[i] = _NODE_ANCHOR_SIZE
            end
            notify(inj_color)
            node_text = " | max |net injection| = $(_fmt_val(maxabs)) MW"
        else
            set_key!(:redisp)
            fill!(abuf, Vec2f(0, 0))
            D = st.D
            fill!(dvbuf, 0.0f0)
            @inbounds for j in cols, i in eachindex(dvbuf)
                dvbuf[i] += D[i, j]
            end
            maxabs = 0.0
            @inbounds for x in dvbuf
                maxabs = max(maxabs, abs(Float64(x)))
            end
            ref = redisp_ref === nothing ? maxabs : Float64(redisp_ref)
            refmag[] = ref
            span = Float32(max_markersize - min_markersize)
            @inbounds for i in eachindex(dvbuf)
                x = dvbuf[i]
                cbuf[i] = abs(x) <= zero_tol ? _REDISP_ZERO_COLOR :
                          x > 0 ? _REDISP_UP_COLOR : _REDISP_DOWN_COLOR
                sbuf[i] = ref <= zero_tol ? Float32(min_markersize) :
                          Float32(min_markersize) +
                          span * sqrt(clamp(Float32(abs(x) / ref), 0.0f0, 1.0f0))
            end
            node_text = " | max |Δ injection| = $(_fmt_val(maxabs)) MWh" *
                (st.slack > zero_tol ? " | nodal slack = $(_fmt_val(st.slack)) MWh" : "")
        end
        notify(node_color)
        notify(node_size)
        notify(inj_dirs)

        unit_suffix = ishours ? " h" : isflowsum ? " MWh" : ""
        info.text = "$(state_menu.selection[]) | t = $lo..$hi ($nhours h) | " *
                    "$(mode_menu.selection[]) | max = $(_fmt_val(peak))$unit_suffix" *
                    node_text
        return nothing
    end

    on(_ -> redraw!(), state_menu.selection)
    on(_ -> redraw!(), mode_menu.selection)
    on(_ -> redraw!(), scale_menu.selection)
    on(_ -> redraw!(), thr_slider.value)
    on(_ -> redraw!(), islider.interval)

    redraw!()
    return fig
end
