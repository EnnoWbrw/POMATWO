# =============================================================================
# Reference-day / ShareShift visualization.
#
#   plot_shift_map_interactive(results)          geographic map of the nodal
#       injection deltas caused by the ShareShift (green = increase,
#       red = decrease), with a component filter and a time-window slider, plus
#       an optional AC-line colouring by the reference-day basecase flow
#       (|flow|, utilization, or the F0 intercept under a selectable GSK).
#   plot_refday_dispatch_interactive(variant, source)   per-zone stacked-bar
#       comparison of (1) the selected reference day, (2) the forecast/target
#       day, (3) the shifted basecase and (4) the actual flow-based DA
#       clearing, with net-position markers per stage, zone menu, aggregation
#       menu and time-window slider. Plant types use params.colors.
#
# Private helpers are prefixed `_refday_`/`_shift_` to keep them apart from
# plotting_functions.jl, whose `_plot_colors`, `_color_for`, `_hex_color`,
# `_zone_load_series`, `_line_endpoints_from_results`, `_clear_legends!` and
# `_auto_map_extent` are reused here.
#
# Both plots keep their scene children fixed and drive them through Observables:
# the geometry (line segments, node markers, bar series) is built once and a
# slider tick only rewrites preallocated value buffers. Reductions run over a
# dense `key × time` matrix (`_ZoneKeyTable`) rather than the nested
# `Dict{String,Dict{Int,Dict{String,Float64}}}` these aggregations used to build.
# =============================================================================

# Stacking/legend order of the real nodal shift components ("np_relax" is a
# per-zone residual, not a nodal delta — it is reported separately).
const _SHIFT_COMPONENTS = ["RES_prestep", "load_prestep", "RES", "conv", "load", "sto",
                           "balance"]

# Muted colors + black stroke mark shift-delta segments as synthetic (not
# plant types). Makie has no hatching. Parsed once, so the colour vectors handed
# to Makie are `Vector{RGBAf}` rather than `Vector{Any}` of hex strings.
const REFDAY_SHIFT_COLORS = Dict{String,RGBAf}(
    "RES_prestep"  => _hex_color("#b5d4b0"),
    "load_prestep" => _hex_color("#e0c766"),
    "RES"          => _hex_color("#5aa469"),
    "conv"         => _hex_color("#8c8c8c"),
    "load"         => _hex_color("#c9a227"),
    "sto"          => _hex_color("#4ca37a"),
    "balance"      => _hex_color("#a9a9a9"),
    "np_relax"     => _hex_color("#c85a89"),
)

# Storage charging (pumped-hydro/PSP): a real withdrawal that lowers net position.
# Drawn as a downward bar so the net-position diamond reads off the stack.
const _CHARGE_COLOR = _hex_color("#6b5b95")

const _SHIFT_UP_COLOR   = RGBAf(0.13, 0.55, 0.13, 0.85)
const _SHIFT_DOWN_COLOR = RGBAf(0.70, 0.13, 0.13, 0.85)
const _SHIFT_ZERO_COLOR = RGBAf(0.40, 0.40, 0.40, 0.50)

# Single key of the charge tables, which have no type dimension.
const _CHARGE_KEY = "charge"

# --- reference-day line layer ------------------------------------------------
# Menu labels of the line-value modes. `none` keeps the flat grey topology the shift map
# has always drawn; every other mode colours the AC lines from REFDAY_LINEFLOW.
const _RD_LINE_NONE = "none"
const _RD_LINE_FLOW = "|flow| (MW)"
const _RD_LINE_UTIL = "utilization"
const _RD_LINE_F0 = "|F0| (MW)"
const _RD_LINE_F0UTIL = "|F0| / fmax"
const _RD_LINE_MODES = [_RD_LINE_NONE, _RD_LINE_FLOW, _RD_LINE_UTIL,
                        _RD_LINE_F0, _RD_LINE_F0UTIL]

# Symbol form of the same, for the `line_value` keyword.
const _RD_LINE_BY_SYMBOL = Dict{Symbol,String}(
    :none => _RD_LINE_NONE,
    :flow => _RD_LINE_FLOW,
    :utilization => _RD_LINE_UTIL,
    :f0 => _RD_LINE_F0,
    :f0_utilization => _RD_LINE_F0UTIL,
)

# The two F0 modes are the only ones the GSK menu affects.
_rd_is_f0(mode) = mode == _RD_LINE_F0 || mode == _RD_LINE_F0UTIL
# The two share modes divide by fmax; the MW modes do not.
_rd_is_share(mode) = mode == _RD_LINE_UTIL || mode == _RD_LINE_F0UTIL

const _RD_AGG_MEAN = "mean"
const _RD_AGG_HOURS = "hours ≥ threshold"
const _RD_AGG_SUM = "sum"
const _RD_AGG_MODES = [_RD_AGG_MEAN, _RD_AGG_HOURS, _RD_AGG_SUM]
const _RD_AGG_BY_SYMBOL = Dict{Symbol,String}(
    :mean => _RD_AGG_MEAN, :hours => _RD_AGG_HOURS, :sum => _RD_AGG_SUM)

# Flat grey of the `none` mode — the colour the shift map drew before this layer existed.
const _RD_LINE_PLAIN = RGBAf(0.0, 0.0, 0.0, 0.35)

# =============================================================================
# shared helpers
# =============================================================================

_refday_has_coords(params, n) = _has_coords(params.node_coords, n)

"""
Dense `zone -> (key × time)` value table.

Replaces the `Dict{String,Dict{Int,Dict{String,Float64}}}` the aggregations below used to
return. That shape cost three chained hash lookups per (key, hour) inside `redraw!`, and
`get(store, t, Dict{String,Float64}())` allocated a fresh empty `Dict` on **every** miss
because `get`'s default argument is evaluated eagerly — at `|types| × |window|` calls per
slider tick that was the dominant allocator of the reference-day plot. Here the keys are
resolved to indices once and a reduction walks a matrix row.
"""
struct _ZoneKeyTable
    keys::Vector{String}
    keypos::Dict{String,Int}
    timepos::Dict{Int,Int}
    data::Dict{String,Matrix{Float64}}
end

"""
    _build_zone_key_table(emit, zones, timepos) -> _ZoneKeyTable

`emit(f)` must call `f(zone, time, key, value)` for every row of the source. It is called
twice: once to collect the key set (so the matrices can be dense and index-resolved), once
to sum. `emit` is specialised on the callback, so the inner loops do not dispatch per row.
"""
function _build_zone_key_table(emit::E, zones, timepos) where {E}
    seen = Set{String}()
    emit() do _, _, key, _
        push!(seen, String(key))
        return nothing
    end
    keys_ = sort!(collect(seen))
    keypos = Dict{String,Int}(k => i for (i, k) in enumerate(keys_))
    # Positional zone lookup in the row loop, for the same reason as `_dispatch_data`:
    # an `Int` miss-marker keeps the hot path free of a `Union`-typed return.
    mats = [zeros(Float64, length(keys_), length(timepos)) for _ in zones]
    zone_idx = Dict{String,Int}(z => i for (i, z) in enumerate(zones))

    emit() do zone, t, key, v
        zi = get(zone_idx, zone, 0)
        zi == 0 && return nothing
        ki = get(keypos, key, 0)
        ki == 0 && return nothing
        j = get(timepos, Int(t), 0)
        j == 0 && return nothing
        @inbounds mats[zi][ki, j] += v
        return nothing
    end
    data = Dict{String,Matrix{Float64}}(z => mats[i] for (i, z) in enumerate(zones))
    return _ZoneKeyTable(keys_, keypos, timepos, data)
