const DEFAULT_PLOT_COLORS = Dict(
    "exchange" => "#9526b7",
    "LL" => "#ff0000",
    "CU" => "#ff7373",
    "Net injection" => "#b2a1d5",
)

# Colour of a series with no entry in `params.colors`.
const _FALLBACK_COLOR = RGBAf(0.6, 0.6, 0.6, 1.0)

"""
Series pinned to the **end** of the stack and drawn pale.

These are annotations sitting on top of the dispatch, not part of it. `CU` is foregone
renewable potential: it is already netted out of `GEN` (`FEEDIN = avail*gmax - CU` in
`technologies.jl`) and appears in no energy balance, so the stack reads

    below the rule at the cap's lower edge = the balance (dispatch, lost load, imports)
    thickness of the cap                   = curtailment

Per non-dispatchable plant `GEN + CU == avail*gmax`, so the cap is exactly the gap between
what the technology could have delivered and what it did. Note the *total* stack height is
balance + curtailment, not `avail*gmax` — the positive half also carries `LL` and, when the
zone imports, `exchange`.

Two reasons the ordering is not cosmetic. A curtailment band in the middle of the stack
would make every band edge above it meaningless, and keeping non-balance series out of the
downward half means the negative stack is now purely balance terms — "sum it and subtract
to get load" no longer has a silent exception.
"""
const _TOP_SERIES = ("CU",)

# Alpha of a `_TOP_SERIES` band, so a cap cannot be mistaken for generation.
const _PALE_ALPHA = 0.45f0

# Sort key: alphabetical, but `_TOP_SERIES` always last.
_series_order(s) = (s in _TOP_SERIES ? 1 : 0, s)

"""
Below this, a stack series counts as absent rather than as a zero-height band.

In the plotted unit: `1e-9` is 1 W at the default `scalefactor = 1/1000` (MW to GW), so it
discards floating-point residue and nothing a figure could show. See the use site in
[`_dispatch_data`](@ref) for why sign-of-noise otherwise leaks into the legend.
"""
const _SERIES_TOL = 1e-9

_time_values(time_horizon) = collect(time_horizon)

"""
    _plot_colors(results) -> Dict{String,RGBAf}

Series colour table, `params.colors` overlaid with [`DEFAULT_PLOT_COLORS`](@ref), parsed
to `RGBAf` **once**.

Parsing here rather than at each `band!`/`barplot!` call keeps every colour vector handed
to Makie concretely typed — the previous `Union{String,Symbol}` return of `_color_for`
made each one a `Vector{Any}`. Callers must hoist this out of loops: it builds a `Dict`.
"""
_plot_colors(results) = _parse_color_table(merge(results.params.colors, DEFAULT_PLOT_COLORS))

"""
    _parse_color_table(d) -> Dict{String,RGBAf}

Parse a `name => colour string` table to `RGBAf` once, replacing anything unparseable with
[`_FALLBACK_COLOR`](@ref) and reporting all of them in a single warning.

Split out of [`_plot_colors`](@ref) so a colour table read straight from `planttypes.csv`
(no `Parameters`, no results) goes through the same parsing and the same warning.
"""
function _parse_color_table(d::AbstractDict)
    out = Dict{String,RGBAf}()
    sizehint!(out, length(d))
    bad = String[]
    for (k, v) in d
        # `parse(Colorant, …)` throws and Colors has no guaranteed `tryparse`; this runs
        # once per plant type at setup, never in a plot loop, so the exception is fine here.
        out[string(k)] = try
            RGBAf(parse(Colorant, v))
        catch
            push!(bad, string(k))
            _FALLBACK_COLOR
        end
    end
    isempty(bad) ||
        @warn "Unparseable colour(s), falling back to gray: $(join(sort!(bad), ", "))"
    return out
end

_color_for(colors::AbstractDict{String,RGBAf}, type) = get(colors, type, _FALLBACK_COLOR)

"Parse a literal hex colour to `RGBAf` at definition time, for the module-level palettes."
_hex_color(s) = RGBAf(parse(Colorant, s))

# Profile lookup without `try`/`catch`. This runs once per (node, hour) — at 1000 nodes ×
# 8760 h a single out-of-range index made the exception path the slowest thing in the
# extension, and the bare `catch` also reported a wrong key as a silent 0.0. Dispatching
# on the two members of `ConcreteProfile` keeps it allocation-free.
_value_at(p::FixedProfile, t) = Float64(p.val)
_value_at(p::HourlyProfile, t) =
    (1 <= t <= length(p.val)) ? Float64(@inbounds p.val[t]) : 0.0
function _value_at(profile, t)
    value = profile[t]
    return ismissing(value) ? 0.0 : Float64(value)
end

# Function barrier: `prof` arrives as a `Union{FixedProfile,HourlyProfile}` element, so
# specialising here keeps the inner loop free of per-element dispatch.
function _accumulate_profile!(acc, prof, time_values)
    @inbounds for i in eachindex(time_values, acc)
        acc[i] += _value_at(prof, time_values[i])
    end
    return acc
end

"""
    _zone_load_series(params, time_values; scalefactor = 1.0) -> Dict{String,Vector{Float64}}

Zonal load over `time_values`, summed from `params.nodal_load` in one pass per zone.

Replaces the per-element `_load_at(params, zone, t)`, which redid the `nodes_in_zone`
lookup and a `haskey`-guarded generator for every single (zone, hour) — and was called
again on every slider tick from the reference-day plot.
"""
function _zone_load_series(params, time_values; scalefactor = 1.0)
    out = Dict{String,Vector{Float64}}()
    sizehint!(out, length(params.sets.Z))
    for z in params.sets.Z
        acc = zeros(Float64, length(time_values))
        for n in get(params.nodes_in_zone, z, String[])
            prof = get(params.nodal_load, n, nothing)
            prof === nothing && continue
            _accumulate_profile!(acc, prof, time_values)
        end
        scalefactor == 1.0 || (acc .*= scalefactor)
        out[z] = acc
    end
    return out
end

# NOTE: the load curve has always been scaled by a hard-coded 1/1000 while the dispatch
# stack uses `scalefactor`. They agree at the default `scalefactor = 1/1000` and diverge
# otherwise. Kept as-is so the figures do not change; fix it deliberately, not here.
_load_by_zone(results, time_values) =
    Dict(z => (Time = time_values, orig_load = v) for (z, v) in
         _zone_load_series(results.params, time_values; scalefactor = 1 / 1000))

"""
    _price_points_by_zone(results, time_pos) -> Dict{String,Vector{Point2f}}

Zonal price curve as ready-to-plot points, sorted by time.

One pass over `ZonalMarketBalance` instead of the `2·|Z|` full scans the previous
`@rsubset`-per-zone chain cost, and the result is the `Point2f` vector a `lines!`
`Observable` takes directly, so a zone change is a plain assignment.
"""
function _price_points_by_zone(results, time_pos)
    out = Dict{String,Vector{Point2f}}()
    for z in results.params.sets.Z
        out[z] = Point2f[]
    end
    df = results.ZonalMarketBalance
    (df isa DataFrame && !isempty(df) && hasproperty(df, :MarketBalance)) || return out
    _fill_price_points!(out, df.Zone, df.Time, df.MarketBalance, time_pos)
    for v in values(out)
        sort!(v; by = first)
    end
    return out
end

function _fill_price_points!(out, zonecol, timecol, pricecol, time_pos)
    @inbounds for k in eachindex(zonecol, timecol, pricecol)
        t = Int(timecol[k])
        haskey(time_pos, t) || continue
        v = get(out, String(zonecol[k]), nothing)
        v === nothing && continue
        p = pricecol[k]
        push!(v, Point2f(t, ismissing(p) ? 0.0 : Float64(p)))
    end
    return out
end

# ---------------------------------------------------------------------------------------
# Stacked dispatch data
#
# A "part" is one additive contribution to the stack (day-ahead GEN, curtailment, the
# exchange column, ...) held as the raw result columns plus how to resolve them:
#
#   key2zone === nothing  the key column already holds zone labels
#   label    === nothing  the series name comes from `type_of[key]`, else it is `label`
#
# The previous pipeline built one enriched DataFrame per part (`transform` + `filter` +
# `dropmissing`, i.e. two full copies), grouped each by (zone, Time, plant_type), `vcat`ed
# them and then summed the result into matrices anyway — the grouping was redundant work
# on top of a stack of temporary frames. Here every part is summed straight into the
# per-zone matrices.
# ---------------------------------------------------------------------------------------
_dispatch_part(keycol, timecol, valuecol; key2zone = nothing, type_of = nothing,
               label = nothing, sgn = 1.0, scale = 1.0) =
    (key = keycol, time = timecol, value = valuecol, key2zone = key2zone,
     type_of = type_of, label = label, factor = Float64(sgn) * Float64(scale))

