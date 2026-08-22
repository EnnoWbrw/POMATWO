# Publication styling for the geographic map axes.
#
# Every map in this extension is drawn in Web Mercator (EPSG:3857) because that is the only
# projection Tyler's raster tiles exist in, and nothing in here changes that: geometry,
# flows and tile lookup all stay in mercator metres. What this file adds is the presentation
# layer a bare `Axis` cannot provide — degree ticks, a scale bar, a north arrow and an optional
# projection statement — so that a figure lifted straight out of a REPL session is
# readable in a paper instead of showing its x axis as `6.0×10⁵` metres east of Greenwich.
#
# Everything here is reactive on `ax.finallimits`. The interactive maps
# (`plot_line_utils_interactive`, `plot_shift_map_interactive`) zoom and pan, so a static
# `(positions, labels)` tuple or a scale bar drawn once at build time would be silently
# wrong the moment the user scrolls.

"Latitude beyond which Web Mercator diverges; the value the tile grid is cut at."
const _MERC_LAT_LIMIT = 85.05112878

"Projection statement for `ax.subtitle`. Opt-in (`projection_note = true`): the CRS belongs
in the figure caption for most readers, and the subtitle is wanted for scenario text."
const _MAP_PROJECTION_NOTE = "WGS 84 / Pseudo-Mercator (EPSG:3857)"

"""
    _unproject(x, y) -> (lon, lat)

Web Mercator metres → WGS84 degrees, the exact inverse of `project` in
`plotting_functions.jl` and written the same way (`MapTiles.project` with the two CRS
arguments swapped) so the pair cannot drift apart.

Used only for presentation: tick labels, the scale bar's latitude correction and the
projection note. No geometry is ever carried back into WGS84 — the plots themselves stay in
mercator metres, which is the only space the raster tiles exist in.
"""
_unproject(x, y) = MapTiles.project((x, y), MapTiles.web_mercator, MapTiles.wgs84)

"Degree value of a mercator coordinate on one axis (`:x` → longitude, `:y` → latitude)."
_deg_from_merc(axis::Symbol, v::Real) =
    axis === :x ? _unproject(Float64(v), 0.0)[1] : _unproject(0.0, Float64(v))[2]

"Mercator coordinate of a degree value on one axis. The latitude clamp keeps the poles finite."
function _merc_from_deg(axis::Symbol, d::Real)
    if axis === :x
        return MapTiles.project((Float64(d), 0.0), MapTiles.wgs84, MapTiles.web_mercator)[1]
    end
    lat = clamp(Float64(d), -_MERC_LAT_LIMIT, _MERC_LAT_LIMIT)
    return MapTiles.project((0.0, lat), MapTiles.wgs84, MapTiles.web_mercator)[2]
end

"""
    _fixed(v, dec) -> String

`v` rounded to `dec` decimals, always printing exactly `dec` of them.

`string(round(v, digits = 2))` would render 52.5 as `"52.5"` and 52.25 as `"52.25"` in the
same tick row; a map axis whose labels carry a ragged number of decimals reads as an
accident. Hand-rolled because `Printf` is not a dependency of POMATWO and the plotting
extension must not add one.
"""
function _fixed(v::Real, dec::Int)
    dec <= 0 && return string(round(Int, v))
    scale = round(Int, 10.0^dec)
    n = round(Int, Float64(v) * scale)
    i, f = divrem(n, scale)
    return string(i, ".", lpad(string(f), dec, '0'))
end

"""
    _degree_decimals(degs, span) -> Int

Number of decimals a tick row of `degs` needs: none while the ticks sit a whole degree or
more apart, otherwise just enough to tell neighbouring ticks apart (capped at four).

Driven by the tick SPACING rather than by the values, so every label in one row shares a
format even when some of them happen to land on a whole degree.
"""
function _degree_decimals(degs, span)
    step = length(degs) >= 2 ? minimum(abs, diff(sort(degs))) : Float64(span)
    step > 0 || return 0
    return clamp(ceil(Int, -log10(step) - 1.0e-9), 0, 4)