end

"Time index of `t`, or `0` when it is outside the table's axis."
_zk_index(tbl::_ZoneKeyTable, t) = get(tbl.timepos, Int(t), 0)

"""
    _zk_reduce(tbl, zone, key, tidx, use_mean; absval = false)

Mean or sum of row `key` of `zone` over the time indices `tidx`.

A `0` entry in `tidx` (a time the table does not cover) contributes `0.0` but still counts
towards the mean — matching the old `[at(store, t, key) for t in W]` comprehension, which
produced a `0.0` element for a missing time.
"""
function _zk_reduce(tbl::_ZoneKeyTable, zone, key, tidx, use_mean; absval::Bool = false)
    isempty(tidx) && return 0.0
    M = get(tbl.data, zone, nothing)
    ki = get(tbl.keypos, key, 0)
    (M === nothing || ki == 0) && return 0.0
    s = 0.0
    @inbounds for j in tidx
        j == 0 && continue
        v = M[ki, j]
        s += absval ? abs(v) : v
    end
    return use_mean ? s / length(tidx) : s
end

"Value of one (zone, key, time index) cell."
function _zk_value(tbl::_ZoneKeyTable, zone, key, j)
    j == 0 && return 0.0
    M = get(tbl.data, zone, nothing)
    ki = get(tbl.keypos, key, 0)
    (M === nothing || ki == 0) && return 0.0
    return @inbounds M[ki, j]
end

"Sum over all keys of `zone` at time index `j` (the old `gen_tot`)."
function _zk_total(tbl::_ZoneKeyTable, zone, j)
    j == 0 && return 0.0
    M = get(tbl.data, zone, nothing)
    M === nothing && return 0.0
    s = 0.0
    @inbounds for i in axes(M, 1)
        s += M[i, j]
    end
    return s
end

"Sum over the rows listed in `rows` of `zone` at time index `j`."
function _zk_partial(tbl::_ZoneKeyTable, zone, rows, j)
    j == 0 && return 0.0
    M = get(tbl.data, zone, nothing)
    M === nothing && return 0.0
    s = 0.0
    @inbounds for i in rows
        s += M[i, j]
    end
    return s
end

"""
Rows of a plant-keyed result column as `(zone, time, key, value)`.

The loop lives in a separate method so it specialises on the concrete column types — see
[`_fill_util!`](@ref) in line_utils_interactive.jl for why locals are not enough.
"""
function _emit_plant_column(f::F, df, col, plant2zone, type_of, label) where {F}
    (df isa DataFrame && !isempty(df) && hasproperty(df, col)) || return nothing
    return _emit_plant_rows(f, df.index, df.Time, df[!, col], plant2zone, type_of, label)
end

function _emit_plant_rows(f::F, idx, tt, vals, plant2zone, type_of, label) where {F}
    @inbounds for k in eachindex(idx, tt, vals)
        v = vals[k]
        ismissing(v) && continue
        p = String(idx[k])
        z = get(plant2zone, p, "")
        isempty(z) && continue
        key = label === nothing ? get(type_of, p, "unknown") : label
        f(z, Int(tt[k]), key, Float64(v))
    end
    return nothing
end

"""
Rows of `REFDAY_SHIFT` as `(zone, time, component, delta)`.

`np_relax` is a per-zone residual, so for those rows the `node` column already holds a zone
label; every other component is mapped through `node2zone`.
"""
function _emit_shift_rows(f::F, df, node2zone) where {F}
    (df isa DataFrame && !isempty(df)) || return nothing
    return _emit_shift_cols(f, df.component, df.node, df.Time, df.delta, node2zone)
end

function _emit_shift_cols(f::F, comp, node, tt, delta, node2zone) where {F}
    @inbounds for k in eachindex(comp, node, tt, delta)
        d = delta[k]
        ismissing(d) && continue
        c = String(comp[k])
        n = String(node[k])
        z = c == "np_relax" ? n : get(node2zone, n, "")
        isempty(z) && continue
        f(z, Int(tt[k]), c, Float64(d))
    end
    return nothing
end

"""
REFDAY_SHIFT trace -> arrays for the map plot.

Returns `(times, nodes, comp_mats, total, unabsorbed)` where `comp_mats[c]`
and `total` are `length(nodes) × length(times)` delta matrices (MW, injection
convention: for the `load` component a positive delta means load *decrease*)
and `unabsorbed` maps a timestep to the `Σ|delta|` of the per-zone `np_relax`
residual rows at that time.

Built by walking the result columns directly. The previous version materialised
`String.(df.component)`, a `BitVector` and a full copy of the frame (`df[.!is_unabs, :]`)
before touching a single value, and then summed `comp_mats` a second time to get `total`.
"""
function _shift_arrays(results)
    df = results.REFDAY_SHIFT
    (df isa DataFrame && !isempty(df)) || error(
        "REFDAY_SHIFT is empty — this run has no reference-day shift trace " *
        "(is it a ReferenceDayBasecase run with collect_trace enabled?)")

    compcol, nodecol, timecol, deltacol = df.component, df.node, df.Time, df.delta
    params = results.params

    # pass 1: the time axis and the components present on the real (non-residual) rows
    times_set = Set{Int}()
    comps_seen = Set{String}()
    unabsorbed = Dict{Int,Float64}()
    _shift_scan!(times_set, comps_seen, unabsorbed, compcol, timecol, deltacol)

    times = sort!(collect(times_set))
    # Same all-or-nothing rule as `_results_topology`, so the node set here and the node
    # positions there always agree. While SOME node carries coordinates, one that does not
    # cannot be placed and its deltas are dropped (warned about below). When NO node does,
    # the map falls back to a circular layout that can place every one of them — filtering
    # here would then leave the map with no markers at all.
    nodes = any(n -> _refday_has_coords(params, n), params.sets.N) ?
        [n for n in params.sets.N if _refday_has_coords(params, n)] :
        collect(params.sets.N)
    tpos = Dict{Int,Int}(t => i for (i, t) in enumerate(times))
    npos = Dict{String,Int}(n => i for (i, n) in enumerate(nodes))

    comps = [c for c in _SHIFT_COMPONENTS if c in comps_seen]
    comp_mats = Dict{String,Matrix{Float64}}(
        c => zeros(Float64, length(nodes), length(times)) for c in comps)
    total = zeros(Float64, length(nodes), length(times))

    # pass 2: sum into the component matrices and the total in one go
    unknown = Set{String}()
    dropped = _shift_fill!(comp_mats, total, unknown, compcol, nodecol, timecol, deltacol,
                           npos, tpos)
    dropped > 0 && @warn "Σ|delta| = $(round(dropped, digits = 1)) MW on nodes without coordinates — not shown on the map."
    isempty(unknown) || @warn "REFDAY_SHIFT component(s) not in _SHIFT_COMPONENTS, not shown: $(join(sort!(collect(unknown)), ", "))"

    return (; times, nodes, comp_mats, total, unabsorbed)
