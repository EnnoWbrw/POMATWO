# =============================================================================
# Reference-day / ShareShift visualization.
#
#   plot_shift_map_interactive(results)          geographic map of the nodal
#       injection deltas caused by the ShareShift (green = increase,
#       red = decrease), with a component filter and a time-window slider, plus
#       an optional AC-line colouring by the reference-day basecase flow
#       (|flow|, utilization, or the F0 intercept under a selectable GSK).
#   plot_refday_dispatch_interactive(variant, source)   per-zone stacked-bar
#       comparison at ONE timestep of (1) the matched reference day, (2) the
#       ShareShift decomposition, (3) the shifted reference day and (4) a
#       selectable market state, with a net-position marker per bar, zone /
#       market-state menus, a timestep slider and a PNG/PDF/SVG export of the
#       current view. Bars 1/3/4 stack merged categories whose conv/RES/storage
#       split comes from the run's MatchingConfig.res_tags.
#
# Private helpers are prefixed `_refday_`/`_shift_` to keep them apart from
# plotting_functions.jl, whose `_hex_color`, `_zone_load_series`,
# `_line_endpoints_from_results`, `_clear_legends!` and `_auto_map_extent` are
# reused here.
#
# Both plots keep their scene children fixed and drive them through Observables:
# the geometry (line segments, node markers, bar series) is built once and a
# slider tick only rewrites preallocated value buffers. Lookups go into a dense
# `key × time` matrix (`_ZoneKeyTable`) rather than the nested
# `Dict{String,Dict{Int,Dict{String,Float64}}}` these aggregations used to build.
# =============================================================================

# Stacking/legend order of the real nodal shift components ("np_relax" is a
# per-zone residual, not a nodal delta — it is reported separately).
const _SHIFT_COMPONENTS = ["RES_prestep", "load_prestep", "RES", "conv", "load", "sto",
                           "balance"]

# One colour per shift component. The dispatch plot reuses these for its merged stack
# categories too (`_RD_CAT_COLORS`), so a component and the category it folds into share a
# hue across bars. Parsed once, so the colour vectors handed to Makie are `Vector{RGBAf}`
# rather than `Vector{Any}` of hex strings. Shift segments additionally carry a black
# stroke to mark them as synthetic deltas — Makie has no hatching.
const REFDAY_SHIFT_COLORS = Dict{String,RGBAf}(
    "RES_prestep"  => _hex_color("#AAB5C3"),
    "load_prestep" => _hex_color("#DA9747"),
    "RES"          => _hex_color("#BF5B69"),
    "conv"         => _hex_color("#7A62A3"),
    "load"         => _hex_color("#268675"),
    "sto"          => _hex_color("#2F78AF"),
    "balance"      => _hex_color("#A66B52"),
    "np_relax"     => _hex_color("#c85a89"),
)

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
resolved to indices once and a lookup is a single matrix index.
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

"Value of one (zone, key, time index) cell."
function _zk_value(tbl::_ZoneKeyTable, zone, key, j)
    j == 0 && return 0.0
    M = get(tbl.data, zone, nothing)
    ki = get(tbl.keypos, key, 0)
    (M === nothing || ki == 0) && return 0.0
    return @inbounds M[ki, j]
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
    if !(gsk isa Union{Nothing,AbstractString})
        # An explicitly passed instance wins over a roster entry of the same type name.
        # Two `CustomWeightsGSK`s differ only in their weights, and silently plotting the
        # one from `gsk_options` instead of the one the caller named would be invisible.
        gsk_by_name[default_gsk] = gsk
        default_gsk in gsk_names || (push!(gsk_names, default_gsk); sort!(gsk_names))
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
# Plot 2 — reference day, shift decomposition, shifted reference day, market result
# =============================================================================