end

"""
    _format_degree(d, axis, dec) -> String

A degree value as `10°E` / `5.5°W` / `52°N` / `3°S`, and a bare `0°` on the equator and the
prime meridian where a hemisphere letter would be meaningless. `dec` comes from
[`_degree_decimals`](@ref); the zero test uses the same resolution, so a tick that ROUNDS to
zero is not labelled `0.0°W`.
"""
function _format_degree(d::Real, axis::Symbol, dec::Int)
    v = Float64(d)
    abs(v) < 0.5 * 10.0^(-dec) && return "0°"
    hemi = axis === :x ? (v > 0 ? "E" : "W") : (v > 0 ? "N" : "S")
    return string(_fixed(abs(v), dec), "°", hemi)
end

"""
    DegreeTicks(axis; n_ideal = 5)

Makie tick locator that labels a Web Mercator axis in degrees.

`axis` is `:x` (longitude) or `:y` (latitude). This is a tick OBJECT rather than a
precomputed `(positions, labels)` tuple on purpose: Makie re-runs `get_ticks` on every limit
change, so the ticks survive zooming and panning on the interactive maps. A static tuple
would keep showing the initial window's degrees over a completely different view.

The nice-number search happens in DEGREE space and the chosen values are projected back, so
the labels are round numbers (`52°N`) at slightly irregular pixel spacing — which is what a
mercator map should look like — rather than round metres carrying awkward degrees.
"""
struct DegreeTicks
    axis::Symbol
    n_ideal::Int
end
DegreeTicks(axis::Symbol; n_ideal::Int = 5) = DegreeTicks(axis, n_ideal)

# `get_ticks(ticks, scale, formatter, vmin, vmax) -> (tickvalues, ticklabels)` is the
# documented extension hook (Makie 0.24, `src/makielayout/lineaxis.jl`); overloading it
# rather than `get_tickvalues`/`get_ticklabels` separately is what lets one method own both
# the projection of the positions and the formatting of the labels. `formatter` is ignored
# deliberately — the labels are the whole point of this type.
function Makie.get_ticks(t::DegreeTicks, scale, formatter, vmin, vmax)
    lo = _deg_from_merc(t.axis, min(vmin, vmax))
    hi = _deg_from_merc(t.axis, max(vmin, vmax))
    (isfinite(lo) && isfinite(hi) && hi > lo) || return (Float64[], String[])

    degs = Makie.get_tickvalues(Makie.WilkinsonTicks(t.n_ideal, k_min = 3), lo, hi)
    isempty(degs) && (degs = Makie.get_tickvalues(Makie.LinearTicks(t.n_ideal), lo, hi))
    # Wilkinson may reach past the span. The axis would drop such a tick anyway, but
    # filtering here also keeps the spacing that decides the decimals honest.
    degs = Float64[Float64(d) for d in degs if lo - 1.0e-12 <= d <= hi + 1.0e-12]
    isempty(degs) && return (Float64[], String[])

    dec = _degree_decimals(degs, hi - lo)
    positions = Float64[_merc_from_deg(t.axis, d) for d in degs]
    labels = String[_format_degree(d, t.axis, dec) for d in degs]
    return positions, labels
end

"""
    _nice_length(x) -> Float64

`x` rounded to the nearest 1, 2 or 5 times a power of ten. A scale bar labelled `137 km` is
useless for reading distances off a figure; one labelled `100 km` is a ruler.
"""
function _nice_length(x::Real)
    x > 0 || return 1.0
    e = floor(log10(Float64(x)))
    m = Float64(x) / 10.0^e
    nice = m < 1.5 ? 1.0 : m < 3.5 ? 2.0 : m < 7.5 ? 5.0 : 10.0
    return nice * 10.0^e
end