"""
Call `f(zone, time_index, series, value)` for every in-horizon row of one dispatch part.

`f` is passed as the first argument and the method is specialised on it (`where {F}`), so
the callback inlines instead of dispatching per row. Two passes run over the same parts —
one to collect the series names, one to sum — which is why the resolution lives here
instead of being materialised into temporary columns.
"""
function _each_dispatch_row(f::F, part, time_pos) where {F}
    keycol, timecol, valuecol = part.key, part.time, part.value
    key2zone, type_of, label = part.key2zone, part.type_of, part.label
    factor = part.factor
    @inbounds for k in eachindex(keycol, timecol, valuecol)
        raw = valuecol[k]
        ismissing(raw) && continue
        ti = get(time_pos, Int(timecol[k]), 0)
        ti == 0 && continue
        key = String(keycol[k])
        zone = key2zone === nothing ? key : get(key2zone, key, "")
        isempty(zone) && continue
        series = label === nothing ? get(type_of, key, "unknown") : label
        f(zone, ti, series, factor * Float64(raw))
    end
    return nothing
end

"""
One zone's stacked dispatch: cumulative `time × series` matrices for the upward and
downward halves, plus which series that zone actually had rows for (`pos_used`/`neg_used`
drive the legend, which stays zone-specific even though the matrices are not).
"""
struct _ZoneDispatch
    pos_mat::Matrix{Float64}
    neg_mat::Matrix{Float64}
    pos_used::BitVector
    neg_used::BitVector
end

"""
    _dispatch_data(results, parts, time_values)

Cumulative stacked-dispatch matrices per zone over a **shared** series order.

`pos_types`/`neg_types` are the union across every zone, so the interactive plots can
create their `band!` objects once and only reassign the `Observable` edges on a zone
change; previously each redraw destroyed and rebuilt one plot object per plant type. A
zone that never uses a series carries a zero column, and `pos_used`/`neg_used` record
which series that zone actually had rows for, so the legend still lists only those.

**Sign is decided per part, on that part's aggregate.** Each part is summed over
(zone, hour, series) on its own and the total then goes up or down; the halves accumulate
across parts. This is exactly what the old pipeline did — `groupby` ran inside each
`_aggregate_*` call, the results were `vcat`ed, and `filter(:value => >=(0))` then split
the concatenated **rows**. Both halves of that matter:

- Summing across parts first would be wrong. `GEN` and `CU` of the same plant map to the
  same plant type, and the stack must show generation up and curtailment down rather than
  one netted bar.
- Summing within a part is required. `Net injection` is the per-node `NETINPUT` of a zone,
  so importing and exporting nodes have to cancel into one bar instead of growing both
  halves of the stack.

A series may be positive in some hours and negative in others, so it can appear in both
`pos_types` and `neg_types`. `present` keeps a cell no row ever wrote out of the reckoning:
a dense zero would otherwise read as non-negative and put the series in `pos_types`.
"""
function _dispatch_data(results, parts, time_values)
    ntime = length(time_values)
    time_pos = Dict{Int,Int}(Int(t) => i for (i, t) in enumerate(time_values))

    seen = Set{String}()
    for part in parts
        _each_dispatch_row(part, time_pos) do _, _, series, _
            push!(seen, series)
            return nothing
        end
    end
    series = sort!(collect(seen); by = _series_order)
    sidx = Dict{String,Int}(s => i for (i, s) in enumerate(series))
    nseries = length(series)

    # Zones are addressed by POSITION, not by a `Dict` of accumulators. `get(dict, k,
    # nothing)` on a dict whose value type is an immutable struct returns
    # `Union{Nothing,T}`, and because the struct is stored inline the union has to be
    # boxed — one heap allocation per row, which dominated everything else here.
    # An `Int` index is isbits, so the same lookup is allocation-free.
    zones = results.params.sets.Z
    nz = length(zones)
    zone_idx = Dict{String,Int}(z => i for (i, z) in enumerate(zones))
    pos = [zeros(Float64, ntime, nseries) for _ = 1:nz]
    neg = [zeros(Float64, ntime, nseries) for _ = 1:nz]
    pos_used = [falses(nseries) for _ = 1:nz]
    neg_used = [falses(nseries) for _ = 1:nz]
    # One scratch accumulator per zone, cleared and reused per part.
    acc = [zeros(Float64, ntime, nseries) for _ = 1:nz]
    seen_cell = [falses(ntime, nseries) for _ = 1:nz]

    for part in parts
        for i = 1:nz
            fill!(acc[i], 0.0)
            fill!(seen_cell[i], false)
        end
        _each_dispatch_row(part, time_pos) do zone, ti, s, v
            zi = get(zone_idx, zone, 0)
            zi == 0 && return nothing
            ci = get(sidx, s, 0)
            ci == 0 && return nothing
            @inbounds acc[zi][ti, ci] += v
            @inbounds seen_cell[zi][ti, ci] = true
            return nothing
        end
        for zi = 1:nz
            A, S = acc[zi], seen_cell[zi]
            Pm, Nm = pos[zi], neg[zi]
            @inbounds for ci = 1:nseries, ti = 1:ntime
                S[ti, ci] || continue
                v = A[ti, ci]
                v >= 0 ? (Pm[ti, ci] += v) : (Nm[ti, ci] += v)
            end
        end
    end

    # Which side a series is *listed* on is decided from the finished column, and only
    # when it carries something visible. Marking it used the moment any cell was written
    # made legend membership depend on floating-point noise: a zone's `NETINPUT` sums to
    # exactly zero in a nodal market (the closed nodal balance), so the aggregate is a
    # ±1e-19 residual whose sign follows summation order. That put a permanently invisible
    # `Net injection` entry in the legend, on a side that could flip between runs of the
    # same scenario. Judging the accumulated column also beats judging each contribution,
    # since it is the drawn value that matters.
    for zi = 1:nz
        Pm, Nm, pu, nu = pos[zi], neg[zi], pos_used[zi], neg_used[zi]
        @inbounds for ci = 1:nseries
            pu[ci] = _any_significant(Pm, ci, ntime)
            nu[ci] = _any_significant(Nm, ci, ntime)
        end
    end

    # keep only the series some zone actually puts on that side
    pos_flags, neg_flags = falses(nseries), falses(nseries)
    for zi = 1:nz
        pos_flags .|= pos_used[zi]
        neg_flags .|= neg_used[zi]
    end
    pos_cols, neg_cols = findall(pos_flags), findall(neg_flags)

    zone_data = Dict{String,_ZoneDispatch}()
    for (zi, z) in enumerate(zones)
        zone_data[z] = _ZoneDispatch(
            _cumulate_columns!(pos[zi][:, pos_cols]),
            _cumulate_columns!(neg[zi][:, neg_cols]),
            pos_used[zi][pos_cols],
            neg_used[zi][neg_cols],
        )
    end

    return (time = time_values, pos_types = series[pos_cols],
            neg_types = series[neg_cols], zones = zone_data)
end

"`true` when column `ci` of `m` holds anything above [`_SERIES_TOL`](@ref)."
function _any_significant(m, ci, ntime)
    @inbounds for ti = 1:ntime
        abs(m[ti, ci]) > _SERIES_TOL && return true
    end
    return false
end

"In-place running sum along the series axis (was `cumsum(m, dims = 2)`, a second matrix)."
function _cumulate_columns!(m)
    @inbounds for j in 2:size(m, 2), i in axes(m, 1)
        m[i, j] += m[i, j-1]
    end
    return m
end

"Day-ahead stack contributions, in the order they were `vcat`ed before."
function _disp_parts(results, scalefactor)
    params = results.params
    parts = Any[]   # heterogeneous column types; one dynamic dispatch per part, not per row
    gen = results.GEN
    if gen isa DataFrame && !isempty(gen)
        hasproperty(gen, :GEN) && push!(parts, _dispatch_part(
            gen.index, gen.Time, gen.GEN;
            key2zone = params.plant2zone, type_of = params.plant_type, scale = scalefactor))
        # Curtailment is its own series drawn as a pale cap on top of the stack, so the
        # total height is the true renewable potential `avail*gmax` and the cap is the part
        # that was thrown away. It is NOT a downward bar: it is already netted out of `GEN`
        # and is in no energy balance, so putting it below zero made the negative stack
        # unusable for reading off load. See `_TOP_SERIES`.
        hasproperty(gen, :CU) && push!(parts, _dispatch_part(
            gen.index, gen.Time, gen.CU;
            key2zone = params.plant2zone, label = "CU", scale = scalefactor))
    end
    charge = results.CHARGE
    if charge isa DataFrame && !isempty(charge) && hasproperty(charge, :CHARGE)
        push!(parts, _dispatch_part(
            charge.index, charge.Time, charge.CHARGE;
            key2zone = params.plant2zone, type_of = params.plant_type,
            sgn = -1.0, scale = scalefactor))
    end
    zb = results.ZonalMarketBalance
    if zb isa DataFrame && !isempty(zb) && hasproperty(zb, :LL)
        push!(parts, _dispatch_part(zb.Zone, zb.Time, zb.LL;
                                    label = "LL", scale = scalefactor))
    end
    ex = results.EXCHANGE
    if ex isa DataFrame && !isempty(ex) && hasproperty(ex, :EXCHANGE)
        push!(parts, _dispatch_part(ex.index, ex.Time, ex.EXCHANGE;
                                    label = "exchange", scale = scalefactor))
    end
    return parts
