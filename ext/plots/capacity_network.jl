# Static network + installed-capacity map, built purely from the input CSVs.
#
# Every other map in this extension needs a solved run: `create_lineplot` and
# `plot_line_utils_interactive` colour lines by utilization from the `*_LINEFLOW` tables,
# `plot_shift_map_interactive` needs reference-day traces. This one reads nothing but the
# input files, so a dataset can be inspected before it is ever handed to a solver.

# Colours for plant types that `planttypes.csv` gives none. `_color_for`'s single gray is
# right for one missing series but useless for a whole stack, which would come out as one
# solid gray block with an unreadable legend.
const _CAP_FALLBACK_PALETTE = RGBAf[RGBAf(c) for c in ColorSchemes.tab20.colors]

const _CAP_LABEL_COLOR = RGBAf(0.15, 0.15, 0.15, 1.0)

# Pixel distance a line label is pushed off its own line.
const _CAP_LINE_LABEL_PAD = 6.0f0

# Overlap between consecutive segments of a node's stack, as a fraction of the tallest bar.
const _CAP_STACK_OVERLAP = 0.004

"Capacity for the legend key: whole MW without a trailing `.0`, anything else via `_fmt_val`."
_cap_fmt(x) = isinteger(x) ? string(Int(x)) : _fmt_val(x)

"""
    _label_offset(from, to, pad) -> Vec2f

Pixel offset that pushes a line's label clear of the line, perpendicular to it and always
towards positive y.

A fixed vertical offset works for a horizontal line and puts the label straight on top of a
vertical one. Both layouts this plot uses have an equal-aspect axis — `DataAspect()` for the
circular fallback, web mercator for the map — so a normal computed in data space is still a
normal in pixel space.
"""
function _label_offset(from, to, pad)
    dx, dy = Float32(to[1] - from[1]), Float32(to[2] - from[2])
    n = hypot(dx, dy)
    n > 0 || return Vec2f(0, pad)
    ox, oy = -dy / n, dx / n
    return oy < 0 ? Vec2f(-pad * ox, -pad * oy) : Vec2f(pad * ox, pad * oy)
end

"""
    _node_positions_from_csv(path) -> (node_xy, node_coords, geographic)

Plotting positions for every node in the node input file.

`node_xy[n]` is a `Point2f` in the axis' data space. When the file carries usable `lon`/`lat`
that space is web mercator and `geographic` is `true`, with `node_coords` the raw WGS84
pairs that `_auto_map_extent` and `Tyler.Map` need. When it does not — the columns are
absent, or every node sits on the `(0.0, 0.0)` sentinel `_load_node_coords!` writes for a
node without coordinates — the nodes are laid out on a unit circle instead, `geographic` is
`false` and `node_coords` is `nothing`.

The fallback branch deliberately does not go through [`_read_node_coords`](@ref): that
helper `error`s on a missing column by design, which is the right behaviour for the
result-driven maps but would make this plot unusable on a coordinate-free network.
"""
function _node_positions_from_csv(path)
    header = String.(propertynames(CSV.File(path; limit = 0)))
    if "lon" in header && "lat" in header
        all_coords = _read_node_coords(path)
        # `[0.0, 0.0]` means "no coordinates", not the Gulf of Guinea — a single sentinel
        # left in would stretch the map extent across half the Atlantic.
        node_coords = Dict{String,Tuple{Float64,Float64}}(
            n => c for (n, c) in all_coords if !(c[1] == 0.0 && c[2] == 0.0))
        if !isempty(node_coords)
            node_xy = Dict{String,Point2f}(
                n => project_point2f(c[1], c[2]) for (n, c) in node_coords)
            return node_xy, node_coords, true
        end
    end

    ids = sort!(String.(CSV.read(path, DataFrame; select = [:index]).index))
    isempty(ids) && error("Node file $(path) contains no nodes.")
    return _circular_node_positions(ids), nothing, false
end

"""
    _csv_line_capacities(path) -> Dict{String,Float64}

`index => capacity` of a line input file. A file without a `capacity` column yields an empty
dict, which the width scaling reads as "unknown" and draws hairline.
"""
function _csv_line_capacities(path)
    header = String.(propertynames(CSV.File(path; limit = 0)))
    caps = Dict{String,Float64}()
    ("index" in header && "capacity" in header) || return caps
    df = CSV.read(path, DataFrame; select = [:index, :capacity])
    idx, cap = df.index, df.capacity
    @inbounds for k in eachindex(idx, cap)
        (ismissing(idx[k]) || ismissing(cap[k])) && continue
        caps[String(idx[k])] = Float64(cap[k])
    end
    return caps