"Bar length as a fraction of the current view width, before rounding to a nice number."
const _SCALEBAR_TARGET_FRAC = 0.25

"""
    _scalebar_geometry(lims, position, pad) -> NamedTuple

Bracket polyline, label anchor and label text for the scale bar at the current limits.

Two corrections that a naive implementation gets wrong, both silently:

1. **Mercator metres are not ground metres.** The projection inflates distances by
   `1 / cos(latitude)`, so a bar 100 km long in axis units covers only `100·cos(lat)` km on
   the ground — 61 km at 52°N. The ground length is therefore computed with a `cos(lat)`
   factor taken at the CENTRE of the current view, and the round number that comes out of
   [`_nice_length`](@ref) is converted BACK to mercator metres for drawing.
2. **Everything is anchored to a fraction of `lims`**, not to fixed coordinates, so the bar
   stays in its corner at every zoom level instead of drifting off screen.

The bar is a single bracket-shaped polyline (cap, rule, cap) rather than three plots, so the
whole thing costs one scene child.
"""
function _scalebar_geometry(lims, position::Symbol, pad::Real)
    xmin, ymin = minimum(lims)
    xmax, ymax = maximum(lims)
    w = Float64(xmax - xmin)
    h = Float64(ymax - ymin)

    latc = _deg_from_merc(:y, 0.5 * (Float64(ymin) + Float64(ymax)))
    # Ground metres per mercator metre at the centre latitude of the view.
    k = max(cos(deg2rad(clamp(latc, -_MERC_LAT_LIMIT, _MERC_LAT_LIMIT))), 1.0e-6)

    ground_km = _nice_length(w * _SCALEBAR_TARGET_FRAC * k / 1000)
    bar = 1000 * ground_km / k                      # back into mercator metres for drawing

    top = position === :rt || position === :lt
    sgn = top ? -1.0 : 1.0
    caph = sgn * 0.012 * h
    px = Float64(pad) * w
    py = Float64(pad) * h

    x1 = (position === :rb || position === :rt) ? Float64(xmax) - px : Float64(xmin) + px + bar
    x0 = x1 - bar
    y = top ? Float64(ymax) - py : Float64(ymin) + py

    points = Point2f[
        Point2f(x0, y + caph), Point2f(x0, y), Point2f(x1, y), Point2f(x1, y + caph),
    ]
    label = ground_km >= 1 ? string(_fixed(ground_km, 0), " km") :
        string(round(Int, ground_km * 1000), " m")
    anchor = Point2f(0.5 * (x0 + x1), y + caph + sgn * 0.006 * h)
    return (points = points, anchor = anchor, label = label)
end

"""
    _add_scalebar!(ax; position = :rb, pad = 0.035)

Draw a reactive kilometre scale bar into a Web Mercator axis.

Everything is `lift`ed off `ax.finallimits`, so the bar's length, its round-number label and
its corner are recomputed on every zoom and pan — see [`_scalebar_geometry`](@ref) for the
latitude correction, which is the part that makes the number on the label true rather than
merely plausible.

Drawn as a white halo under a dark rule so it stays legible on the pale CartoDB tiles;
`overdraw` plus a large z translation keeps it above both the tiles and the network.
`position` is one of `:rb`, `:lb`, `:rt`, `:lt`.
"""
function _add_scalebar!(ax; position::Symbol = :rb, pad::Real = 0.035)
    geom = lift(l -> _scalebar_geometry(l, position, pad), ax.finallimits)
    points = lift(g -> g.points, geom)
    anchor = lift(g -> g.anchor, geom)
    label = lift(g -> g.label, geom)
    top = position === :rt || position === :lt

    halo = lines!(ax, points; color = (:white, 0.9), linewidth = 5,
                  overdraw = true, inspectable = false)
    rule = lines!(ax, points; color = :black, linewidth = 2,
                  overdraw = true, inspectable = false)
    txt = text!(ax, anchor; text = label, align = (:center, top ? :top : :bottom),
                fontsize = 12, color = :black, strokecolor = (:white, 0.9), strokewidth = 2,
                overdraw = true, inspectable = false)
    for p in (halo, rule, txt)
        translate!(p, 0, 0, 1000)
    end
    return ax