end

"Pass 1 of [`_shift_arrays`](@ref), behind a function barrier (see [`_fill_util!`](@ref))."
function _shift_scan!(times_set, comps_seen, unabsorbed, compcol, timecol, deltacol)
    @inbounds for k in eachindex(compcol, timecol, deltacol)
        t = Int(timecol[k])
        c = String(compcol[k])
        if c == "np_relax"
            d = deltacol[k]
            ismissing(d) || (unabsorbed[t] = get(unabsorbed, t, 0.0) + abs(Float64(d)))
            continue
        end
        push!(times_set, t)
        push!(comps_seen, c)
    end
    return nothing
end

"Pass 2 of [`_shift_arrays`](@ref); returns the `Σ|delta|` dropped for want of a coordinate."
function _shift_fill!(comp_mats, total, unknown, compcol, nodecol, timecol, deltacol, npos, tpos)
    dropped = 0.0
    @inbounds for k in eachindex(compcol, nodecol, timecol, deltacol)
        c = String(compcol[k])
        c == "np_relax" && continue
        raw = deltacol[k]
        ismissing(raw) && continue
        d = Float64(raw)
        M = get(comp_mats, c, nothing)
        if M === nothing
            push!(unknown, c)
            continue
        end
        ni = get(npos, String(nodecol[k]), 0)
        ti = get(tpos, Int(timecol[k]), 0)
        if ni == 0 || ti == 0
            dropped += abs(d)
            continue
        end
        M[ni, ti] += d
        total[ni, ti] += d
    end
    return dropped
end

"""
    _refday_line_arrays(results) -> (lines, times, S, cap)

Reference-day basecase flows as a dense `length(lines) × length(times)` matrix.

`S` keeps the persisted sign (import-positive, i.e. the negative of the physical feed-in
flow — see the NETINPUT/ACINJECTION note in `CLAUDE.md`); every display mode takes `abs`,
so only the magnitude is ever painted and the convention cannot mislead. `cap` is the AC
thermal rating per line from `params.acline_capacity`, `0.0` where the line has none —
`REFDAY_LINEFLOW` carries no `line_capacity` column of its own, unlike the `LINEFLOW`
result tables.

`lines × times` (not the transpose) so a time window is a set of contiguous columns and
`view(S, :, cols)` needs no copy — the same layout as [`_line_util_matrix`](@ref).

Empty arrays when the run carries no `REFDAY_LINEFLOW`; the caller then offers only the
`none` line mode.
"""
function _refday_line_arrays(results)
    df = results.REFDAY_LINEFLOW
    (df isa DataFrame && !isempty(df)) ||
        return String[], Int[], zeros(Float64, 0, 0), Float64[]

    times = sort!(unique(Int.(df.Time)))
    lines = sort!(unique(String.(df.index)))
    tpos = Dict{Int,Int}(t => i for (i, t) in enumerate(times))
    lpos = Dict{String,Int}(l => i for (i, l) in enumerate(lines))

    S = zeros(Float64, length(lines), length(times))
    _fill_refday_flow!(S, df.index, df.Time, df.LINEFLOW, lpos, tpos)

    caps = results.params.acline_capacity
    cap = [Float64(get(caps, l, 0.0)) for l in lines]
    return lines, times, S, cap
end

"Function barrier for the [`_refday_line_arrays`](@ref) fill loop — see [`_fill_util!`](@ref) for why."
function _fill_refday_flow!(S, idx, tt, vals, lpos, tpos)
    @inbounds for k in eachindex(idx, tt, vals)
        v = vals[k]
        ismissing(v) && continue
        i = get(lpos, String(idx[k]), 0)
        j = get(tpos, Int(tt[k]), 0)
        (i == 0 || j == 0) && continue
        S[i, j] = Float64(v)
    end
    return S
end

"""
    _rd_reduce!(dest, V, cols, agg, share, thr)

Window reduction of a `lines × times` value matrix into `dest`, one entry per line.

`agg` is one of [`_RD_AGG_MEAN`](@ref), [`_RD_AGG_SUM`](@ref), [`_RD_AGG_HOURS`](@ref).
In the hours mode `share` supplies the |value| / fmax matrix the threshold is compared
against — a threshold in MW would mean nothing across a network of mixed ratings, so the
count is always over the utilization share even when the painted value is MW.

Writes into `dest` rather than allocating, so a slider drag does not allocate per pixel.
"""
function _rd_reduce!(dest, V, cols, agg, share, thr)
    n = length(cols)
    @inbounds for i in eachindex(dest)
        if agg == _RD_AGG_HOURS
            c = 0
            for j in cols
                share[i, j] >= thr && (c += 1)
            end
            dest[i] = Float32(c)
        else
            s = 0.0
            for j in cols
                s += V[i, j]
            end
            dest[i] = Float32(agg == _RD_AGG_MEAN && n > 0 ? s / n : s)
        end
    end
    return dest
end

"""
(zone, target_time) -> matched reference time (+ fallback flag) from
REFDAY_MATCH. Groups are zone labels under ZonalMatchScope; otherwise falls
back to node-level matches mapped through node2zone (first node wins, warning
if matches differ within a zone).
"""
function _refday_zone_ref_times(variant)
    params = variant.params
    match = variant.REFDAY_MATCH
    isempty(match) && error("REFDAY_MATCH is empty — no reference-day matching trace in this run.")

    refmap = Dict{String,Dict{Int,Int}}()
    fbmap  = Dict{String,Dict{Int,Bool}}()
    zoneset = Set(params.sets.Z)

    if all(g -> String(g) in zoneset, unique(match.group))
        grp, tgt, mt, fb = match.group, match.target_time, match.matched_time, match.fallback
        @inbounds for k in eachindex(grp, tgt, mt, fb)
            z = String(grp[k])
            get!(refmap, z, Dict{Int,Int}())[Int(tgt[k])] = Int(mt[k])
            get!(fbmap, z, Dict{Int,Bool}())[Int(tgt[k])] = Bool(fb[k])
        end
    else
        @warn "REFDAY_MATCH groups are not zone labels — deriving zone reference times from node-level matches."
        rt = POMATWO.refday_reference_times(variant)   # group ⋈ node ⋈ match
        nodes, tgt, mtc, fb = rt.node, rt.target_time, rt.matched_time, rt.fallback
        conflict = false
        @inbounds for k in eachindex(nodes, tgt, mtc, fb)
            z = get(params.node2zone, nodes[k], missing)
            ismissing(z) && continue
            d = get!(refmap, String(z), Dict{Int,Int}())
            tt, m = Int(tgt[k]), Int(mtc[k])
            haskey(d, tt) && d[tt] != m && (conflict = true)
            get!(d, tt, m)
            get!(get!(fbmap, String(z), Dict{Int,Bool}()), tt, Bool(fb[k]))
        end
        conflict && @warn "Nodes within one zone matched different reference times; using the first per zone."
    end
    return refmap, fbmap