end

"`path` is usable as a line/DC input file for this plot."
_cap_has_file(data, key) = haskey(data, key) && isfile(data[key])

"""
    _installed_capacity_by_node(path, node_xy) -> (cap, types)

`cap[node][plant_type]` summed installed `g_max`, and the sorted plant types that actually
carry capacity. Plants at a node with no plotting position are dropped.

`g_max` only: a storage plant whose discharge power lives solely in `storage_power`
contributes nothing here.
"""
function _installed_capacity_by_node(path, node_xy)
    df = CSV.read(path, DataFrame; select = [:index, :plant_type, :node, :g_max])
    cap = Dict{String,Dict{String,Float64}}()
    types = Set{String}()
    pt, nd, gm = df.plant_type, df.node, df.g_max
    @inbounds for k in eachindex(pt, nd, gm)
        (ismissing(pt[k]) || ismissing(nd[k]) || ismissing(gm[k])) && continue
        g = Float64(gm[k])
        g > 0 || continue
        n = String(nd[k])
        haskey(node_xy, n) || continue
        t = String(pt[k])
        push!(types, t)
        d = get!(() -> Dict{String,Float64}(), cap, n)
        d[t] = get(d, t, 0.0) + g
    end
    return cap, sort!(collect(types))
end

"""
    _type_colors_from_csv(path, types) -> Dict{String,RGBAf}

Plant-type colours from the `color` column of the plant-type input file, parsed by
[`_parse_color_table`](@ref). Types with no entry get one from
[`_CAP_FALLBACK_PALETTE`](@ref) by position in `types`, so a file without a `color` column
still produces a distinguishable stack rather than a gray block.
"""
function _type_colors_from_csv(path, types)
    header = String.(propertynames(CSV.File(path; limit = 0)))
    parsed = if "index" in header && "color" in header
        df = CSV.read(path, DataFrame; select = [:index, :color])
        raw = Dict{String,String}()
        idx, col = df.index, df.color
        @inbounds for k in eachindex(idx, col)
            (ismissing(idx[k]) || ismissing(col[k])) && continue
            raw[String(idx[k])] = String(col[k])
        end
        _parse_color_table(raw)
    else
        Dict{String,RGBAf}()
    end

    out = Dict{String,RGBAf}()
    for (k, t) in enumerate(types)
        out[t] = get(parsed, t,
            _CAP_FALLBACK_PALETTE[mod1(k, length(_CAP_FALLBACK_PALETTE))])
    end
    return out
end