end

"Redispatch stack contributions."
function _redisp_parts(results, scalefactor)
    params = results.params
    parts = Any[]
    redisp = results.REDISP
    if redisp isa DataFrame && !isempty(redisp)
        for (col, sgn) in ((:GEN_REDISP, 1.0), (:CHARGE_REDISP, -1.0))
            hasproperty(redisp, col) || continue
            push!(parts, _dispatch_part(
                redisp.index, redisp.Time, redisp[!, col];
                key2zone = params.plant2zone, type_of = params.plant_type,
                sgn = sgn, scale = scalefactor))
        end
        # pale cap on top, same reasoning as `_disp_parts`; the invariant survives
        # redispatch as `GEN_REDISP + CU_REDISP == avail*gmax`
        hasproperty(redisp, :CU_REDISP) && push!(parts, _dispatch_part(
            redisp.index, redisp.Time, redisp.CU_REDISP;
            key2zone = params.plant2zone, label = "CU", scale = scalefactor))
    end
    ni = results.NETINPUT
    if ni isa DataFrame && !isempty(ni) && hasproperty(ni, :NETINPUT)
        push!(parts, _dispatch_part(ni.index, ni.Time, ni.NETINPUT;
                                    key2zone = params.node2zone, label = "Net injection",
                                    scale = scalefactor))
    end
    nb = results.NodalMarketRedispBalance
    if nb isa DataFrame && !isempty(nb) && hasproperty(nb, :LL)
        push!(parts, _dispatch_part(nb.Node, nb.Time, nb.LL;
                                    key2zone = params.node2zone, label = "LL",
                                    scale = scalefactor))
    end
    return parts
end

"""
    prepare_disp_plot_data(results, scalefactor, time_horizon)
    prepare_redisp_plot_data(results, scalefactor, time_horizon)

`(prices, loads, dispatch)` for one market stage. Prices and loads are stage-independent —
[`plot_DA_w_Redisp_interactive`](@ref) builds them once and only calls `_dispatch_data`
per stage.
"""
function prepare_disp_plot_data(results, scalefactor, time_horizon)
    time_values = _time_values(time_horizon)
    time_pos = Dict{Int,Int}(Int(t) => i for (i, t) in enumerate(time_values))
    return _price_points_by_zone(results, time_pos),
           _load_by_zone(results, time_values),
           _dispatch_data(results, _disp_parts(results, scalefactor), time_values)
end

function prepare_redisp_plot_data(results, scalefactor, time_horizon)
    time_values = _time_values(time_horizon)
    time_pos = Dict{Int,Int}(Int(t) => i for (i, t) in enumerate(time_values))
    return _price_points_by_zone(results, time_pos),
           _load_by_zone(results, time_values),
           _dispatch_data(results, _redisp_parts(results, scalefactor), time_values)
end

"""
    _clear_legends!(fig)

Delete every `Legend` currently in `fig`.

`delete!` removes the block from `fig.content` while it is being walked, so the plain
`for leg in fig.content` this replaces skipped whichever block shifted into the freed
index — with two adjacent legends (`update_plot_comb!`) one survived every redraw and they
piled up. Collecting first makes the walk independent of the mutation.
"""
_clear_legends!(fig) = foreach(delete!, filter(x -> x isa Legend, collect(fig.content)))

"""
    _make_bands!(ax, x, types, colors; labelled) -> (edges, handles)

One stacked `band!` per entry of `types`, backed by `Observable` upper edges — band `i`
runs from edge `i-1` (zero for the first) to edge `i`.

The band objects are created once and only their observables are reassigned, so a zone
change no longer destroys and rebuilds one scene child per plant type. `edges` is returned
in `types` order for [`_set_bands!`](@ref); `handles` is empty unless `labelled`.

A [`_TOP_SERIES`](@ref) band is drawn at [`_PALE_ALPHA`](@ref) with a thin rule along its
lower edge. `band!` has no stroke attribute, and the rule is the more useful mark anyway:
it is the boundary between the balance below and the foregone potential above.
"""
function _make_bands!(ax, x, types, colors; labelled::Bool = true)
    n = length(types)
    nx = length(x)
    edges = [Observable(zeros(Float64, nx)) for _ = 1:n]
    zero_edge = zeros(Float64, nx)
    handles = Any[]
    for i = 1:n
        lower = i == 1 ? zero_edge : edges[i-1]
        c = _color_for(colors, types[i])
        is_cap = types[i] in _TOP_SERIES
        b = band!(ax, x, lower, edges[i];
                  color = is_cap ? RGBAf(c.r, c.g, c.b, _PALE_ALPHA) : c,
                  label = types[i])
        is_cap && lines!(ax, x, lower; color = (:black, 0.55), linewidth = 0.8)
        labelled && push!(handles, b)
    end
    return edges, handles
end

"Copy the cumulative matrix into the band edge observables (no reallocation per redraw)."
function _set_bands!(edges, mat)
    length(edges) == size(mat, 2) ||
        throw(DimensionMismatch("band count $(length(edges)) ≠ series count $(size(mat, 2))"))
    for i in eachindex(edges)
        copyto!(edges[i][], view(mat, :, i))
    end
    foreach(notify, edges)
    return nothing
end

"""
    _DispatchAxes

Persistent series of one generation axis (`ax`) and its price twin (`ax2`).

Everything except the `Legend` survives a zone change; see [`_make_bands!`](@ref).
"""
struct _DispatchAxes{A,B,H,L,P}
    ax::A
    ax2::B
    pos_edges::Vector{Observable{Vector{Float64}}}
    neg_edges::Vector{Observable{Vector{Float64}}}
    pos_handles::Vector{H}
    pos_types::Vector{String}
    load::Observable{Vector{Float64}}
    load_handle::L
    price::Observable{Vector{Point2f}}
    price_handle::P
end

"""
    _setup_dispatch_axes!(ax, ax2, disp, colors; price_label)

Create the persistent bands, the load line and the price line of one axis pair.
"""
function _setup_dispatch_axes!(ax, ax2, disp, colors; price_label = "price")
    pos_edges, pos_handles = _make_bands!(ax, disp.time, disp.pos_types, colors)
    neg_edges, _ = _make_bands!(ax, disp.time, disp.neg_types, colors; labelled = false)

    load_obs = Observable(zeros(Float64, length(disp.time)))
    load_line = lines!(ax, disp.time, load_obs;
                       color = :black, linestyle = :dash, label = "original load")

    price_obs = Observable(Point2f[])
    price_line = lines!(ax2, price_obs;
                        color = :black, linestyle = :dot, label = price_label)

    return _DispatchAxes(ax, ax2, pos_edges, neg_edges, pos_handles,
                         collect(disp.pos_types), load_obs, load_line,
                         price_obs, price_line)
end

"""
    _update_dispatch_axes!(da, zd, load, price) -> (handles, labels)

Point one axis pair at a zone and return its legend entries.

Only the series the zone actually has rows for are returned (`zd.pos_used`), so the legend
keeps listing exactly what it listed when each zone built its own band set.
"""
function _update_dispatch_axes!(da::_DispatchAxes, zd::_ZoneDispatch, load, price)
    _set_bands!(da.pos_edges, zd.pos_mat)
    _set_bands!(da.neg_edges, zd.neg_mat)
    da.load[] = load.orig_load
    da.price[] = price

    autolimits!(da.ax)
    autolimits!(da.ax2)

    handles = Any[]
    labels = String[]
    for i in eachindex(da.pos_types)
        zd.pos_used[i] || continue
        push!(handles, da.pos_handles[i])
        push!(labels, da.pos_types[i])
    end
    return handles, labels