# Merged stack categories of the dispatch plot. Every category value is the quantity's
# NET POSITION contribution (export-positive): generation and storage discharge enter
# positive, load and storage charging negative. That is what makes bar 3 a plain
# per-category addition of bars 1 and 2 — a REFDAY_SHIFT delta is an export-positive
# injection change, so a positive `load` delta (a load DECREASE) adds to the very
# category that carries `−load`. It is also why the net-position marker of a bar is the
# algebraic sum of that bar's segments.
const _RD_CAT_CONV = "conventional"
const _RD_CAT_RES  = "RES"
const _RD_CAT_STO  = "storage"
const _RD_CAT_BAL  = "balance"
const _RD_CAT_LOAD = "load"

# Stacking/legend order. Load last so it anchors the bottom of the negative half.
const _RD_CATEGORIES = [_RD_CAT_CONV, _RD_CAT_RES, _RD_CAT_STO, _RD_CAT_BAL, _RD_CAT_LOAD]

const _RD_CAT_COLORS = Dict{String,RGBAf}(
    _RD_CAT_CONV => REFDAY_SHIFT_COLORS["conv"],
    _RD_CAT_RES  => REFDAY_SHIFT_COLORS["RES"],
    _RD_CAT_STO  => REFDAY_SHIFT_COLORS["sto"],
    _RD_CAT_BAL  => REFDAY_SHIFT_COLORS["balance"],
    _RD_CAT_LOAD => REFDAY_SHIFT_COLORS["load"],
)

# Which category a shift component folds into for bar 3. The pre-step levers keep their
# own colour in the decomposition bar but merge with their main lever here — a pre-step
# RES delta is a RES injection change like any other.
const _RD_SHIFT_TO_CAT = Dict{String,String}(
    "RES_prestep"  => _RD_CAT_RES,
    "RES"          => _RD_CAT_RES,
    "load_prestep" => _RD_CAT_LOAD,
    "load"         => _RD_CAT_LOAD,
    "conv"         => _RD_CAT_CONV,
    "sto"          => _RD_CAT_STO,
    "balance"      => _RD_CAT_BAL,
)

# Menu entry backed by the `variant` argument itself, always present so the two-argument
# call keeps working without a `results_dir`.
const _RD_STATE_SELF = "variant (as passed)"

const _RD_EXPORT_PNG = "png"

"`NaN` (an absent bar segment) read as zero for stacking and legend arithmetic."
_rd_finite(v) = isnan(v) ? 0.0 : v

"""
    _refday_plant_categories(params, res_tags) -> Dict{String,String}

Plant → merged stack category, classified by `POMATWO._classify_plant` — the same function
`refday_basecase.jl` uses to split the shift levers. Passing the run's own
`MatchingConfig.res_tags` therefore makes the plot's conventional/RES/storage split
identical to the one the reference-day basecase applied, by construction rather than by
convention.
"""
function _refday_plant_categories(params, res_tags)
    out = Dict{String,String}()
    for p in keys(params.plant2zone)
        cls = POMATWO._classify_plant(p, params, res_tags)
        out[p] = cls === :res ? _RD_CAT_RES : cls === :sto ? _RD_CAT_STO : _RD_CAT_CONV
    end
    return out
end

"""
    _refday_state_options(results_dir) -> Vector{String}

Canonical names of the market states that wrote a dispatch table under `results_dir`, read
off the stage-prefixed filenames (`DayAhead_GEN.arrow` → `DayAhead`). Empty for a missing
directory or a legacy, unprefixed result layout.

Both `GEN` and `REDISP` count: the redispatch stage writes **no** `GEN` table at all — its
dispatch is `GEN_REDISP` inside `Redispatch_REDISP.arrow` — so scanning for `_GEN.arrow`
alone would silently drop `Redispatch` from the menu.
"""
function _refday_state_options(results_dir)
    (results_dir isa AbstractString && !isempty(results_dir) && isdir(results_dir)) ||
        return String[]
    subruns = filter(x -> isdir(x) && occursin(r"subrun", x),
                     readdir(results_dir, join = true))
    seen = Set{String}()
    for folder in subruns, f in readdir(folder)
        (endswith(f, "_GEN.arrow") || endswith(f, "_REDISP.arrow")) || continue
        s = POMATWO._file_stage(f)
        s === nothing && continue
        # Only the states the reference-day machinery can actually read a dispatch from.
        try
            POMATWO._source_state(s)
        catch
            continue
        end
        push!(seen, s)
    end
    return sort!(collect(seen))