end

"""
    _add_north_arrow!(ax; position = :rt, pad = 0.035)

Draw a reactive north arrow into a Web Mercator axis.

Web Mercator is north-up at every point on the map, so "up on the page" IS north and the
arrow needs no rotation — that is a property of the projection, not a simplification. The
arrow is still `lift`ed off `ax.finallimits` for the same reason the scale bar is: its size
and its corner are fractions of the current view, so it neither shrinks to a dot nor wanders
off screen while the user zooms.

`position` is one of `:rt`, `:lt`, `:rb`, `:lb`.
"""
function _add_north_arrow!(ax; position::Symbol = :rt, pad::Real = 0.035)
    geom = lift(ax.finallimits) do lims
        xmin, ymin = minimum(lims)
        xmax, ymax = maximum(lims)
        w = Float64(xmax - xmin)
        h = Float64(ymax - ymin)
        # Sized off `min(w, h)`: the map axes hold an equal-aspect view, so one data unit is
        # the same number of pixels on both axes and a single scale keeps the arrow square.
        s = 0.07 * min(w, h)
        px = Float64(pad) * w
        py = Float64(pad) * h
        x = (position === :rt || position === :rb) ? Float64(xmax) - px : Float64(xmin) + px
        # `0.05h` of headroom above the tip is where the "N" goes.
        ytop = (position === :rt || position === :lt) ? Float64(ymax) - py - 0.05 * h :
            Float64(ymin) + py + s
        y0 = ytop - s
        shaft = Point2f[Point2f(x, y0), Point2f(x, y0 + 0.6 * s)]
        head = Point2f[
            Point2f(x, ytop), Point2f(x - 0.17 * s, y0 + 0.55 * s),
            Point2f(x + 0.17 * s, y0 + 0.55 * s),
        ]
        return (shaft = shaft, head = head, anchor = Point2f(x, ytop + 0.012 * h))
    end

    shaft = lift(g -> g.shaft, geom)
    head = lift(g -> g.head, geom)
    anchor = lift(g -> g.anchor, geom)

    stem = lines!(ax, shaft; color = :black, linewidth = 2,
                  overdraw = true, inspectable = false)
    tip = poly!(ax, head; color = :black, strokecolor = (:white, 0.9), strokewidth = 1,
                overdraw = true, inspectable = false)
    txt = text!(ax, anchor; text = "N", align = (:center, :bottom), fontsize = 13,
                font = :bold, color = :black, strokecolor = (:white, 0.9), strokewidth = 2,
                overdraw = true, inspectable = false)
    for p in (stem, tip, txt)
        translate!(p, 0, 0, 1000)
    end
    return ax
end