end
"""
    plot_market_interactive(results; time_horizon=nothing, scalefactor=1/1000, kind=:DA)

Creates an interactive plot for visualizing market results by zone, including generation dispatch, load, and price curves.

# Arguments
- `results`: A data structure containing DA market simulation results (typically a `DataFiles` struct).
- `time_horizon`: (optional, keyword) A range of time steps (hours) to plot. If not provided, uses the entire time range in `results.GEN`.
- `scalefactor`: (optional, keyword, default: 1/1000) A scaling factor for power values (e.g., from MW to GW).
- `kind`: (optional, keyword, default: :DA) Specify what market stage should be visualized. Currently supported are `:DA` for Day-Ahead and `:REDISP` for Redispatch.
# Interactivity
- Dropdown menu to select market zone.
- Plot updates automatically to show:
    - **Generation dispatch** (per technology)
    - **Load curve**
    - **Day-ahead price curve**
- Dual y-axes for power (GW) and price (EUR/MWh).

# Returns
- `fig`: An interactive plot figure (`Makie.Figure`) for display or saving.

# Example
```julia
fig = plot_market_interactive(results)
```
"""
function POMATWO.plot_market_interactive(
    results;
    time_horizon=nothing,
    scalefactor=1/1000,
    kind=:DA  # or :Redispatch
)
    colors = _plot_colors(results)
    table = kind == :DA ? results.GEN : results.REDISP
    if time_horizon === nothing
        time_horizon = 1:maximum(table.Time)
    end

    data_prep = kind == :DA ? prepare_disp_plot_data : prepare_redisp_plot_data
    prices_by_zone, load_by_zone, disp = data_prep(results, scalefactor, time_horizon)
    fig = Figure(size = (1200, 800))

    # Dropdown menu for selecting a zone
    zone_menu = Menu(fig, options = results.params.sets.Z, fontsize = 30)

    fig[1, 2] = vgrid!(Label(fig, "Market Zone", fontsize = 30, width = 400), zone_menu)

    ax = Axis(fig[1:2, 1], xlabel = "Hour", ylabel = "GW", title = "Generation")

    ax2 = Axis(fig[1:2, 1], ylabel = "EUR/MWh", yaxisposition = :right)

    hidexdecorations!(ax2)
    linkxaxes!(ax, ax2)

    da = _setup_dispatch_axes!(ax, ax2, disp, colors)

    function redraw!(selected)
        handles, labels = _update_dispatch_axes!(
            da, disp.zones[selected], load_by_zone[selected], prices_by_zone[selected])
        push!(handles, da.load_handle);  push!(labels, "Load")
        push!(handles, da.price_handle); push!(labels, "Day-Ahead Price")

        _clear_legends!(fig)
        Legend(fig[2, 2], handles, labels, "Legend", nbanks = 2, position = :ct)
    end

    redraw!(results.params.sets.Z[1])
    on(zone_menu.selection) do selected
        redraw!(selected)
    end

    return fig
end
"""
    update_plot_comb!(fig, redisp_axes, da_axes, zone, ...)

Point both axis pairs of [`plot_DA_w_Redisp_interactive`](@ref) at one zone.

Note the legend wiring, kept as it was: the "Day-Ahead price" entry of the **Day-Ahead**
legend is the price line of the *redispatch* axis (`ax2`). The day-ahead price line on
`ax4` carries no legend entry.
"""
function update_plot_comb!(fig, redisp_axes, da_axes, zd_r, load, price, zd_d, load_d, price_d)
    handles, labels = _update_dispatch_axes!(redisp_axes, zd_r, load, price)
    push!(handles, redisp_axes.load_handle)
    push!(labels, "Load")

    handles_d, labels_d = _update_dispatch_axes!(da_axes, zd_d, load_d, price_d)
    push!(handles_d, da_axes.load_handle)
    push!(labels_d, "Load")
    push!(handles_d, redisp_axes.price_handle)
    push!(labels_d, "Day-Ahead price")

    _clear_legends!(fig)
    Legend(fig[2:3, 2], handles, labels, "Redispatch", nbanks = 3, position = :ct)
    Legend(fig[4, 2], handles_d, labels_d, "Day-Ahead", nbanks = 3, position = :ct)
    return nothing
end

"""
    plot_DA_w_Redisp_interactive(results; time_horizon = nothing, scalefactor = 1/1000)

Creates an interactive, comparative visualization of Day-Ahead (DA) and Redispatch market results by zone, showing generation, load, and prices before and after redispatch. This function enables side-by-side analysis of how redispatch alters zonal dispatch and market prices.

# Arguments
- `results`: Data structure containing Day-Ahead and redispatch simulation results (typically a `DataFiles` struct).
- `time_horizon`: (optional, keyword) Range of time steps (hours) to plot. Defaults to the full time range in `results.GEN`.
- `scalefactor`: (optional, keyword, default: 1/1000) Factor to scale power values (e.g., MW to GW).

# Interactivity
- Dropdown menu to select the market zone.
- The plot consists of two subplots:
    - **Top subplot:** Generation, load, and prices **after redispatch** (reflecting resolved network constraints).
    - **Bottom subplot:** Generation, load, and prices **in the Day-Ahead market** (as originally scheduled).
- Dual y-axes for both power (GW) and price (EUR/MWh).
- Plots update interactively when the selected zone changes.

# Returns
- `fig`: The interactive plot (`Makie.Figure`) ready for display or saving.

# Example
```julia
fig = plot_DA_w_Redisp_interactive(results)
```
"""
function POMATWO.plot_DA_w_Redisp_interactive(results; time_horizon = nothing, scalefactor = 1/1000)
    colors = _plot_colors(results)
    if time_horizon === nothing
        time_horizon = 1:maximum(results.GEN.Time)
    end

    # Prices and load do not depend on the market stage — the previous code called both
    # `prepare_*_plot_data` helpers, each of which rebuilt them from scratch.
    time_values = _time_values(time_horizon)
    time_pos = Dict{Int,Int}(Int(t) => i for (i, t) in enumerate(time_values))
    prices_by_zone = _price_points_by_zone(results, time_pos)
    load_by_zone = _load_by_zone(results, time_values)
    disp_r = _dispatch_data(results, _redisp_parts(results, scalefactor), time_values)
    disp_d = _dispatch_data(results, _disp_parts(results, scalefactor), time_values)

    fig = Figure(size = (1200, 800))

    # Dropdown menu for selecting a zone
    zone_menu = Menu(fig, options = results.params.sets.Z, fontsize = 30)

    fig[1, 2] = vgrid!(Label(fig, "Market Zone", fontsize = 30, width = 400), zone_menu)


    ax = Axis(
        fig[1:2, 1],
        xlabel = "Hour",
        ylabel = "GW",
        title = "Generation after Redispatch",
    )

    ax2 = Axis(fig[1:2, 1], ylabel = "EUR/MWh", yaxisposition = :right)

    hidexdecorations!(ax2)

    ax3 = Axis(fig[3:4, 1], xlabel = "Hour", ylabel = "GW", title = "Generation Day Ahead")

    ax4 = Axis(fig[3:4, 1], ylabel = "EUR/MWh", yaxisposition = :right)

    hidexdecorations!(ax4)
    linkxaxes!(ax, ax2)
    linkxaxes!(ax3, ax4)

    redisp_axes = _setup_dispatch_axes!(ax, ax2, disp_r, colors; price_label = "Day-Ahead Price")
    da_axes = _setup_dispatch_axes!(ax3, ax4, disp_d, colors; price_label = "Day-Ahead Price")

    function redraw!(selected)
        update_plot_comb!(
            fig,
            redisp_axes,
            da_axes,
            disp_r.zones[selected],
            load_by_zone[selected],
            prices_by_zone[selected],
            disp_d.zones[selected],
            load_by_zone[selected],
            prices_by_zone[selected],
        )
    end

    redraw!(results.params.sets.Z[1])
    on(zone_menu.selection) do selected
        redraw!(selected)
    end

    return fig
end


project(x, y) = MapTiles.project((x, y), MapTiles.wgs84, MapTiles.web_mercator)
project_point2f(x, y) = project(x, y) |> Point2f

# Endpoint pair of one line, already in web mercator. Naming the type lets the endpoint
# dicts be concrete — they used to be `Dict()`, i.e. `Dict{Any,Any}`, so every lookup in
# the drawing loops returned `Any` and boxed the tuple.
const _Segment = Tuple{Point2f,Point2f}

# NOTE: a `_redisp_node_summary(results)` helper used to be computed here and returned as
# the fifth element of `_prepare_lineplot_common`. Both `create_lineplot` methods discarded
# it (`..., _, node_coords = ...`), so every call paid for a `filter` + `transform` +
# `groupby` + `leftjoin` over the whole `REDISP` table and threw the result away. Nothing
# read it, so it is gone. The interactive map's redispatch markers come from
# `_redisp_injection_matrix` (line_utils_interactive.jl), not from this.

function _line_utilization_table(results, exclude_dc_lines, threshold)
    if isempty(results.LINEFLOW)
        df_line_util = DataFrame(index = String[], avg = Float64[], max = Int[])
    else
        df_line_util = @chain results.LINEFLOW begin
            @rtransform :util = :line_capacity == 0 ? 0.0 : abs(:LINEFLOW) / :line_capacity
            @by :index begin
                :avg = mean(:util)
                :max = count(>=(threshold), :util)
            end
        end
    end

    if !exclude_dc_lines && !isempty(results.DCLINEFLOW)
        df_line_util_dc = @chain results.DCLINEFLOW begin
            @rtransform :util = :line_capacity == 0 ? 0.0 : abs(:DCLINEFLOW) / :line_capacity
            @by :index begin
                :avg = mean(:util)
                :max = count(>=(threshold), :util)
            end
        end
        append!(df_line_util, df_line_util_dc, cols = :union)
    end

    if isempty(df_line_util)
        # Typed, so the empty case has the same column eltype as the populated one
        # instead of an `Any` column that boxes every later access.
        empty_colors = eltype(ColorSchemes.lajolla.colors)[]
        df_line_util[!, :avg_color] = copy(empty_colors)
        df_line_util[!, :max_color] = copy(empty_colors)
        return df_line_util
    end

    df_line_util[!, :avg_color] = get(ColorSchemes.lajolla, clamp.(df_line_util.avg, 0, 1))
    df_line_util[!, :max_color] = get(ColorSchemes.lajolla, df_line_util.max, :extrema)
    return df_line_util