end

"""
    _refday_dispatch_tables(res, state_name) -> (gen, charge)

Generation and storage-charging frames of one market state, via the very accessors the
shift uses (`POMATWO._source_gen` / `_source_charge`). Going through them rather than
reading `res.GEN` / `res.CHARGE` is what makes `Redispatch` work: that stage writes no
`GEN` or `CHARGE` table, and its dispatch has to be read as `GEN_REDISP` / `CHARGE_REDISP`
out of `REDISP`. Both frames come back with the plain `GEN` / `CHARGE` column names.
"""
function _refday_dispatch_tables(res, state_name)
    st = POMATWO._source_state(state_name)
    return POMATWO._source_gen(st, res), POMATWO._source_charge(st, res)
end

"""
Loaded `CairoMakie` module, or `nothing`.

GLMakie cannot write PDF or SVG. Rather than adding a hard dependency, the export menu
offers the vector formats only when the user has `using CairoMakie` in their session, so
the extension's weakdep set is unchanged.
"""
function _cairo_backend()
    for (id, m) in Base.loaded_modules
        id.name == "CairoMakie" && return m
    end
    return nothing
end

"Export formats available right now: PNG always, PDF/SVG only with CairoMakie loaded."
_refday_export_formats() =
    _cairo_backend() === nothing ? [_RD_EXPORT_PNG] : [_RD_EXPORT_PNG, "pdf", "svg"]

"`path` with its extension forced to `fmt`."
function _refday_with_ext(path, fmt)
    base, ext = splitext(path)
    isempty(ext) && return string(path, ".", fmt)
    lowercase(ext) == string(".", fmt) && return path
    return string(base, ".", fmt)
end

"""
    _refday_snapshot_figure(bars, np, ticks, ylabel, caption, size) -> Figure

The plotted area alone — axis, legend and caption — with none of the interactive
furniture. The live figure carries its menus, textbox, button and slider inside the same
`Figure`, so saving it would put the whole GUI in the file; this rebuilds just the plot
from the values that figure currently holds.

`bars` is one `(heights, offsets, color, stroked, label)` tuple per series, already
resolved to plain vectors — the snapshot is static, so nothing here is an Observable.
"""
function _refday_snapshot_figure(bars, np, ticks, ylabel, caption, size)
    fig = Figure(size = size)
    ax = Axis(fig[1, 1]; ylabel = ylabel, xticks = ticks)
    xs = [1.0, 2.0, 3.0, 4.0]
    handles, labels = Any[], String[]
    for (h, o, color, stroked, label) in bars
        p = barplot!(ax, xs, copy(h);
                     offset = copy(o), width = 0.7, color = color,
                     strokecolor = stroked ? :black : :transparent,
                     strokewidth = stroked ? 1.0 : 0.0)
        any(v -> _rd_finite(v) != 0.0, h) || continue
        push!(handles, p)
        push!(labels, label)
    end
    npp = scatter!(ax, copy(np); marker = :circle, markersize = 16, color = :magenta,
                   strokecolor = :black, strokewidth = 1.0)
    push!(handles, npp)
    push!(labels, "Net position")
    Legend(fig[1, 2], handles, labels, "Legend", nbanks = 2)
    Label(fig[2, 1], caption; tellwidth = false, fontsize = 13)
    return fig
end