"""
    _style_map_axis!(ax; scalebar = true, north_arrow = true, projection_note = false,
                     scalebar_position = :rb, north_arrow_position = :rt)

Turn a raw Web Mercator `Axis` into a publication-grade map axis: degree ticks,
`Longitude`/`Latitude` labels, a scale bar and a north arrow. `projection_note = true` adds
[`_MAP_PROJECTION_NOTE`](@ref) as the subtitle as well; it is off by default because the CRS
is caption material for most readers and the subtitle is more useful for scenario text.

Call this only on axes that really are geographic. An axis holding the
[`_circular_node_positions`](@ref) fallback carries no coordinates at all, so degrees, a
scale bar and a north arrow would every one of them be a fabrication —
[`create_lineplot_layout`](@ref) gates the call on its `geographic` keyword for exactly that
reason.

When tiles are drawn this must run AFTER `Tyler.Map` and its `wait`: Tyler sets axis
attributes itself (limits, `autolimitaspect`, grid visibility) and would otherwise land on
top of the styling.

The two `ticklabelspace` assignments are load-bearing, not cosmetic. Tyler leaves the axis on
`autolimitaspect = 1`, and Makie documents a cyclical relayout for that setting — expanded
limits → different ticks → different label widths → relayout → different limits — that ends
in a stack overflow. Degree labels change width as you zoom (`5°E` vs `5.25°E`), which is
precisely the trigger; reserving a fixed amount of space breaks the cycle.
"""
function _style_map_axis!(
    ax;
    scalebar::Bool = true,
    north_arrow::Bool = true,
    projection_note::Bool = false,
    scalebar_position::Symbol = :rb,
    north_arrow_position::Symbol = :rt,
)
    ax.xlabel = "Longitude"
    ax.ylabel = "Latitude"
    ax.xticks = DegreeTicks(:x)
    ax.yticks = DegreeTicks(:y)
    ax.xticklabelspace = 22.0
    ax.yticklabelspace = 62.0

    # `ax.subtitle` is CONTENDED, and last writer wins. Three other places write it and none
    # of them coordinate with this one: `plot_capacity_network` and `plot_shift_map_interactive`
    # put `_NO_COORDS_NOTE` there on the circular fallback (mutually exclusive with this
    # branch, since that path is not styled at all), and `plot_line_utils_interactive`
    # rewrites it with its live colour/width key on every slider tick — which WOULD clobber
    # the CRS note, silently and immediately, the moment `projection_note` is defaulted on.
    # Flipping that default therefore means giving the interactive key a slot of its own.
    if projection_note
        ax.subtitle = _MAP_PROJECTION_NOTE
        ax.subtitlecolor = RGBAf(0.0, 0.0, 0.0, 0.55)
    end
    scalebar && _add_scalebar!(ax; position = scalebar_position)
    north_arrow && _add_north_arrow!(ax; position = north_arrow_position)
    return ax
end

"Keyword names [`_style_map_axis!`](@ref) accepts, read off the method itself so the two
cannot drift apart the way a hand-maintained list would."
_map_axis_knobs() = Tuple(Base.kwarg_decl(only(methods(_style_map_axis!))))

"""
    _map_axis_style_kwargs(map_axis) -> NamedTuple | Nothing

Normalise the public `map_axis` keyword into keyword arguments for
[`_style_map_axis!`](@ref), or `nothing` when the caller asked for a bare axis.

`true` means "the defaults" and becomes an empty `NamedTuple`; a `NamedTuple` passes through
verbatim, which is what makes all five knobs of `_style_map_axis!` reachable without six
public signatures growing five keywords each (the same shape as Makie's own `axis = (; ...)`
passthrough). `false` becomes `nothing`.

Both failure modes are caught HERE, at the top of [`create_lineplot_layout`](@ref), rather
than where they would otherwise surface. A wrong type would reach `_style_map_axis!` and a
misspelled field would reach it as an unsupported keyword — but both only AFTER a window has
opened and, with tiles on, after a network-bound tile fetch has run. A caller who mistyped a
keyword should not have to wait for a map to draw to find out.
"""
_map_axis_style_kwargs(map_axis::Bool) = map_axis ? NamedTuple() : nothing

function _map_axis_style_kwargs(map_axis::NamedTuple)
    knobs = _map_axis_knobs()
    unknown = setdiff(collect(keys(map_axis)), collect(knobs))
    isempty(unknown) || throw(ArgumentError(
        "`map_axis` got unknown field(s) $(join(unknown, ", ")). " *
        "Accepted fields: $(join(knobs, ", "))."))
    return map_axis
end

_map_axis_style_kwargs(map_axis) = throw(ArgumentError(
    "`map_axis` must be a Bool or a NamedTuple, got $(typeof(map_axis)). " *
    "Use `true` for the default styling, `false` for a bare axis, or a NamedTuple of " *
    "$(join(_map_axis_knobs(), ", ")) to override individual settings."))