end

"""
    _line_endpoints_from_data(data, exclude_dc_lines)
        -> (line_from_to, node_lonlat, node_coords)

Line geometry read from the input CSVs. `line_from_to[l]` and `node_lonlat[n]` are
web-mercator `Point2f` ready to plot; `node_coords[n]` is the raw `(lon, lat)` in WGS84,
which is what [`_auto_map_extent`](@ref) and `Tyler.Map` need.
"""
function _line_endpoints_from_data(data, exclude_dc_lines)
    node_coords = _read_node_coords(data[:nodes])
    node_lonlat = Dict{String,Point2f}(
        n => project_point2f(c[1], c[2]) for (n, c) in node_coords)

    line_from_to = Dict{String,_Segment}()
    _collect_csv_endpoints!(line_from_to, data[:lines], node_lonlat)
    exclude_dc_lines || _collect_csv_endpoints!(line_from_to, data[:dclines], node_lonlat)

    return line_from_to, node_lonlat, node_coords
end

"""
    _read_node_coords(path) -> Dict{String,Tuple{Float64,Float64}}

`index`/`lon`/`lat` of the node input file. Only those three columns are parsed; the
header is read separately so a missing column still names every column that *is* present.
"""
function _read_node_coords(path)
    header = String.(propertynames(CSV.File(path; limit = 0)))
    missing_cols = setdiff(["index", "lon", "lat"], header)
    if !isempty(missing_cols)
        error("Node file is missing required column(s): $(join(missing_cols, ", ")). "
            * "Found: $(join(header, ", "))")
    end
    nodes = CSV.read(path, DataFrame; select = [:index, :lon, :lat])
    coords = Dict{String,Tuple{Float64,Float64}}()
    sizehint!(coords, nrow(nodes))
    idx, lon, lat = nodes.index, nodes.lon, nodes.lat
    @inbounds for k in eachindex(idx, lon, lat)
        coords[String(idx[k])] = (Float64(lon[k]), Float64(lat[k]))
    end
    return coords
end

function _collect_csv_endpoints!(line_from_to, path, node_lonlat)
    df = CSV.read(path, DataFrame; select = [:index, :node_i, :node_j])
    idx, ni, nj = df.index, df.node_i, df.node_j
    @inbounds for k in eachindex(idx, ni, nj)
        from = get(node_lonlat, String(ni[k]), nothing)
        to = get(node_lonlat, String(nj[k]), nothing)
        (from === nothing || to === nothing) && continue
        line_from_to[String(idx[k])] = (from, to)
    end
    return line_from_to
end

"""
    _line_endpoints_from_results(results, exclude_dc_lines)
        -> (line_from_to, node_lonlat, node_coords)

Line geometry read from `results.params`. Same return contract as
[`_line_endpoints_from_data`](@ref); `node_coords` carries the raw WGS84 `(lon, lat)`.
"""
function _line_endpoints_from_results(results, exclude_dc_lines)
    params = results.params
    node_coords = Dict{String,Tuple{Float64,Float64}}(
        n => (params.node_coords[n][1], params.node_coords[n][2])
        for n in params.sets.N if haskey(params.node_coords, n)
    )
    node_lonlat = Dict{String,Point2f}(
        n => project_point2f(c[1], c[2]) for (n, c) in node_coords)
    line_from_to = Dict{String,_Segment}()

    _collect_param_endpoints!(line_from_to, params.sets.L, params.line_start,
                              params.line_end, node_lonlat)
    exclude_dc_lines || _collect_param_endpoints!(line_from_to, params.sets.DC,
                                                  params.dc_start, params.dc_end, node_lonlat)

    return line_from_to, node_lonlat, node_coords
end

"""
    _circular_node_positions(ids) -> Dict{String,Point2f}

Nodes laid out evenly on a unit circle, in the order of `ids`.

The fallback for a network whose nodes carry no coordinates. Topology, line styling and
per-node markers all still read correctly on it; only the geography is gone, so the axis it
is drawn in must not carry a basemap.
"""
function _circular_node_positions(ids)
    pos = Dict{String,Point2f}()
    isempty(ids) && return pos
    sizehint!(pos, length(ids))
    for (k, n) in enumerate(ids)
        θ = 2π * (k - 1) / length(ids)
        pos[String(n)] = Point2f(cos(θ), sin(θ))
    end
    return pos
end

"Axis subtitle marking a figure that fell back to [`_circular_node_positions`](@ref)."
const _NO_COORDS_NOTE = "no node coordinates in the input data — circular layout"

"""
    _results_topology(results, exclude_dc_lines)
        -> (line_from_to, node_xy, node_coords, geographic)

Line geometry from `results.params`, with a circular fallback.

While at least one node carries usable coordinates this is exactly
[`_line_endpoints_from_results`](@ref) and `geographic` is `true`. Only when **no** node does
— every one of them on the `[0.0, 0.0]` sentinel, or the node input never had a `lon`/`lat`
column — are the nodes placed on a unit circle instead, with `node_coords` `nothing` and
`geographic` `false`. Callers must then skip the basemap and `_auto_map_extent`, and pass
`geographic = false` to [`create_lineplot_layout`](@ref) so the map styling is skipped too.

Without this a coordinate-free result set draws every node on top of the same point and
every line as a zero-length segment: a blank map rather than an error.
"""
function _results_topology(results, exclude_dc_lines)
    params = results.params
    if any(n -> _has_coords(params.node_coords, n), params.sets.N)
        line_from_to, node_xy, node_coords =
            _line_endpoints_from_results(results, exclude_dc_lines)
        return line_from_to, node_xy, node_coords, true
    end

    node_xy = _circular_node_positions(sort(collect(params.sets.N)))
    line_from_to = Dict{String,_Segment}()
    _collect_param_endpoints!(line_from_to, params.sets.L, params.line_start,
                              params.line_end, node_xy)
    exclude_dc_lines || _collect_param_endpoints!(line_from_to, params.sets.DC,
                                                  params.dc_start, params.dc_end, node_xy)
    return line_from_to, node_xy, nothing, false
end

function _collect_param_endpoints!(line_from_to, ids, starts, ends, node_lonlat)
    for l in ids
        s = get(starts, l, nothing)
        e = get(ends, l, nothing)
        (s === nothing || e === nothing) && continue
        from = get(node_lonlat, s, nothing)
        to = get(node_lonlat, e, nothing)
        (from === nothing || to === nothing) && continue
        line_from_to[l] = (from, to)
    end
    return line_from_to
end

function _prepare_lineplot_common(results, data, exclude_dc_lines, threshold)
    line_from_to, node_lonlat, node_coords = data === nothing ?
        _line_endpoints_from_results(results, exclude_dc_lines) :
        _line_endpoints_from_data(data, exclude_dc_lines)
    df_line_util = _line_utilization_table(results, exclude_dc_lines, threshold)
    return results, df_line_util, line_from_to, node_lonlat, node_coords
end

"`RGBAf` of a colormap colour at a fixed alpha, without going through Makie's parser."
_with_alpha(c, alpha) = RGBAf(red(c), green(c), blue(c), alpha)

function _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshold)
    if !(type in ("max", "avg"))
        throw(ArgumentError("Type not supported, please choose 'max' or 'avg'. You entered: $type"))
    end

    # One `linesegments!` / one `scatter!` instead of a plot object per line and per node.
    # At a few thousand lines that is the difference between one scene child and a few
    # thousand, both to build and on every frame.
    color_col = type == "max" ? :max_color : :avg_color
    idx, cols = df_line_util.index, df_line_util[!, color_col]
    segments = Point2f[]
    segcolors = RGBAf[]
    sizehint!(segments, 2 * length(idx))
    sizehint!(segcolors, 2 * length(idx))
    @inbounds for k in eachindex(idx, cols)
        seg = get(line_from_to, String(idx[k]), nothing)
        seg === nothing && continue
        c = _with_alpha(cols[k], 0.98)
        push!(segments, seg[1], seg[2])
        push!(segcolors, c, c)
    end
    isempty(segments) || linesegments!(ax, segments; color = segcolors, linewidth = 1.5)

    # The caption belongs on the colorbar it explains, not on `ax.xlabel` — that now carries
    # the map's "Longitude".
    if type == "max"
        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla,
                 limits = (0, isempty(df_line_util) ? 1 : maximum(df_line_util.max)),
                 label = "count of timesteps with utilization >= $(threshold * 100)%")
    else
        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla, limits = (0.0, 1.0),
                 label = "average line utilization in selected timeframe")
    end

    isempty(node_lonlat) ||
        scatter!(ax, collect(values(node_lonlat)), color = :black, markersize = 5)

    return fig