"""
    plot_capacity_network(data::Dict{Symbol,String}; kwargs...)

Static map of the transmission network and the installed generation capacity at each node,
built **purely from the input CSVs** — no simulation results are read, so a dataset can be
checked before it is solved.

Line width carries line capacity, DC lines are dashed, and each node carries a stacked bar
of its installed capacity per plant type with the node index labelled underneath.

# Arguments
- `data`: dictionary of input file paths (see section [Input Data Load](@ref)). `:nodes`,
  `:plants` and `:types` are required; `:lines` and `:dclines` are optional and each is
  skipped when the key is absent, the file does not exist, or it holds only a header.

# Keyword arguments
- `background_map`: (default `true`) draw Tyler/CartoDB raster tiles behind the network.
  Ignored when the node file carries no coordinates — the circular fallback layout is not
  geographic and gets no basemap.
- `extent`: (default `nothing`) map window as a `Tyler.Extents.Extent`. `nothing` fits it to
  the node coordinates.
- `figsize`: (default `(1000, 1100)`) figure size in pixels.
- `exclude_dc_lines`: (default `false`) if `true`, DC lines are not drawn.
- `linewidth_range`: (default `(0.6, 4.5)`) width in points of the smallest and the largest
  line capacity.
- `bar_height_frac`: (default `0.12`) height of the tallest node bar as a fraction of the
  node bounding box.
- `bar_width_frac`: (default `0.02`) bar width as a fraction of the node bounding box.
- `show_node_labels`: (default `true`) print the node index below each node.
- `show_line_labels`: (default `true`) print the line index at each line's midpoint.
- `label_fontsize`: (default `10`) font size of both label sets, in points.

# Plot Details
- Line width is proportional to the `capacity` column with a floor, so a line of unknown or
  zero capacity is hairline rather than invisible. AC and DC share one scale: equal
  capacities are drawn equally thick regardless of line type.
- Bar height uses one scale across all nodes, so bars are comparable between nodes. Only
  `g_max` is counted — a storage plant carrying its power in `storage_power` alone
  contributes nothing.
- Plant types are stacked in alphabetical order, identically at every node. Colours come
  from the `color` column of the plant-type file; types without one fall back to a
  distinguishable palette colour.
- A node with no plants keeps its dot and its label and grows no bar.
- When the node file has no `lon`/`lat` columns (or every node sits on the `0, 0` sentinel),
  nodes are laid out on a circle instead and the basemap is suppressed. Topology, line
  widths, bars and labels all still read correctly; only the geography is gone.
- The axis title states the absolute magnitude of the tallest bar and the widest line,
  without which neither encoding is readable in absolute terms.

# Returns
- `fig`: a Makie `Figure`.

# Example
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
"""
function POMATWO.plot_capacity_network(
    data::Dict{Symbol,String};
    background_map::Bool = true,
    extent = nothing,
    figsize = (1000, 1100),
    exclude_dc_lines::Bool = false,
    linewidth_range = (0.6, 4.5),
    bar_height_frac = 0.12,
    bar_width_frac = 0.02,
    show_node_labels::Bool = true,
    show_line_labels::Bool = true,
    label_fontsize = 10,
)
    for key in (:nodes, :plants, :types)
        haskey(data, key) || error("`data` is missing the required key :$(key).")
    end

    node_xy, node_coords, geographic = _node_positions_from_csv(data[:nodes])
    nodes = sort!(collect(keys(node_xy)))
    node_points = [node_xy[n] for n in nodes]

    # --- geometry and capacity of every line, per style --------------------------
    # `linestyle` is a per-plot attribute — it cannot be varied per segment the way colour
    # and width can — so AC and DC are collected separately and drawn as two plots.
    line_groups = Tuple{Symbol,Vector{String},Dict{String,_Segment}}[]
    line_caps = Dict{String,Float64}()
    for (key, style) in ((:lines, :solid), (:dclines, :dash))
        key === :dclines && exclude_dc_lines && continue
        _cap_has_file(data, key) || continue
        segs = Dict{String,_Segment}()
        _collect_csv_endpoints!(segs, data[key], node_xy)
        isempty(segs) && continue
        merge!(line_caps, _csv_line_capacities(data[key]))
        push!(line_groups, (style, sort!(collect(keys(segs))), segs))
    end

    # One capacity scale over AC and DC together.
    capmax = 0.0
    for (_, ids, _) in line_groups, l in ids
        capmax = max(capmax, get(line_caps, l, 0.0))
    end
    wlo, whi = Float32(first(linewidth_range)), Float32(last(linewidth_range))
    # Proportional to capacity with a floor, so an unknown or zero capacity draws hairline
    # rather than invisible. Same shape as the width scaling in `plot_line_utils_interactive`.
    _width(l) = capmax <= 0 ? wlo :
                clamp(wlo + (whi - wlo) * Float32(get(line_caps, l, 0.0) / capmax), wlo, whi)

    # --- layout ------------------------------------------------------------------
    use_basemap = background_map && geographic
    if geographic && extent === nothing
        extent = _auto_map_extent(node_coords)
    end
    fig, ax = use_basemap ?
        create_lineplot_layout(figsize; background_map = true, extent = extent) :
        create_lineplot_layout(figsize; background_map = false)

    # --- lines -------------------------------------------------------------------
    label_pos = Point2f[]
    label_txt = String[]
    label_off = Vec2f[]
    for (style, ids, segs) in line_groups
        pts = Vector{Point2f}(undef, 2 * length(ids))
        # `linesegments!` wants one width per POINT, hence each line's width twice.
        widths = Vector{Float32}(undef, 2 * length(ids))
        for (k, l) in enumerate(ids)
            from, to = segs[l]
            pts[2k-1] = from
            pts[2k] = to
            w = _width(l)
            widths[2k-1] = w
            widths[2k] = w
            push!(label_pos, Point2f(0.5f0 * (from[1] + to[1]), 0.5f0 * (from[2] + to[2])))
            push!(label_txt, l)
            push!(label_off, _label_offset(from, to, _CAP_LINE_LABEL_PAD))
        end
        linesegments!(ax, pts;
            color = (:black, 0.85), linewidth = widths, linestyle = style)
    end

    if show_line_labels && !isempty(label_pos)
        # Pixel `offset`, so the label clears the line at every zoom level.
        text!(ax, label_pos; text = label_txt, align = (:center, :center),
            offset = label_off, fontsize = label_fontsize, color = _CAP_LABEL_COLOR)
    end

    # --- installed capacity bars -------------------------------------------------
    cap, types = _installed_capacity_by_node(data[:plants], node_xy)
    type_colors = _type_colors_from_csv(data[:types], types)

    node_total = Dict{String,Float64}(n => sum(values(d)) for (n, d) in cap)
    maxcap = isempty(node_total) ? 0.0 : maximum(values(node_total))

    span = _node_span(node_points)
    bar_w = Float32(bar_width_frac * span)
    hscale = maxcap > 0 ? bar_height_frac * span / maxcap : 0.0

    bar_handles = Any[]
    bar_labels = String[]
    if hscale > 0
        # Running stack height per node, in data units. One `barplot!` per plant type over
        # every node that has it — not one per node — so the figure holds a handful of plot
        # objects regardless of how many nodes the network has.
        # Each segment above the first is extended DOWNWARD by this much so consecutive
        # segments overlap instead of merely touching. Two quads sharing an edge leave an
        # antialiasing seam that reads as a gap in the stack; the overlap covers it. Only
        # the lower edge moves, so every segment's top — and therefore the total height —
        # stays exactly proportional to capacity.
        seam = _CAP_STACK_OVERLAP * bar_height_frac * span
        stacked = Dict{String,Float64}(n => 0.0 for n in nodes)
        for t in types
            xs = Float32[]
            hs = Float32[]
            offs = Float32[]
            for n in nodes
                d = get(cap, n, nothing)
                d === nothing && continue
                g = get(d, t, 0.0)
                g > 0 || continue
                p = node_xy[n]
                # Bars are based at the node point and grow upward, so the node dot is the
                # foot of its own stack and the label below the dot is below the bar.
                base = stacked[n]
                over = base > 0 ? seam : 0.0
                push!(xs, p[1])
                push!(hs, Float32(g * hscale + over))
                push!(offs, Float32(p[2] + base - over))
                stacked[n] = base + g * hscale
            end
            isempty(xs) && continue
            h = barplot!(ax, xs, hs;
                offset = offs, width = bar_w, color = type_colors[t])
            push!(bar_handles, h)
            push!(bar_labels, t)
        end
    end

    scatter!(ax, node_points; color = :black, markersize = 5)

    if show_node_labels
        text!(ax, node_points; text = nodes, align = (:center, :top),
            offset = (0, -6), fontsize = label_fontsize, color = _CAP_LABEL_COLOR)
    end

    # --- legend ------------------------------------------------------------------
    # Two titled sections in one legend block: the bar colours say what the capacity is made
    # of, the line styles say what the topology is made of. They are not the same key.
    line_handles = Any[]
    line_labels = String[]
    for (style, ids, _) in line_groups
        isempty(ids) && continue
        push!(line_handles, LineElement(color = :black, linestyle = style, linewidth = 2))
        push!(line_labels, style === :dash ? "DC line" : "AC line")
    end
    groups = Vector{Any}[]
    group_labels = Vector{String}[]
    titles = String[]
    isempty(bar_handles) || (push!(groups, bar_handles);
        push!(group_labels, bar_labels); push!(titles, "installed capacity"))
    isempty(line_handles) || (push!(groups, line_handles);
        push!(group_labels, line_labels); push!(titles, "network"))
    isempty(groups) || Legend(fig[1, 2], groups, group_labels, titles)

    # Bar height and line width are both relative encodings; without their absolute
    # reference neither is readable. This sits in the axis title rather than next to the
    # legend because a `Label` in the legend's grid cell gets pushed to the bottom of the
    # figure by the row sizing, far away from the thing it explains.
    key = String[]
    maxcap > 0 && push!(key, "tallest bar = $(_cap_fmt(maxcap)) MW")
    capmax > 0 && push!(key, "widest line = $(_cap_fmt(capmax)) MW")
    isempty(key) || (ax.title = join(key, "   ·   "))

    geographic || (ax.xlabel = _NO_COORDS_NOTE)

    return fig
end