"""
    _refday_export(fig, path, fmt; px_per_unit)

Write `fig` to `path`. PNG goes through the active GLMakie screen; a vector format is
rendered by CairoMakie, preferring `save(...; backend = ...)` and falling back to a
backend switch on older Makie versions (GLMakie is reactivated either way).
"""
function _refday_export(fig, path, fmt; px_per_unit = 2)
    dir = dirname(path)
    isempty(dir) || isdir(dir) || mkpath(dir)
    if fmt == _RD_EXPORT_PNG
        save(path, fig; px_per_unit = px_per_unit)
        return path
    end
    cm = _cairo_backend()
    cm === nothing &&
        error("$(uppercase(fmt)) export needs CairoMakie — run `using CairoMakie` first.")
    try
        save(path, fig; backend = cm)
    catch
        cm.activate!()
        try
            save(path, fig)
        finally
            GLMakie.activate!(inline = false)
        end
    end
    return path
end

"""
    plot_refday_dispatch_interactive(variant, source; kwargs...)

Single-timestep comparison of one zone's dispatch across the reference-day pipeline, as
four stacked bars:

1. **`ref`** — the source (basecase) run's dispatch at the reference hour matched to the
   selected timestep. Pass `source` loaded with the same state the `ReferenceDayBasecase`
   used **and** the same `source_type` string — e.g. `DataFiles(dir, TwoDayAhead)` with
   `source_type = "2DA"`.
2. **`shift`** — the ShareShift decomposition at the selected timestep, one segment per
   REFDAY_SHIFT component (`RES_prestep`, `load_prestep`, `RES`, `conv`, `load`, `sto`,
   `balance`).
3. **`shifted ref`** — bar 1 plus bar 2, with the deltas merged into the bar's own
   categories.
4. **market result** — the dispatch of the market state selected in the `Market state`
   menu, at the same timestep.

# Sign convention
Every segment is an export-positive net-position contribution, so the bars read directly:
generation and storage discharge stack upward, load and storage charging downward, and a
shift delta lands on the axis matching its effect on the net position. REFDAY_SHIFT is
already in that convention — a positive `load` delta is a load *decrease* — so a load
decrease appears on the positive axis and a load increase on the negative one, exactly as
a generation increase and decrease do. The net-position diamond of a bar is therefore the
algebraic sum of its segments.

# Categories
Bars 1, 3 and 4 are stacked in `conventional` / `RES` / `storage` / `load` (plus
`balance`, which only the shift produces). Plants are assigned by
`POMATWO._classify_plant` using `matching.res_tags` — pass the run's own `MatchingConfig`
so the split is the one the reference-day basecase applied.

# Interactivity
Zone menu, market-state menu, a single-timestep slider, and a PNG/PDF/SVG export (PDF and
SVG appear in the format menu only when `CairoMakie` is loaded). The export writes the
plotted area only — axis, legend and caption — not the menus, textbox, button and slider,
which live in the same `Figure` and would otherwise land in the file.

# Reading a state's dispatch
Which table holds a state's dispatch differs by state, and the plot delegates that to the
shift's own accessors (`POMATWO._source_gen` / `_source_charge`). The day-ahead and
`TwoDayAhead` states write `GEN` and `CHARGE`; **the redispatch stage writes neither** —
its dispatch is `GEN_REDISP` / `CHARGE_REDISP` inside the `REDISP` table. Reading `.GEN`
directly would therefore show an empty bar for a redispatch source instead of failing.

# Keyword arguments
- `matching::MatchingConfig = MatchingConfig()`: the run's matching config; only
  `res_tags` is read.
- `source_type = ""`: which market state `source` was loaded for — the same string the
  `ReferenceDayBasecase` was given (`""`/`"DA"`, `"2DA"`, `"REDISP"`, or a canonical state
  name). It decides which columns bar 1 is read from; a mismatch raises instead of drawing
  an empty bar.
- `results_dir = ""`: results directory whose market states fill the state menu. Without
  it the menu holds the passed `variant` alone.
- `scalefactor = 1/1000`: MW → GW.
- `figsize = (1300, 850)`, `px_per_unit = 2` (PNG export resolution),
  `export_path = "refday_dispatch.png"` (prefilled export path),
  `export_figsize = (1000, 650)` (size of the exported plot, which carries no controls).
"""
function POMATWO.plot_refday_dispatch_interactive(
    variant, source;
    matching    = POMATWO.MatchingConfig(),
    source_type = "",
    results_dir = "",
    scalefactor = 1 / 1000,
    figsize     = (1300, 850),
    px_per_unit = 2,
    export_path = "refday_dispatch.png",
    export_figsize = (1000, 650),
)
    params = variant.params

    refmap, fbmap = _refday_zone_ref_times(variant)
    target_times = sort(unique(Int.(variant.GEN.Time)))
    ref_times = Set{Int}()
    for d in values(refmap), r in values(d)
        push!(ref_times, r)
    end

    # One shared time axis for every table, so a lookup is a single index map.
    times = sort!(collect(union(ref_times, Set(target_times))))
    timepos = Dict{Int,Int}(t => i for (i, t) in enumerate(times))
    zones = sort(collect(keys(refmap)))
    isempty(zones) && error("No zones with reference-day matches found.")

    p2z = params.plant2zone
    cat_of = _refday_plant_categories(params, matching.res_tags)

    # Dispatch of one market state as a (gen, charge) pair of category tables. Which
    # columns that state actually stores is `_refday_dispatch_tables`' business.
    function stage_tables(res, state_name)
        gen_df, chg_df = _refday_dispatch_tables(res, state_name)
        gen = _build_zone_key_table(zones, timepos) do f
            _emit_plant_column(f, gen_df, :GEN, p2z, cat_of, nothing)
        end
        chg = _build_zone_key_table(zones, timepos) do f
            _emit_plant_column(f, chg_df, :CHARGE, p2z, cat_of, _CHARGE_KEY)
        end
        return (gen = gen, chg = chg)
    end

    src_gen_df, _ = _refday_dispatch_tables(source, source_type)
    isempty(src_gen_df) && error(
        "plot_refday_dispatch_interactive: the `source` results carry no dispatch for " *
        "market state \"$(isempty(source_type) ? "DayAhead" : source_type)\". Pass the " *
        "`source_type` the ReferenceDayBasecase used, together with a `source` loaded " *
        "for that state — e.g. source_type = \"REDISP\" with DataFiles(dir, Redispatch).")
    src = stage_tables(source, source_type)
    src_tbl, src_chg = src.gen, src.chg
    shift_tbl = _build_zone_key_table(zones, timepos) do f
        _emit_shift_rows(f, variant.REFDAY_SHIFT, params.node2zone)
    end

    # Market states of bar 4. The passed `variant` is always available; anything found in
    # `results_dir` is loaded on first selection and kept.
    state_options = String[_RD_STATE_SELF; _refday_state_options(results_dir)]
    state_cache = Dict{String,Any}(_RD_STATE_SELF => stage_tables(variant, ""))
    function state_tables(name)
        haskey(state_cache, name) && return state_cache[name]
        res = DataFiles(results_dir, POMATWO.market_state_type(name))
        tbls = stage_tables(res, name)
        state_cache[name] = tbls
        return tbls
    end

    zone_load = _zone_load_series(params, times)
    for z in zones   # a REFDAY_MATCH group need not be in params.sets.Z
        haskey(zone_load, z) || (zone_load[z] = zeros(Float64, length(times)))
    end

    shift_comps = [c for c in _SHIFT_COMPONENTS if haskey(shift_tbl.keypos, c)]

    # Fixed series set: the merged categories (bars 1/3/4) followed by the shift
    # components (bar 2 only), so every bar object is created once and a redraw only
    # rewrites preallocated value buffers.
    series_kind = Symbol[fill(:cat, length(_RD_CATEGORIES));
                         fill(:shift, length(shift_comps))]
    series_key = String[_RD_CATEGORIES; shift_comps]
    series_labels = String[_RD_CATEGORIES; ["Δ$(c)" for c in shift_comps]]
    nseries = length(series_key)

    GLMakie.activate!(inline = false)
    fig = Figure(size = figsize)
    ax = Axis(fig[1:4, 1]; ylabel = "GW", title = "")

    zone_menu = Menu(fig, options = zones, fontsize = 20)
    state_menu = Menu(fig, options = state_options, default = first(state_options),
                      fontsize = 20)
    fmt_menu = Menu(fig, options = _refday_export_formats(), default = _RD_EXPORT_PNG,
                    fontsize = 20)
    path_box = Textbox(fig, width = 280, placeholder = "output path",
                       stored_string = export_path, displayed_string = export_path)
    export_btn = Button(fig, label = "Export view", fontsize = 18)
    # Two rows for the control column and one for the legend: the seven widgets overflow
    # a single row and the topmost one is clipped by the figure edge.
    fig[1:2, 2] = vgrid!(Label(fig, "Market Zone", fontsize = 20, width = 300), zone_menu,
                         Label(fig, "Market state", fontsize = 20), state_menu,
                         Label(fig, "Export format", fontsize = 20), fmt_menu,
                         path_box, export_btn; tellheight = false)

    sgrid = SliderGrid(fig[5, 1],
                       (label = "Timestep", range = target_times,
                        startvalue = first(target_times)))
    tslider = sgrid.sliders[1]
    info = Label(fig[6, 1], ""; tellwidth = false, fontsize = 13)
    status = Label(fig[7, 1], ""; tellwidth = false, fontsize = 12, color = :gray30)

    # A shift series is absent from three of the four bars, and a stroked zero-height
    # segment renders as a black line across whatever it sits on top of. `strokewidth` has
    # to stay scalar (GLMakie draws the outlines as one polyline set), so an absent segment
    # is `NaN` instead of `0.0` and is not drawn at all. `_rd_finite` is what keeps the
    # stacking arithmetic and the legend from tripping over those.
    heights = [Observable(zeros(Float64, 4)) for _ = 1:nseries]
    offsets = [Observable(zeros(Float64, 4)) for _ = 1:nseries]
    bar_handles = Any[]
    series_colors = RGBAf[]
    xs = [1.0, 2.0, 3.0, 4.0]
    for s = 1:nseries
        is_shift = series_kind[s] === :shift
        color = is_shift ? REFDAY_SHIFT_COLORS[series_key[s]] : _RD_CAT_COLORS[series_key[s]]
        push!(series_colors, color)
        push!(bar_handles, barplot!(
            ax, xs, heights[s];
            offset = offsets[s], width = 0.7, color = color,
            strokecolor = is_shift ? :black : :transparent,
            strokewidth = is_shift ? 1.0 : 0.0))
    end

    np_pts = Observable(fill(Point2f(0, 0), 4))
    npplot = scatter!(ax, np_pts; marker = :circle, markersize = 16, color = :magenta,
                      strokecolor = :black, strokewidth = 1.0)

    function redraw!()
        zone = zone_menu.selection[]
        t = Int(tslider.value[])
        jw = get(timepos, t, 0)
        r = get(get(refmap, zone, Dict{Int,Int}()), t, 0)
        jr = r == 0 ? 0 : get(timepos, r, 0)
        # No match for this (zone, hour): bars 1–3 are empty, and so are the shift rows.
        jm = r == 0 ? 0 : jw
        fb = get(get(fbmap, zone, Dict{Int,Bool}()), t, false)
        tbl = state_tables(state_menu.selection[])

        zl = zone_load[zone]
        load_at(j) = j == 0 ? 0.0 : @inbounds zl[j]

        # Net-position contribution of one category at one time index.
        function cat_value(gen, chg, cat, j)
            cat == _RD_CAT_LOAD && return -load_at(j) * scalefactor
            cat == _RD_CAT_BAL && return 0.0
            v = _zk_value(gen, zone, cat, j)
            cat == _RD_CAT_STO && (v -= _zk_value(chg, zone, _CHARGE_KEY, j))
            return v * scalefactor
        end
        shift_value(c) = _zk_value(shift_tbl, zone, c, jm) * scalefactor

        cat_delta = Dict{String,Float64}(c => 0.0 for c in _RD_CATEGORIES)
        for c in shift_comps
            cat_delta[_RD_SHIFT_TO_CAT[c]] += shift_value(c)
        end

        for s = 1:nseries
            h = heights[s][]
            if series_kind[s] === :cat
                cat = series_key[s]
                b1 = cat_value(src_tbl, src_chg, cat, jr)
                h[1] = b1
                h[2] = 0.0
                h[3] = b1 + cat_delta[cat]
                h[4] = cat_value(tbl.gen, tbl.chg, cat, jw)
            else
                v = shift_value(series_key[s])
                h[1] = NaN
                h[2] = v == 0.0 ? NaN : v
                h[3] = NaN
                h[4] = NaN
            end
        end

        # stacking offsets: positives up from 0, negatives down from 0, in series order.
        # The running total of a bar is its net position, so the marker needs no separate
        # reduction over the tables.
        nps = zeros(Float64, 4)
        for x = 1:4
            pos, neg = 0.0, 0.0
            for s = 1:nseries
                v = _rd_finite(heights[s][][x])
                o = offsets[s][]
                if v >= 0
                    o[x] = pos
                    pos += v
                else
                    o[x] = neg
                    neg += v
                end
            end
            nps[x] = pos + neg
        end
        foreach(notify, heights)
        foreach(notify, offsets)
        np_pts[] = Point2f[Point2f(x, nps[x]) for x = 1:4]

        state_label = state_menu.selection[] == _RD_STATE_SELF ? "market result" :
                      state_menu.selection[]
        ax.xticks = ([1, 2, 3, 4],
                     [r == 0 ? "ref (no match)" : "ref (t=$r)", "shift",
                      "shifted ref", state_label])

        # legend: only the series that carry something in this timestep
        handles, labels = Any[], String[]
        for s = 1:nseries
            any(x -> _rd_finite(heights[s][][x]) != 0.0, 1:4) || continue
            push!(handles, bar_handles[s])
            push!(labels, series_labels[s])
        end
        push!(handles, npplot)
        push!(labels, "Net position")

        unabs = _zk_value(shift_tbl, zone, "np_relax", jm) * scalefactor
        rnd(x) = round(x, digits = 2)
        info.text = "zone $zone | t = $t | " *
                    (r == 0 ? "no reference match" :
                     "reference hour $r$(fb ? " (fallback match)" : "")") *
                    " | np_relax = $(round(unabs, digits = 3)) GW | " *
                    "NP [ref/shift/shifted/market] = $(rnd(nps[1])) / $(rnd(nps[2])) / " *
                    "$(rnd(nps[3])) / $(rnd(nps[4])) GW"
        autolimits!(ax)
        _clear_legends!(fig)
        Legend(fig[3:4, 2], handles, labels, "Legend", nbanks = 2)
        return nothing
    end

    on(export_btn.clicks) do _
        fmt = fmt_menu.selection[]
        raw = path_box.stored_string[]
        p = _refday_with_ext(raw === nothing || isempty(raw) ? export_path : raw, fmt)
        try
            bars = [(heights[s][], offsets[s][], series_colors[s],
                     series_kind[s] === :shift, series_labels[s]) for s = 1:nseries]
            snap = _refday_snapshot_figure(bars, np_pts[], ax.xticks[], ax.ylabel[],
                                           info.text[], export_figsize)
            _refday_export(snap, p, fmt; px_per_unit = px_per_unit)
            status.text = "saved $(abspath(p))"
        catch err
            status.text = "export failed: $(sprint(showerror, err))"
        end
        return nothing
    end

    redraw!()
    on(_ -> redraw!(), zone_menu.selection)
    on(_ -> redraw!(), state_menu.selection)
    on(_ -> redraw!(), tslider.value)

    return fig
end