end

# Fallback map window (Germany) for result sets whose nodes carry no usable coordinates.
const _DEFAULT_MAP_CUTOUT = Extent(X = (5.5, 15.0), Y = (47.0, 55.0))

"`true` when `coords[n]` is a usable lon/lat pair — `_load_node_coords!` stores `[0.0, 0.0]` for nodes without one."
_has_coords(coords, n) =
    haskey(coords, n) && length(coords[n]) >= 2 &&
    !(coords[n][1] == 0.0 && coords[n][2] == 0.0)

"""
    _auto_map_extent(node_coords; pad = 0.5)

WGS84 bounding box of the usable coordinates in `node_coords` (values indexable as
`[lon, lat]`), padded by `pad` degrees. Falls back to [`_DEFAULT_MAP_CUTOUT`](@ref) when
no node carries one.
"""
function _auto_map_extent(node_coords; pad = 0.5)
    pts = [c for c in values(node_coords)
           if length(c) >= 2 && !(c[1] == 0.0 && c[2] == 0.0)]
    isempty(pts) && return _DEFAULT_MAP_CUTOUT
    lons = [c[1] for c in pts]
    lats = [c[2] for c in pts]
    return Extent(
        X = (minimum(lons) - pad, maximum(lons) + pad),
        Y = (minimum(lats) - pad, maximum(lats) + pad),
    )
end

"""
    create_lineplot_layout(figsize = (800, 1000); background_map = true,
                           extent = _DEFAULT_MAP_CUTOUT, geographic = true,
                           map_axis = true)

The single axis factory every map in this extension goes through. Returns `(fig, ax)`.

`background_map` decides only whether Tyler draws raster tiles; `geographic` decides whether
the axis holds real coordinates. The two are independent: a caller may turn the tiles off for
speed and still be plotting Web Mercator metres, which is why the publication styling
([`_style_map_axis!`](@ref) — degree ticks, `Longitude`/`Latitude`, scale bar, north arrow)
is gated on `geographic` and not on `background_map`. Pass `geographic = false` for the
[`_circular_node_positions`](@ref) fallback layout, whose unit-circle coordinates would turn
every one of those decorations into a fabrication.

`map_axis` is what the caller of a public entry point controls: `true` for the default
styling, `false` for a bare Web Mercator axis, or a `NamedTuple` splatted into
`_style_map_axis!` (`map_axis = (scalebar = false,)`). It is a request, not an override —
`geographic` is the hard gate, so on the fallback layout even `map_axis = true` draws
nothing. See [`_map_axis_style_kwargs`](@ref) for the validation.
"""
function create_lineplot_layout(
    figsize = (800, 1000);
    background_map = true,
    extent = _DEFAULT_MAP_CUTOUT,
    geographic = true,
    map_axis = true,
)
    # Before the window opens and before any tile fetch: see `_map_axis_style_kwargs`.
    style = _map_axis_style_kwargs(map_axis)
    GLMakie.activate!(inline = false)
    fig = Figure(; size = figsize)
    ax = Axis(fig[1, 1])

    if background_map
        provider = OpenStreetMap(:DE)
        tm = Tyler.Map(extent; provider, figure = fig, axis = ax)
        wait(tm)
    else
        ax.aspect = DataAspect()
    end

    # After `wait(tm)`, never before: Tyler sets axis attributes itself while the map spins
    # up and would otherwise land on top of the ticks and labels. `geographic` is checked
    # first and cannot be overridden by `map_axis`: on the unit-circle fallback there is no
    # geography to label, whatever the caller asked for.
    if geographic && style !== nothing
        _style_map_axis!(ax; style...)
    end

    return fig, ax
end

"""
    create_lineplot(results_path, type="max", exclude_dc_lines=false, threshhold=0.95)

The results-only method of [`create_lineplot`](@ref): identical to the
`(results_path, data, ...)` method below, but the line geometry is read from `results.params`
instead of from input CSVs. Both are methods of the same exported function; nothing else
differs, so see the other one for the arguments and the plot description.

It takes the same keywords, `map_axis` included.

The two never compete: this method's second positional argument is typed `::String`, so
`create_lineplot(path, "avg")` selects it while `create_lineplot(path, datafiles)` selects the
other. A `String` passed where `data` belongs would land here and be read as `type` — it then
fails in `_render_lineplot!` unless the string happens to be `"max"` or `"avg"`.
"""
function POMATWO.create_lineplot(
    results_path,
    type::String = "max",
    exclude_dc_lines::Bool = false,
    threshhold::Float64 = 0.95;
    background_map::Bool = true,
    extent = nothing,
    map_axis = true,
)
    results, df_line_util, line_from_to, node_lonlat, node_coords =
        _prepare_lineplot_common(DataFiles(results_path), nothing, exclude_dc_lines, threshhold)
    extent === nothing && (extent = _auto_map_extent(node_coords))
    # Same sentinel trap as in `plot_network`: `_line_endpoints_from_*` place a node parked
    # on `[0.0, 0.0]` like any other, so only `_has_coords` can tell a real map from a
    # degenerate one.
    geographic = any(n -> _has_coords(node_coords, n), keys(node_coords))
    fig, ax = create_lineplot_layout(; background_map = background_map, extent = extent,
                                     geographic = geographic, map_axis = map_axis)
    return _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshhold)
end

"""
    create_lineplot(results_path, data, type="max", exclude_dc_lines=false, threshhold=0.95)

Creates a geographical network map showing transmission line utilization with color-coded lines based on either maximum utilization frequency or average utilization.

This is one of two methods of `create_lineplot`. Drop the `data` argument
(`create_lineplot(results_path, "avg")`) to read the line geometry from `results.params`
instead of from the input CSVs; everything below applies to both.

# Arguments
- `results_path`: Path to the directory containing simulation results.
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref)). Pass it as a `Dict{Symbol,String}`: the argument is untyped, so a `String` here would be taken for the `type` of the results-only method instead.
- `type`: (optional, default: `"max"`) Visualization mode:
    - `"max"`: Color lines by the count of timesteps where utilization >= `threshhold`.
    - `"avg"`: Color lines by the average utilization across all timesteps.
- `exclude_dc_lines`: (optional, default: `false`) If `true`, only AC lines are visualized.
- `threshhold`: (optional, default: `0.95`) Utilization threshold (0-1 scale) for `"max"` mode counting.

# Keyword arguments
- `background_map`: (default: `true`) Draw Tyler/CartoDB raster tiles behind the network.
  Turning them off changes nothing about the axis: it stays geographic and keeps its degree
  ticks, scale bar and north arrow.
- `extent`: (default: `nothing`) Map window as a `Tyler.Extents.Extent`. `nothing` fits it
  to the node coordinates; result sets whose nodes carry no coordinates fall back to
  `_DEFAULT_MAP_CUTOUT` (Germany).
- `map_axis`: (default `true`) map-axis styling. `true` for degree ticks, `Longitude` /
  `Latitude` labels, a scale bar and a north arrow; `false` for a bare axis in raw Web
  Mercator metres; or a `NamedTuple` to override individual settings, e.g.
  `map_axis = (scalebar = false,)`, `(projection_note = true,)` (adds the CRS as the
  subtitle), `(north_arrow_position = :lt,)`. Accepted fields: `scalebar`, `north_arrow`,
  `projection_note`, `scalebar_position`, `north_arrow_position`. Ignored on a dataset
  without node coordinates, where none of the decorations mean anything.

# Plot Details
- Lines are colored using the `ColorSchemes.lajolla` colormap.
- **Max mode**: Colorbar shows the count of hours where line utilization exceeds the
  threshold; the colorbar's own label states what the colour means.
- **Avg mode**: Colorbar shows average utilization percentage (0-100%).
- Network nodes are displayed as black points.
- The axis is a map axis: ticks are labelled in degrees (`10°E`, `52°N`), the axes are
  labelled `Longitude` / `Latitude`, and the figure carries a kilometre scale bar and a
  north arrow. Geometry stays in Web Mercator throughout — state the CRS,
  `WGS 84 / Pseudo-Mercator (EPSG:3857)`, in the figure caption. Mercator scale is
  latitude-dependent, so the scale bar is exact only at the latitude it is drawn at.
- A result set whose nodes carry no coordinates at all draws every node on the mercator
  origin; the map decorations are suppressed there rather than labelling a degenerate map.

# Returns
- `fig`: A Makie figure object with the network map, color-coded lines, and colorbar.

# Example
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
results_path = "path/to/results"

# Visualize lines by max utilization frequency
fig = create_lineplot(results_path, datafiles, "max", false, 0.95)

# Visualize lines by average utilization
fig = create_lineplot(results_path, datafiles, "avg")
```
"""
function POMATWO.create_lineplot(
    results_path,
    data,
    type::String = "max",
    exclude_dc_lines::Bool = false,
    threshhold::Float64 = 0.95;
    background_map::Bool = true,
    extent = nothing,
    map_axis = true,
)
    results, df_line_util, line_from_to, node_lonlat, node_coords =
        _prepare_lineplot_common(DataFiles(results_path), data, exclude_dc_lines, threshhold)
    extent === nothing && (extent = _auto_map_extent(node_coords))
    # Same sentinel trap as in `plot_network`: `_line_endpoints_from_*` place a node parked
    # on `[0.0, 0.0]` like any other, so only `_has_coords` can tell a real map from a
    # degenerate one.
    geographic = any(n -> _has_coords(node_coords, n), keys(node_coords))
    fig, ax = create_lineplot_layout(; background_map = background_map, extent = extent,
                                     geographic = geographic, map_axis = map_axis)
    return _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshhold)