end

# =============================================================================
# Plot 1 — geographic shift map
# =============================================================================
"""
    plot_shift_map_interactive(results; kwargs...)

Geographic map of the ShareShift impact for one reference-day scenario.
Topology (AC solid, DC dashed) plus one circle per node: green = net
injection increase, red = decrease, gray ≈ 0; marker area ∝ |Σ delta| in the
selected time window.

Deltas follow the injection convention of REFDAY_SHIFT: for the `load`
component a positive delta is a load *decrease*. "total" sums the real nodal
components (RES_prestep, RES, conv, load, sto, balance); the per-zone
`np_relax` residual is reported in the info label only.

On a geographic run the axis is a map axis: degree ticks (`10°E`, `52°N`),
`Longitude` / `Latitude` labels, a kilometre scale bar and a north arrow, all of
which follow zoom and pan. Geometry stays in Web Mercator — state the CRS,
`WGS 84 / Pseudo-Mercator (EPSG:3857)`, in the figure caption, and note that
mercator scale is latitude-dependent, so the scale bar is exact only at the
latitude it is drawn at.

If NO node in the run carries coordinates, the nodes are laid out on a circle
instead, the basemap is suppressed and none of the map decorations are drawn
(noted in the axis subtitle). Topology, line styling and the node markers all
still read correctly; only the geography is gone. While SOME node has
coordinates the behaviour is unchanged: a node without them cannot be placed and
its deltas are dropped, with a warning naming the total dropped MW.

# Line layer
The AC lines can be coloured by the assembled reference-day basecase flow, read from
`REFDAY_LINEFLOW`:

- `none` — flat grey topology (the behaviour before this layer existed),
- `|flow| (MW)` / `utilization` — the basecase flow magnitude, raw or over the line's AC
  rating,
- `|F0| (MW)` / `|F0| / fmax` — the flow-based intercept `F0` recomputed from that same
  basecase under the GSK picked in the GSK menu (`refday_f0`), over **every** AC line, not
  only the CNEs.

The GSK menu is built from `gsk_strategies()`, so a strategy added to POMATWO later
appears without this plot being changed; a strategy needing constructor arguments (e.g.
`CustomWeightsGSK`) is supplied through `gsk_options`. `F0` is a linearization intercept,
not a physical flow — `|F0| > fmax` is legitimate and is neither clamped nor flagged.

DC lines stay dashed grey in every mode: `REFDAY_LINEFLOW` covers AC lines only. An AC line
the basecase has no flow for sits at the bottom of the colour scale.

# Interactivity
- Component menu: total / individual shift components (node markers).
- Line value menu, GSK menu, aggregation menu (`mean`, `hours ≥ threshold`, `sum`),
  colour-scale menu (`adaptive (this window)` / `fixed (whole horizon)`) and a threshold
  slider (line layer). The threshold is always compared against `|value| / fmax`, in the
  MW modes too — a MW threshold means nothing across a network of mixed ratings.
- IntervalSlider: single timestep (handles together) or Σ over a window.

# Keyword arguments
`figsize=(1250,1100)`, `background_map=true` (Tyler/CartoDB tiles; the axis stays
a map axis without them), `exclude_dc_lines=false`, `extent_pad=0.5` (degrees), `max_markersize=40`,
`min_markersize=2.5`, `zero_tol=1e-6` (MW).

Line layer: `line_value=:none` (`:none`, `:flow`, `:utilization`, `:f0`,
`:f0_utilization`), `line_agg=:mean` (`:mean`, `:hours`, `:sum`), `line_scale=:window`
(`:window`, `:horizon`), `threshold=0.8`, `gsk=nothing` (a `GSKStrategy` or its type name;
defaults to `FlatGSK`), `gsk_options=gsk_strategies()`, `linewidth=1.0`,
`linewidth_by_capacity=true`, `linewidth_range=(0.6,4.5)`.

`map_axis=true` controls the map-axis styling: `true` for degree ticks,
`Longitude`/`Latitude` labels, a scale bar and a north arrow, `false` for a bare
axis in raw Web Mercator metres, or a `NamedTuple` overriding individual settings
(`map_axis = (scalebar = false,)`, `(projection_note = true,)`,
`(north_arrow_position = :lt,)`; fields `scalebar`, `north_arrow`,
`projection_note`, `scalebar_position`, `north_arrow_position`). On a run without
node coordinates it is ignored — the circular fallback has no geography to label.
"""
function POMATWO.plot_shift_map_interactive(
    results;
    figsize          = (1250, 1100),
    background_map   = true,
    exclude_dc_lines = false,
    extent_pad       = 0.5,
    max_markersize   = 40.0,
    min_markersize   = 2.5,
    zero_tol         = 1e-6,
    map_axis         = true,
    line_value       = :none,
    line_agg         = :mean,
    line_scale       = :window,
    threshold        = 0.8,
    gsk              = nothing,
    gsk_options      = POMATWO.gsk_strategies(),
    linewidth        = 1.0,
    linewidth_by_capacity::Bool = true,
    linewidth_range  = (0.6, 4.5),
)
    params = results.params
    sa = _shift_arrays(results)

    haskey(_RD_LINE_BY_SYMBOL, line_value) || throw(ArgumentError(
        "line_value must be one of $(sort!(collect(keys(_RD_LINE_BY_SYMBOL)))), got :$line_value"))
    haskey(_RD_AGG_BY_SYMBOL, line_agg) || throw(ArgumentError(
        "line_agg must be one of $(sort!(collect(keys(_RD_AGG_BY_SYMBOL)))), got :$line_agg"))
    line_scale in (:window, :horizon) ||
        throw(ArgumentError("line_scale must be :window or :horizon, got :$line_scale"))

    # --- reference-day flows -------------------------------------------------
    lf_lines, lf_times, lf_S, lf_cap = _refday_line_arrays(results)
    has_flows = !isempty(lf_lines)

    # GSK roster for the F0 modes. Dynamically discovered (see `gsk_strategies`), so a
    # strategy added to POMATWO later appears here without this file being touched.
    # Anything needing constructor arguments is passed in through `gsk_options` instead.
    gsk_by_name = Dict{String,Any}(string(nameof(typeof(s))) => s for s in gsk_options)
    gsk_names = sort!(collect(keys(gsk_by_name)))
    default_gsk = gsk === nothing ? ("FlatGSK" in gsk_names ? "FlatGSK" :
                                     (isempty(gsk_names) ? "" : first(gsk_names))) :
                  (gsk isa AbstractString ? String(gsk) : string(nameof(typeof(gsk))))
    if !(gsk isa Union{Nothing,AbstractString}) && !haskey(gsk_by_name, default_gsk)
        gsk_by_name[default_gsk] = gsk
        push!(gsk_names, default_gsk)
        sort!(gsk_names)
    end
    isempty(gsk_names) || default_gsk in gsk_names || throw(ArgumentError(
        "gsk \"$default_gsk\" is not among $(join(gsk_names, ", "))"))

    line_modes = has_flows && !isempty(gsk_names) ? _RD_LINE_MODES :
                 has_flows ? [_RD_LINE_NONE, _RD_LINE_FLOW, _RD_LINE_UTIL] :
                 [_RD_LINE_NONE]
    default_mode = _RD_LINE_BY_SYMBOL[line_value]
    default_mode in line_modes || (default_mode = _RD_LINE_NONE)

    # topology: AC solid, DC dashed. `_results_topology` falls back to a circular layout
    # when no node carries coordinates — without it such a result set collapses every node
    # onto one point and draws a blank map.
    ac_from_to, node_lonlat, node_coords, geographic = _results_topology(results, true)

    fig, ax = geographic ?
        create_lineplot_layout(figsize; background_map = background_map,
                               extent = _auto_map_extent(node_coords; pad = extent_pad),
                               geographic = true, map_axis = map_axis) :
        create_lineplot_layout(figsize; background_map = false, geographic = false,
                               map_axis = map_axis)
    geographic || (ax.subtitle = _NO_COORDS_NOTE)

    # Sorted, so a line's position in `ac_pts` is a stable index the colour buffer can be
    # written through. `values(ac_from_to)` was fine while every AC line was the same
    # grey; it is not once the segments carry per-line values.
    ac_lines = sort!(collect(keys(ac_from_to)))
    ac_pts = Vector{Point2f}(undef, 2 * length(ac_lines))
    for (i, l) in enumerate(ac_lines)
        from, to = ac_from_to[l]
        ac_pts[2i-1] = from
        ac_pts[2i] = to
    end

    # Per-line width from the AC rating, so a thin overloaded line and a thick one are
    # visibly different problems — the same rule as `plot_line_utils_interactive`.
    ac_widths = if linewidth_by_capacity && !isempty(ac_lines)
        capmax = maximum(Float64[get(params.acline_capacity, l, 0.0) for l in ac_lines];
                         init = 0.0)
        wlo, whi = Float32(first(linewidth_range)), Float32(last(linewidth_range))
        Float32[capmax <= 0 ? wlo :
                clamp(wlo + (whi - wlo) *
                      Float32(get(params.acline_capacity, l, 0.0) / capmax), wlo, whi)
                for l in ac_lines for _ in 1:2]
    else
        Float32(linewidth)
    end

    # `line_pos[i]` is the row of `lf_S` for `ac_lines[i]`, or 0 for a line the
    # reference-day basecase has no flow for (it stays at the colour-scale floor).
    lf_row = Dict{String,Int}(l => i for (i, l) in enumerate(lf_lines))
    line_pos = [get(lf_row, l, 0) for l in ac_lines]

    crange = Observable((0.0f0, 1.0f0))
    ac_vals = Observable(zeros(Float32, 2 * length(ac_lines)))
    # Two plots over the same geometry: `linestyle`, `colormap` and a flat colour are all
    # per-plot attributes in Makie, so `none` cannot be a state of the coloured plot.
    ac_plain = isempty(ac_pts) ? nothing :
        linesegments!(ax, ac_pts; color = _RD_LINE_PLAIN, linewidth = ac_widths)
    ac_colored = isempty(ac_pts) ? nothing :
        linesegments!(ax, ac_pts; color = ac_vals,
                      colormap = ColorSchemes.lajolla.colors, colorrange = crange,
                      linewidth = ac_widths, visible = false)

    if !exclude_dc_lines
        dc_segs = Dict{String,_Segment}()
        _collect_param_endpoints!(dc_segs, params.sets.DC, params.dc_start, params.dc_end,
                                  node_lonlat)
        dc_pts = Point2f[]
        sizehint!(dc_pts, 2 * length(dc_segs))
        for (from, to) in values(dc_segs)
            push!(dc_pts, from, to)
        end
        # DC always stays flat grey: REFDAY_LINEFLOW covers AC lines only.
        isempty(dc_pts) ||
            linesegments!(ax, dc_pts; color = _RD_LINE_PLAIN, linewidth = 1.0,
                          linestyle = :dash)
    end

    node_points = [node_lonlat[n] for n in sa.nodes]
    nnodes = length(sa.nodes)

    # controls
    comp_options = ["total"; [c for c in _SHIFT_COMPONENTS if haskey(sa.comp_mats, c)]]
    comp_menu = Menu(fig, options = comp_options, default = "total")
    line_menu = Menu(fig, options = line_modes, default = default_mode)
    gsk_menu = Menu(fig, options = isempty(gsk_names) ? ["—"] : gsk_names,
                    default = isempty(gsk_names) ? "—" : default_gsk)
    agg_menu = Menu(fig, options = _RD_AGG_MODES, default = _RD_AGG_BY_SYMBOL[line_agg])
    scale_menu = Menu(fig, options = [_SCALE_WINDOW, _SCALE_HORIZON],
                      default = line_scale === :window ? _SCALE_WINDOW : _SCALE_HORIZON)
    thr_grid = SliderGrid(fig, (label = "threshold", range = 0:0.01:2,
                                startvalue = threshold,
                                format = x -> string(round(Int, 100x)) * " %"))
    thr_slider = thr_grid.sliders[1]

    islider = IntervalSlider(fig[2, 1], range = sa.times,
                             startvalues = (first(sa.times), first(sa.times)))
    info = Label(fig[3, 1], ""; tellwidth = false, fontsize = 13)

    cbar = Colorbar(fig[1, 3]; colormap = ColorSchemes.lajolla.colors,
                    colorrange = crange, label = "line value")

    # --- lazily built value matrices ----------------------------------------
    # One `lines × times` matrix per (mode, GSK) actually selected, kept for the life of
    # the figure. F0 needs a PTDFz per GSK — recomputing it on every slider pixel would
    # make the slider unusable on anything larger than a toy network.
    f0_cache = Dict{String,Matrix{Float64}}()
    val_cache = Dict{String,Tuple{Matrix{Float64},Matrix{Float64}}}()

    function f0_matrix(name)
        get!(f0_cache, name) do
            F0 = POMATWO.refday_f0(results, gsk_by_name[name]; lines = lf_lines)
            [Float64(F0[l, t]) for l in lf_lines, t in lf_times]
        end
    end

    # `(V, share)` for a mode: the painted magnitude and the |value| / fmax the threshold
    # is compared against.
    function value_matrices(mode, name)
        key = _rd_is_f0(mode) ? "$mode|$name" : mode
        get!(val_cache, key) do
            base = _rd_is_f0(mode) ? f0_matrix(name) : lf_S
            V = abs.(base)
            share = similar(V)
            @inbounds for i in axes(V, 1), j in axes(V, 2)
                share[i, j] = lf_cap[i] > 0 ? V[i, j] / lf_cap[i] : 0.0
            end
            return (_rd_is_share(mode) ? share : V, share)
        end
    end

    # Preallocated: a slider drag reassigns these in place rather than allocating three
    # fresh vectors per pixel, which is what the previous `lift` chain did.
    agg = zeros(Float64, nnodes)
    node_color = Observable(fill(_SHIFT_ZERO_COLOR, nnodes))
    node_size = Observable(fill(Float64(min_markersize), nnodes))
    scatter!(ax, node_points; color = node_color, markersize = node_size,
             strokecolor = :white, strokewidth = 0.4)

    line_vals = zeros(Float32, length(lf_lines))

    function redraw_lines!(lo, hi)
        mode = line_menu.selection[]
        ac_plain === nothing && return ""
        if mode == _RD_LINE_NONE || !has_flows
            ac_plain.visible[] = true
            ac_colored.visible[] = false
            # A colour bar over flat grey lines would be a scale for nothing. Its layout
            # cell is kept (only the block's own scene is hidden) so switching modes does
            # not resize the map underneath the cursor.
            cbar.blockscene.visible[] = false
            return ""
        end
        cbar.blockscene.visible[] = true

        name = gsk_menu.selection[]
        V, share = try
            value_matrices(mode, name)
        catch e
            # A user strategy can claim `is_time_dependent` and define no
            # `timedep_node_weight`; that must not kill the whole figure.
            ac_plain.visible[] = true
            ac_colored.visible[] = false
            return " | F0 unavailable for $name: $(sprint(showerror, e))"
        end

        aggm = agg_menu.selection[]
        thr = thr_slider.value[]
        cols = searchsortedfirst(lf_times, lo):searchsortedlast(lf_times, hi)
        _rd_reduce!(line_vals, V, cols, aggm, share, thr)

        # Colour reference. `window` rescales to the visible peak (best contrast, but two
        # windows are not comparable by colour); `horizon` uses the whole-horizon peak of
        # the same reduction so colour means one thing throughout — see `_SCALE_WINDOW`.
        hi_ref = if scale_menu.selection[] == _SCALE_HORIZON
            if aggm == _RD_AGG_HOURS
                Float32(length(lf_times))
            elseif aggm == _RD_AGG_MEAN
                Float32(maximum(V; init = 0.0))
            else
                Float32(maximum(sum(V; dims = 2); init = 0.0))
            end
        else
            Float32(maximum(line_vals; init = 0.0f0))
        end
        # A share scale is anchored at 1.0 so "overloaded" is always the same colour, and
        # an hour count at 1.0 so a single hour over the threshold is not painted as the
        # maximum. An MW scale has no such landmark and floors at a hairline > 0.
        floor_ref = aggm == _RD_AGG_HOURS || _rd_is_share(mode) ? 1.0f0 : 1.0f-9
        crange[] = (0.0f0, max(hi_ref, floor_ref))

        buf = ac_vals[]
        @inbounds for (i, r) in enumerate(line_pos)
            v = r == 0 ? 0.0f0 : line_vals[r]
            buf[2i-1] = v
            buf[2i] = v
        end
        notify(ac_vals)
        ac_plain.visible[] = false
        ac_colored.visible[] = true

        unit = aggm == _RD_AGG_HOURS ? "h" :
               _rd_is_share(mode) ? (aggm == _RD_AGG_SUM ? "share·h" : "share") :
               (aggm == _RD_AGG_SUM ? "MWh" : "MW")
        cbar.label = "$mode — $aggm ($unit)" * (_rd_is_f0(mode) ? ", GSK $name" : "")

        # worst line of the window, named — a colour alone does not identify it
        wi = isempty(line_vals) ? 0 : argmax(line_vals)
        worst = wi == 0 ? "" :
            " | max $(round(Float64(line_vals[wi]), digits = 2)) $unit on $(lf_lines[wi])"
        return " | lines: $mode$(_rd_is_f0(mode) ? " (GSK $name)" : "")$worst"
    end

    function redraw!()
        comp = comp_menu.selection[]
        M = comp == "total" ? sa.total : sa.comp_mats[comp]
        lo, hi = islider.interval[]
        cols = searchsortedfirst(sa.times, lo):searchsortedlast(sa.times, hi)

        fill!(agg, 0.0)
        @inbounds for j in cols, i in eachindex(agg)
            agg[i] += M[i, j]
        end

        mx = 0.0
        @inbounds for x in agg
            mx = max(mx, abs(x))
        end

        cbuf = node_color[]
        sbuf = node_size[]
        scale = mx <= zero_tol ? 0.0 : (max_markersize - min_markersize) / sqrt(mx)
        @inbounds for i in eachindex(agg)
            x = agg[i]
            cbuf[i] = abs(x) <= zero_tol ? _SHIFT_ZERO_COLOR :
                      x > 0 ? _SHIFT_UP_COLOR : _SHIFT_DOWN_COLOR
            sbuf[i] = mx <= zero_tol ? Float64(min_markersize) :
                      min_markersize + scale * sqrt(abs(x))
        end
        notify(node_color)
        notify(node_size)

        line_note = redraw_lines!(lo, hi)

        unabs = 0.0
        for t = lo:hi
            unabs += get(sa.unabsorbed, Int(t), 0.0)
        end
        nhours = hi - lo + 1
        info.text = "t = $lo..$hi ($nhours h, Σ) | component: $comp | " *
                    "max |Δ| = $(round(mx, digits = 1)) MW$(nhours > 1 ? "h" : "") | " *
                    "Σ|np_relax| = $(round(unabs, digits = 1))" * line_note
        return nothing
    end

    on(_ -> redraw!(), islider.interval)
    on(_ -> redraw!(), comp_menu.selection)
    on(_ -> redraw!(), line_menu.selection)
    on(_ -> redraw!(), gsk_menu.selection)
    on(_ -> redraw!(), agg_menu.selection)
    on(_ -> redraw!(), scale_menu.selection)
    on(_ -> redraw!(), thr_slider.value)

    legend = Legend(fig,
        [MarkerElement(marker = :circle, color = _SHIFT_UP_COLOR, markersize = 15),
         MarkerElement(marker = :circle, color = _SHIFT_DOWN_COLOR, markersize = 15),
         MarkerElement(marker = :circle, color = _SHIFT_ZERO_COLOR, markersize = 8),
         LineElement(color = (:black, 0.6), linestyle = :solid),
         LineElement(color = (:black, 0.6), linestyle = :dash)],
        ["injection increase", "injection decrease", "≈ 0", "AC line", "DC line"],
        "Shift impact")
    fig[1, 2] = vgrid!(
        Label(fig, "Component", fontsize = 16), comp_menu,
        Label(fig, "Line value", fontsize = 16), line_menu,
        Label(fig, "GSK (F0 only)", fontsize = 16), gsk_menu,
        Label(fig, "Aggregation", fontsize = 16), agg_menu,
        Label(fig, "Colour scale", fontsize = 16), scale_menu,
        thr_grid, legend; tellheight = false)

    redraw!()
    return fig