end

"""
    plot_network(data::Dict{Symbol,String})

Plots a simple network map of an energy system using line and node geographical data. AC and DC transmission lines are shown as straight connections between nodes, and all network nodes are marked.

# Arguments
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref))

# Keyword arguments
- `map_axis`: (default `true`) map-axis styling. `true` for degree ticks, `Longitude` /
  `Latitude` labels, a scale bar and a north arrow; `false` for a bare axis in raw Web
  Mercator metres; or a `NamedTuple` to override individual settings, e.g.
  `map_axis = (scalebar = false,)`, `(projection_note = true,)` (adds the CRS as the
  subtitle), `(north_arrow_position = :lt,)`. Accepted fields: `scalebar`, `north_arrow`,
  `projection_note`, `scalebar_position`, `north_arrow_position`. Ignored on a dataset
  without node coordinates, where none of the decorations mean anything.

# Plot Details
- **AC lines** are drawn as solid black lines.
- **DC lines** are drawn as dashed black lines.
- **Nodes** are plotted as black points.
- The axis is a map axis: degree ticks (`10°E`, `52°N`), `Longitude` / `Latitude` labels, a
  kilometre scale bar and a north arrow. Geometry stays in Web Mercator — state the CRS,
  `WGS 84 / Pseudo-Mercator (EPSG:3857)`, in the figure caption, and note that mercator
  scale is latitude-dependent, so the scale bar is exact only at its own latitude.
- A node file whose `lon`/`lat` are all `0, 0` draws every node on the mercator origin. The
  map decorations are suppressed in that case rather than labelling a degenerate map.

# Returns
- `fig`: The Makie figure object containing the network plot.

# Example
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
fig = plot_network(datafiles)
```
"""
function POMATWO.plot_network(data::Dict{Symbol,String}; map_axis = true)
    node_coords = _read_node_coords(data[:nodes])
    node_lonlat = Dict{String,Point2f}(
        n => project_point2f(c[1], c[2]) for (n, c) in node_coords)

    # `_read_node_coords` keeps the `0.0, 0.0` sentinel rows, and `_auto_map_extent` answers
    # a Germany cutout when every row is one — so without this check a coordinate-free node
    # file would get degree ticks and a Germany-scaled scale bar over nodes stacked on the
    # mercator origin.
    geographic = any(n -> _has_coords(node_coords, n), keys(node_coords))
    fig, ax = create_lineplot_layout(; extent = _auto_map_extent(node_coords),
                                     geographic = geographic, map_axis = map_axis)

    # One draw call per line style and one for all nodes, rather than one per row.
    for (path, style) in ((data[:lines], :solid), (data[:dclines], :dash))
        segs = Dict{String,_Segment}()
        _collect_csv_endpoints!(segs, path, node_lonlat)
        isempty(segs) && continue
        pts = Point2f[]
        sizehint!(pts, 2 * length(segs))
        for (from, to) in values(segs)
            push!(pts, from, to)
        end
        linesegments!(ax, pts; color = (:black, 0.98), linewidth = 1, linestyle = style)
    end

    isempty(node_lonlat) ||
        scatter!(ax, collect(values(node_lonlat)), color = :black, markersize = 5)

    return fig
end


function plot_total_gen(results, kind, zone)
    df = summarize_result(transform_results_by_type(results, kind, zone))


    categories = names(df)  # Extract column names as labels
    values = vec(Matrix(df)) ./ 1000  # Convert DataFrame row to a vector of values and scales form MWh to GWh
    # `_plot_colors` builds a Dict — hoisted out of the comprehension, which used to
    # rebuild the whole merged colour table once per category.
    palette = _plot_colors(results)
    colors = RGBAf[_color_for(palette, c) for c in categories]
    # Create the bar plot
    fig = Figure()
    ax = Axis(
        fig[1, 1],
        xticks = (1:length(categories), categories),
        ylabel = "GWh",
        xticklabelrotation = 45,
    )

    # Create bars with custom colors
    barplot!(ax, 1:length(values), values, color = colors, bar_labels = :y)
    return fig
end

"""
    plot_total_gen_interactive(results::DataFiles)

Create an interactive bar plot of total generation by category for a selected `kind` and `zone`.

This function displays an interactive Makie figure with two dropdown menus: one for selecting the generation `kind` (e.g., day-ahead, redispatch, etc.) and one for selecting the `zone`. The bar plot updates automatically to reflect the selected `kind` and `zone`, showing total generation per category in GWh with category-specific colors.

# Arguments
- `results`: The results data structure containing generation data, available kinds, zones, and category colors.

# Returns
- `Figure`: A Makie Figure object with the interactive bar plot and dropdown menus.

# Example
```julia
fig = plot_total_gen_interactive(results)
```
"""
function POMATWO.plot_total_gen_interactive(results::DataFiles)
    # Fetch available kinds and zones from your results object
    kinds = [:DA, :REDISP]
    zones = results.params.sets.Z      # e.g. ["Zone1", "Zone2"]

    # Built once; the comprehension below used to rebuild the merged colour table per
    # category, and `get_plot_data` is called again on every menu change.
    palette = _plot_colors(results)

    # Function to generate plot data
    function get_plot_data(kind, zone)
        df = summarize_result(transform_results_by_type(results, kind, zone))
        categories = names(df)
        values = vec(Matrix(df)) ./ 1000
        colors = RGBAf[_color_for(palette, c) for c in categories]
        return categories, values, colors
    end

    # Initial fill
    cats0, vals0, cols0 = get_plot_data(first(kinds), first(zones))

    # Create the figure
    fig = Figure(size = (900, 600))
    ax = Axis(
        fig[2, 1],
        xticks = (1:length(cats0), cats0),
        ylabel = "GWh",
        xticklabelrotation = 45,
    )

    barplot!(ax, 1:length(vals0), vals0, color = cols0, bar_labels = :y)

    # Menus
    kind_menu = Menu(fig, options = kinds, width = 150)
    zone_menu = Menu(fig, options = zones, width = 150)
    fig[1, 1] = hgrid!(Label(fig, "Kind:"), kind_menu, Label(fig, "Zone:"), zone_menu)

    # The category set changes with the selection (the `unstack` in
    # `transform_results_by_type` yields different columns), so the single `barplot!` is
    # rebuilt rather than kept behind observables. That is one plot object, not one per bar.
    function update_plot!()
        cats, vals, cols = get_plot_data(kind_menu.selection[], zone_menu.selection[])
        empty!(ax)
        ax.xticks = (1:length(cats), cats)
        barplot!(ax, 1:length(vals), vals, color = cols, bar_labels = :y)
    end

    on(kind_menu.selection) do _
        update_plot!()
    end
    on(zone_menu.selection) do _
        update_plot!()
    end

    return fig
end

"""
    plot_market_statistics(results::DataFiles, zone::String="DE"; save_path=nothing)

Create a comprehensive multi-panel visualization of market statistics for a specified zone.

Generates a 3×3 grid figure displaying time series, distribution histograms, box plots, 
and summary statistics for exchange flows, lost load events, and market prices. The 
visualization provides both temporal dynamics and statistical distributions of key 
market parameters.

# Arguments
- `results::DataFiles`: DataFiles object containing model results with EXCHANGE and ZonalMarketBalance data.
- `zone::String="DE"`: Zone identifier for which to create visualizations. Defaults to "DE".
- `save_path=nothing`: (keyword) Optional file path to save the figure (e.g., "market_stats.png"). 
  If `nothing`, the figure is not saved to disk.

# Plot Layout
The figure consists of a 3×3 grid:

**Row 1 - Time Series:**
- Exchange flow over time (MW)
- Lost Load events over time (MW)
- Market prices over time (€/MWh)

**Row 2 - Distributions:**
- Exchange histogram with mean line
- Lost Load histogram with mean line
- Price histogram with mean line

**Row 3 - Statistical Summary:**
- Box plots of all three parameters (Z-score normalized for comparability)
- Text summary panel with key statistics (mean, median, std, min, max, sum, event count)

# Returns
- `Figure`: A Makie Figure object (1800×1200 pixels) containing all visualization panels.

# Notes
- Time series use sequential indices to avoid gaps in visualization.
- Box plots are Z-score normalized to enable comparison across different scales.
- Colors are consistent across all panels: steelblue (Exchange), coral (Lost Load), 
  mediumseagreen (Price).
- If `save_path` is provided, the figure is saved and a confirmation message is printed.

# Example
```julia
julia> results = DataFiles("path/to/results")

# Display the figure interactively
julia> fig = plot_market_statistics(results, "DE")

# Save to file
julia> fig = plot_market_statistics(results, "FR"; save_path="france_market_stats.png")
Figure saved to: france_market_stats.png
```
"""
function POMATWO.plot_market_statistics(results::DataFiles, zone::String="DE"; save_path=nothing)

    # Get statistics and time series
    stats_df = get_market_statistics(results, zone)
    if isempty(stats_df)
        throw(ArgumentError("No market statistics available for zone '$zone'."))
    end
    
    # Extract time series data
    exchange_series = stats_df[stats_df.metric .== "timeseries" .&& stats_df.parameter .== "Exchange", :value][1]
    ll_series = stats_df[stats_df.metric .== "timeseries" .&& stats_df.parameter .== "Lost_Load", :value][1]
    price_series = stats_df[stats_df.metric .== "timeseries" .&& stats_df.parameter .== "Price", :value][1]
    time_series = stats_df[stats_df.metric .== "timeseries" .&& stats_df.parameter .== "Time", :value][1]
    
    # Create a DataFrame for easier handling
    timeseries_df = DataFrame(
        Time = time_series,
        Exchange = exchange_series,
        Lost_Load = ll_series,
        Price = price_series
    )
    
    # Sort by time to ensure proper plotting order
    sort!(timeseries_df, :Time)
    
    # Create a sequential index for x-axis (avoids diagonal lines from time gaps)
    time_index = 1:nrow(timeseries_df)
    
    # Create figure with 3x3 layout
    fig = Figure(size=(1800, 1200), fontsize=14)
    
    # Define colors for consistency
    colors = Dict(
        "Exchange" => :steelblue,
        "Lost_Load" => :coral,
        "Price" => :mediumseagreen
    )
    
    # Row 1: Time Series Plots
    # Exchange time series
    ax1 = Axis(fig[1, 1], 
               xlabel="Time Step", 
               ylabel="Exchange (MW)", 
               title="$(zone) Exchange Over Time")
    lines!(ax1, time_index, timeseries_df.Exchange, 
           color=colors["Exchange"], linewidth=1)
    hlines!(ax1, [0], color=:black, linestyle=:dash, linewidth=1)
    
    # Lost Load time series
    ax2 = Axis(fig[1, 2], 
               xlabel="Time Step", 
               ylabel="Lost Load (MW)", 
               title="$(zone) Lost Load Over Time")
    lines!(ax2, time_index, timeseries_df.Lost_Load, 
           color=colors["Lost_Load"], linewidth=1)
    
    # Price time series
    ax3 = Axis(fig[1, 3], 
               xlabel="Time Step", 
               ylabel="Price (€/MWh)", 
               title="$(zone) Market Price Over Time")
    lines!(ax3, time_index, timeseries_df.Price, 
           color=colors["Price"], linewidth=1)
    
    # Row 2: Distribution Plots (Histograms)
    # Exchange distribution
    ax4 = Axis(fig[2, 1], 
               xlabel="Exchange (MW)", 
               ylabel="Frequency", 
               title="Exchange Distribution")
    hist!(ax4, timeseries_df.Exchange, 
          bins=50, color=(colors["Exchange"], 0.7))
    vlines!(ax4, [mean(timeseries_df.Exchange)], 
            color=:red, linestyle=:dash, linewidth=2, label="Mean")
    axislegend(ax4, position=:rt)
    
    # Lost Load distribution
    ax5 = Axis(fig[2, 2], 
               xlabel="Lost Load (MW)", 
               ylabel="Frequency", 
               title="Lost Load Distribution")
    hist!(ax5, timeseries_df.Lost_Load, 
          bins=50, color=(colors["Lost_Load"], 0.7))
    vlines!(ax5, [mean(timeseries_df.Lost_Load)], 
            color=:red, linestyle=:dash, linewidth=2, label="Mean")
    axislegend(ax5, position=:rt)
    
    # Price distribution
    ax6 = Axis(fig[2, 3], 
               xlabel="Price (€/MWh)", 
               ylabel="Frequency", 
               title="Price Distribution")
    hist!(ax6, timeseries_df.Price, 
          bins=50, color=(colors["Price"], 0.7))
    vlines!(ax6, [mean(timeseries_df.Price)], 
            color=:red, linestyle=:dash, linewidth=2, label="Mean")
    axislegend(ax6, position=:rt)
    
    # Row 3: Box Plots and Summary Statistics
    # Box plots
    ax7 = Axis(fig[3, 1:2], 
               xlabel="Parameter", 
               ylabel="Standardized Value (Z-score)", 
               title="Statistical Summary (Box Plots) - Z-score Normalized",
               xticks=(1:3, ["Exchange", "Lost Load", "Price"]))
    
    # Normalize data for comparable visualization using Z-score normalization
    # Z-score = (x - μ) / σ, where μ is mean and σ is standard deviation
    # This transforms data to have mean=0 and std=1, making different scales comparable
    # Interpretation: values show how many standard deviations away from the mean
    zscore(values) = std(values) == 0 ? zeros(length(values)) : (values .- mean(values)) ./ std(values)
    exchange_norm = zscore(timeseries_df.Exchange)
    ll_norm = zscore(timeseries_df.Lost_Load)
    price_norm = zscore(timeseries_df.Price)
    
    boxplot!(ax7, fill(1, length(exchange_norm)), exchange_norm, 
             color=(colors["Exchange"], 0.7), width=0.5)
    boxplot!(ax7, fill(2, length(ll_norm)), ll_norm, 
             color=(colors["Lost_Load"], 0.7), width=0.5)
    boxplot!(ax7, fill(3, length(price_norm)), price_norm, 
             color=(colors["Price"], 0.7), width=0.5)
    hlines!(ax7, [0], color=:black, linestyle=:dash, linewidth=1)
    
    # Summary statistics table
    ax8 = Axis(fig[3, 3], 
               title="Key Statistics Summary")
    hidedecorations!(ax8)
    hidespines!(ax8)
    
    # Create text summary
    exchange_stats = filter(row -> row.parameter == "Exchange", stats_df)
    ll_stats = filter(row -> row.parameter == "Lost_Load", stats_df)
    price_stats = filter(row -> row.parameter == "Price", stats_df)
    stat_value(df, metric) = df[df.metric .== metric, :value][1]
    exchange_text = """
    Exchange
    Mean: $(round(stat_value(exchange_stats, "mean"), digits=2)) MW
    Median: $(round(stat_value(exchange_stats, "median"), digits=2)) MW
    Std: $(round(stat_value(exchange_stats, "std"), digits=2)) MW
    Sum: $(round(stat_value(exchange_stats, "sum") / 1000, digits=2)) GWh
    """
    ll_text = """
    Lost Load
    Mean: $(round(stat_value(ll_stats, "mean"), digits=2)) MW
    Max: $(round(stat_value(ll_stats, "max"), digits=2)) MW
    Sum: $(round(stat_value(ll_stats, "sum") / 1000, digits=2)) GWh
    Events: $(Int(stat_value(ll_stats, "count_positive")))
    """
    price_text = """
    Price
    Mean: $(round(stat_value(price_stats, "mean"), digits=2)) EUR/MWh
    Median: $(round(stat_value(price_stats, "median"), digits=2)) EUR/MWh
    Min: $(round(stat_value(price_stats, "min"), digits=2)) EUR/MWh
    Max: $(round(stat_value(price_stats, "max"), digits=2)) EUR/MWh
    """

    text!(ax8, 0.02, 0.95, text=exchange_text, align=(:left, :top), fontsize=10, space=:relative)
    text!(ax8, 0.36, 0.95, text=ll_text, align=(:left, :top), fontsize=10, space=:relative)
    text!(ax8, 0.68, 0.95, text=price_text, align=(:left, :top), fontsize=10, space=:relative)
    
    # Add overall title
    Label(fig[0, :], "Market Statistics Overview - Zone: $(zone)", 
          fontsize=20, font=:bold)
    
    # Save if path provided
    if !isnothing(save_path)
        save(save_path, fig)
        println("Figure saved to: $(save_path)")
    end
    
    return fig
end