end

# =============================================================================
# Plot 2 — reference day vs shifted basecase vs DA clearing
# =============================================================================
"""
    plot_refday_dispatch_interactive(variant, source; kwargs...)

Per-zone comparison of generation, load and net position across the four
stages of the reference-day pipeline:
1. **Reference day** — the source (basecase) run's dispatch by plant type at
   the matched reference times. Pass `source` loaded with the same state the
   `ReferenceDayBasecase` used (e.g. `DataFiles(dir, TwoDayAhead)` for
   `source_type = "2DA"`), so these bars show the state the shift started from,
2. **Target day** — the source run's dispatch at the forecast/target times
   the matching algorithm shifted towards,
3. **Shifted basecase** — the reference-day stack plus one black-stroked
   segment per ShareShift component (ΔRES_prestep/ΔRES/Δconv/Δload/Δsto/
   Δbalance; the shift is a nodal injection change and cannot be attributed to
   plant types), and
4. **DA result** — the variant run's actual flow-based DA dispatch at the
   target times.

Horizontal black markers show zonal load per group (reference-day load,
target load, reference-day load minus the load-shift, target load). Blue
diamonds show the zonal net position (+ = export) per stage, computed as
Σgen − load − charge from the respective tables; the shifted-basecase NP is
`NP(reference) + Σ shift deltas` (all components, export-positive). The
shift guarantees `NP(shifted) + unabsorbed ≈ NP(target)`.

# Interactivity
Zone menu, aggregation menu (`mean` = GW average over the window,
`sum` = GWh), IntervalSlider for single timestep or period.

# Keyword arguments
`scalefactor=1/1000` (MW → GW), `agg=:mean`, `figsize=(1300,850)`.
"""
function POMATWO.plot_refday_dispatch_interactive(
    variant, source;
    scalefactor = 1 / 1000,
    agg         = :mean,
    figsize     = (1300, 850),
)
    params = variant.params
    colors = _plot_colors(variant)

    refmap, fbmap = _refday_zone_ref_times(variant)
    target_times = sort(unique(Int.(variant.GEN.Time)))
    ref_times = Set{Int}()
    for d in values(refmap), r in values(d)
        push!(ref_times, r)
    end

    # One shared time axis for every table, so a lookup is a single index map. Bar 2 needs
    # the target times from the *source* run, hence the union.
    times = sort!(collect(union(ref_times, Set(target_times))))
    timepos = Dict{Int,Int}(t => i for (i, t) in enumerate(times))
    zones = sort(collect(keys(refmap)))
    isempty(zones) && error("No zones with reference-day matches found.")

    p2z = params.plant2zone
    ptype = params.plant_type
    src_tbl = _build_zone_key_table(zones, timepos) do f
        _emit_plant_column(f, source.GEN, :GEN, p2z, ptype, nothing)
    end
    var_tbl = _build_zone_key_table(zones, timepos) do f
        _emit_plant_column(f, variant.GEN, :GEN, p2z, ptype, nothing)
    end
    src_chg = _build_zone_key_table(zones, timepos) do f
        _emit_plant_column(f, hasproperty(source, :CHARGE) ? source.CHARGE : nothing,
                           :CHARGE, p2z, ptype, _CHARGE_KEY)
    end
    var_chg = _build_zone_key_table(zones, timepos) do f
        _emit_plant_column(f, hasproperty(variant, :CHARGE) ? variant.CHARGE : nothing,
                           :CHARGE, p2z, ptype, _CHARGE_KEY)
    end
    shift_tbl = _build_zone_key_table(zones, timepos) do f
        _emit_shift_rows(f, variant.REFDAY_SHIFT, params.node2zone)
    end

    # Reuses the extension's zonal-load helper; `_refday_zone_load` recomputed this from
    # `params.nodal_load` on every slider tick, twice (load markers and net positions).
    zone_load = _zone_load_series(params, times)
    for z in zones   # a REFDAY_MATCH group need not be in params.sets.Z
        haskey(zone_load, z) || (zone_load[z] = zeros(Float64, length(times)))
    end

    # Fixed series sets, so the bar objects can be created once. Both are window
    # independent — the old `redraw!` rebuilt `types` per tick by splatting an unbounded
    # number of key vectors into `vcat`.
    types = sort!(collect(union(Set(src_tbl.keys), Set(var_tbl.keys))))
    shift_comps = [c for c in _SHIFT_COMPONENTS if haskey(shift_tbl.keypos, c)]
    shift_core_rows = [shift_tbl.keypos[c] for c in _SHIFT_COMPONENTS
                       if haskey(shift_tbl.keypos, c)]

    GLMakie.activate!(inline = false)
    fig = Figure(size = figsize)
    ax = Axis(fig[1:3, 1];
              xticks = ([1, 2, 3, 4],
                        ["Reference day", "Target day", "Shifted basecase", "DA result"]),
              title = "")
    zone_menu = Menu(fig, options = zones, fontsize = 20)
    agg_menu = Menu(fig, options = ["mean", "sum"], default = string(agg), fontsize = 20)
    fig[1, 2] = vgrid!(Label(fig, "Market Zone", fontsize = 20, width = 300), zone_menu,
                       Label(fig, "Aggregation", fontsize = 20), agg_menu;
                       tellheight = false)
    islider = IntervalSlider(fig[4, 1], range = target_times,
                             startvalues = (first(target_times), first(target_times)))
    info = Label(fig[5, 1], ""; tellwidth = false, fontsize = 13)

    # --- persistent bar series ------------------------------------------------
    # One `barplot!` per series over the four x positions, created once. The previous
    # `stack!` created one `barplot!` per (stage, segment) — up to 4·(|types|+|comps|)
    # scene children — and destroyed them all on every slider tick.
    series_labels = String[types; "storage charge"; ["Δ$(c) shift" for c in shift_comps]]
    nseries = length(series_labels)
    heights = [Observable(zeros(Float64, 4)) for _ = 1:nseries]
    offsets = [Observable(zeros(Float64, 4)) for _ = 1:nseries]
    bar_handles = Any[]
    xs = [1.0, 2.0, 3.0, 4.0]
    for s = 1:nseries
        is_shift = s > length(types) + 1
        color = if s <= length(types)
            _color_for(colors, types[s])
        elseif s == length(types) + 1
            _CHARGE_COLOR
        else
            REFDAY_SHIFT_COLORS[shift_comps[s-length(types)-1]]
        end
        push!(bar_handles, barplot!(
            ax, xs, heights[s];
            offset = offsets[s], width = 0.7, color = color,
            strokecolor = is_shift ? :black : :transparent,
            strokewidth = is_shift ? 1.0 : 0.0))
    end

    load_pts = Observable(fill(Point2f(0, 0), 4))
    loadplot = scatter!(ax, load_pts; marker = :hline, markersize = 30, color = :black)
    np_pts = Observable(fill(Point2f(0, 0), 4))
    npplot = scatter!(ax, np_pts; marker = :diamond, markersize = 16, color = :royalblue,
                      strokecolor = :black, strokewidth = 1.0)

    function redraw!()
        zone = zone_menu.selection[]
        is_mean = agg_menu.selection[] == "mean"
        lo, hi = islider.interval[]

        # Window in the shared time index space. `Wm`/`R` are the target/reference time
        # pairs that actually carry a match, in the same order.
        zref = get(refmap, zone, Dict{Int,Int}())
        zfb  = get(fbmap, zone, Dict{Int,Bool}())
        Wj = Int[]
        Wmj = Int[]
        Rj = Int[]
        nfall = 0
        nwindow = 0
        for t in target_times
            (lo <= t <= hi) || continue
            nwindow += 1
            push!(Wj, get(timepos, t, 0))
            r = get(zref, t, 0)
            r == 0 && continue
            push!(Wmj, get(timepos, t, 0))
            push!(Rj, get(timepos, r, 0))
            get(zfb, t, false) && (nfall += 1)
        end

        red(tbl, key, idx) = _zk_reduce(tbl, zone, key, idx, is_mean) * scalefactor

        # heights per series, per stage (see the docstring for what each stage shows)
        for s = 1:nseries
            h = heights[s][]
            if s <= length(types)
                pt = types[s]
                h[1] = red(src_tbl, pt, Rj)
                h[2] = red(src_tbl, pt, Wj)
                h[3] = h[1]                       # stage 3 restacks the reference day
                h[4] = red(var_tbl, pt, Wj)
            elseif s == length(types) + 1
                # storage charge is a withdrawal, drawn downward; stage 3 is left to its
                # Δsto shift segment, so no charge bar there
                h[1] = -red(src_chg, _CHARGE_KEY, Rj)
                h[2] = -red(src_chg, _CHARGE_KEY, Wj)
                h[3] = 0.0
                h[4] = -red(var_chg, _CHARGE_KEY, Wj)
            else
                c = shift_comps[s-length(types)-1]
                h[1] = 0.0
                h[2] = 0.0
                h[3] = red(shift_tbl, c, Wmj)
                h[4] = 0.0
            end
        end

        # stacking offsets: positives up from 0, negatives down from 0, in series order
        for x = 1:4
            pos, neg = 0.0, 0.0
            for s = 1:nseries
                v = heights[s][][x]
                o = offsets[s][]
                if v >= 0
                    o[x] = pos
                    pos += v
                else
                    o[x] = neg
                    neg += v
                end
            end
        end
        foreach(notify, heights)
        foreach(notify, offsets)

        # `f` in the original: mean or sum over the window, scaled, 0.0 on an empty window.
        zl = zone_load[zone]
        function reduce_over(g, idx)
            isempty(idx) && return 0.0
            s = 0.0
            for j in idx
                s += g(j)
            end
            return (is_mean ? s / length(idx) : s) * scalefactor
        end
        load_at(j) = j == 0 ? 0.0 : @inbounds zl[j]

        # load markers: the actual load change of the shift is -delta(load)
        load_ref = reduce_over(load_at, Rj)
        load_tgt = reduce_over(load_at, Wj)
        load_shift = load_ref - red(shift_tbl, "load", Wmj)
        load_pts[] = Point2f[Point2f(1, load_ref), Point2f(2, load_tgt),
                             Point2f(3, load_shift), Point2f(4, load_tgt)]

        # net position (+ = export): Σgen − load − charge per stage; the shifted basecase
        # uses the identity NP(ref) + Σ deltas (export-positive)
        np_src(j) = _zk_total(src_tbl, zone, j) - load_at(j) -
                    _zk_value(src_chg, zone, _CHARGE_KEY, j)
        np_var(j) = _zk_total(var_tbl, zone, j) - load_at(j) -
                    _zk_value(var_chg, zone, _CHARGE_KEY, j)
        np_ref = reduce_over(np_src, Rj)
        np_tgt = reduce_over(np_src, Wj)
        np_da  = reduce_over(np_var, Wj)
        # `Rj[i]` and `Wmj[i]` are the reference/target pair of the same matched hour:
        # the dispatch is read at the reference time, the shift deltas at the target time.
        np_shift = reduce_over(
            i -> np_src(Rj[i]) + _zk_partial(shift_tbl, zone, shift_core_rows, Wmj[i]),
            eachindex(Wmj))
        np_pts[] = Point2f[Point2f(1, np_ref), Point2f(2, np_tgt),
                           Point2f(3, np_shift), Point2f(4, np_da)]

        # --- legend: only the series that are actually non-zero in this window, in the
        # order the stages draw them (stage 1 first), matching the old `seen` dedup.
        handles, labels, seen = Any[], String[], Set{String}()
        for x = 1:4, s = 1:nseries
            heights[s][][x] == 0.0 && continue
            lbl = series_labels[s]
            lbl in seen && continue
            push!(seen, lbl)
            push!(handles, bar_handles[s])
            push!(labels, lbl)
        end
        push!(handles, loadplot); push!(labels, "Load")
        push!(handles, npplot);   push!(labels, "Net position")

        unabs = _zk_reduce(shift_tbl, zone, "np_relax", Wmj, is_mean; absval = true) * scalefactor
        unit = is_mean ? "GW" : "GWh"
        ax.ylabel = is_mean ? "GW (mean)" : "GWh (sum)"
        rnd(x) = round(x, digits = 2)
        info.text = "zone $zone | t = $lo..$hi ($nwindow h) | matched: $(length(Wmj))/$nwindow | " *
                    "fallback matches: $nfall | $(agg_menu.selection[]) |np_relax| = " *
                    "$(round(unabs, digits = 3)) $unit | NP [ref/tgt/shift/DA] = " *
                    "$(rnd(np_ref)) / $(rnd(np_tgt)) / $(rnd(np_shift)) / $(rnd(np_da)) $unit"
        autolimits!(ax)
        _clear_legends!(fig)
        Legend(fig[2:3, 2], handles, labels, "Legend", nbanks = 2)
        return nothing
    end

    redraw!()
    on(_ -> redraw!(), zone_menu.selection)
    on(_ -> redraw!(), agg_menu.selection)
    on(_ -> redraw!(), islider.interval)

    return fig
end
