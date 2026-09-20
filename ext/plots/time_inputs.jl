# ---------------------------------------------------------------------------------------
# Typed time selection for the interactive figures.
#
# The interactive plots used to select their timestep (or time window) with a Makie
# `Slider`/`IntervalSlider`. That is fine for a 24 h test case and unusable for a year:
# one horizontal pixel is several hours, so a specific timestep cannot be hit at all and
# a window cannot be reproduced between two sessions.
#
# These helpers replace both with a `Textbox` the user types the numbers into. The parse
# is shared so every figure accepts the same spellings, and the entered value is snapped
# to the timesteps that actually exist in the data — the same guarantee the slider gave
# for free by taking `range = times`.
#
# Accepted input (`_parse_time_bounds`):
#
#   "12"            a single timestep
#   "12-40"         a window, inclusive; also 12:40, 12..40, 12,40, "12 40"
#   "40-12"         reversed bounds are sorted, not rejected
#   "" / "all"      the full horizon
#
# Anything else fails the `Textbox` validator, so the box turns red and the previous
# selection stays live — an invalid entry can never blank a figure.
# ---------------------------------------------------------------------------------------

const _TIME_POINT_RE = r"^\d+$"
# The separator alternatives are ordered longest-first so that ".." is not consumed as
# a single "." (which is not a separator at all, but the `..` case must win over `.`).
const _TIME_RANGE_RE = r"^(\d+)\s*(?:\.\.\.?|::?|--?|–|—|,|;|\s)\s*(\d+)$"
const _TIME_ALL_WORDS = ("all", "full", "*", ":")

"""
    _parse_time_bounds(str, times) -> Union{Tuple{Int,Int},Nothing}

Parse a user-typed timestep or time window and snap it onto `times` (sorted, ascending).

Returns the first and last element of `times` inside the requested span, so the returned
pair is always a pair of timesteps that exist in the data — exactly what an
`IntervalSlider` built over `times` would have produced. Returns `nothing` for anything
unparseable, and for a span that contains no timestep at all (e.g. `"5"` on a horizon that
jumps from 4 to 10); callers use that as the `Textbox` validator, so such an entry is
refused at the box rather than silently redrawing nothing.
"""
function _parse_time_bounds(str::AbstractString, times::AbstractVector{<:Integer})
    isempty(times) && return nothing
    s = strip(str)
    (isempty(s) || lowercase(s) in _TIME_ALL_WORDS) &&
        return (Int(first(times)), Int(last(times)))

    lo = hi = 0
    if occursin(_TIME_POINT_RE, s)
        lo = hi = parse(Int, s)
    else
        m = match(_TIME_RANGE_RE, s)
        m === nothing && return nothing
        lo, hi = parse(Int, m.captures[1]), parse(Int, m.captures[2])
        lo > hi && ((lo, hi) = (hi, lo))
    end

    i = searchsortedfirst(times, lo)
    j = searchsortedlast(times, hi)
    i > j && return nothing
    return (Int(times[i]), Int(times[j]))
end

"""
    _parse_timestep(str, times) -> Union{Int,Nothing}

As [`_parse_time_bounds`](@ref), but for the figures that show one timestep at a time: a
window spanning more than one existing timestep is rejected rather than silently
truncated to its first hour.
"""
function _parse_timestep(str::AbstractString, times::AbstractVector{<:Integer})
    b = _parse_time_bounds(str, times)
    b === nothing && return nothing
    b[1] == b[2] || return nothing
    return b[1]
end

_fmt_time_bounds(b::Tuple{Int,Int}) = b[1] == b[2] ? string(b[1]) : "$(b[1])-$(b[2])"

"""
    _time_hint(times; ranges = true) -> String

The "what may I type here" label: the horizon the box accepts, a gap warning when the
horizon is not contiguous (a split run), where not every number in between is a valid
entry, and an example. `ranges = false` for the single-timestep boxes, which refuse
`lo-hi` and must not advertise it.
"""
function _time_hint(times::AbstractVector{<:Integer}; ranges::Bool = true)
    isempty(times) && return "no timesteps"
    lo, hi = Int(first(times)), Int(last(times))
    gapped = length(times) != hi - lo + 1
    return "t ∈ [$lo, $hi]" * (gapped ? " (with gaps)" : "") *
           "  —  e.g. $lo" * (ranges ? " or $lo-$hi" : "")
end

"""
    _bind_time_box!(tb, times, value, parse_fn, fmt_fn)

Wire a `Textbox` to the `Observable` a figure redraws on.

On submit the entry is parsed, snapped and written back into the box in canonical form, so
a snapped or reordered entry (`"40-12"`, or a `"5"` that landed on hour 6) shows what the
figure is actually drawing. That write-back re-enters this same listener, hence the
`syncing` guard — without it the two observables would ping-pong forever.

`displayed_string` is synced even when `stored_string` already holds the canonical form:
typing into the box sets the displayed text first and the stored text on submit, but a
programmatic `tb.stored_string[] = …` sets only the latter, and the box would go on showing
the previous entry while the figure drew the new one.
"""
function _bind_time_box!(tb::Textbox, times, value::Observable, parse_fn, fmt_fn)
    syncing = Ref(false)
    on(tb.stored_string) do s
        syncing[] && return nothing
        v = parse_fn(s === nothing ? "" : s, times)
        # Unreachable through the UI (the validator refuses invalid entries), but
        # `stored_string` is a public Observable and may be assigned programmatically.
        v === nothing && return nothing
        canon = fmt_fn(v)
        if s != canon || tb.displayed_string[] != canon
            syncing[] = true
            try
                tb.displayed_string[] == canon || (tb.displayed_string[] = canon)
                s == canon || (tb.stored_string[] = canon)
            finally
                syncing[] = false
            end
        end
        value[] = v
        return nothing
    end
    return tb
end

"""
    _entry_row(fig, label, tb, hint) -> GridLayout

`label — [box] — hint` on one line, sized so that it never dictates the width of the column
it is placed in.

`tellwidth = false` is the load-bearing part. These rows sit under a plot (`fig[5, 1]`,
`fig[2, 1]`), and a nested `GridLayout` reports a width demand by default — which pins the
whole column, plot included, to the width of this one row. A `Textbox` is a fixed width, so
the demand is small and constant: it squeezed a 1900 px figure's axis down to 296 px. The
`SliderGrid`/`IntervalSlider` these rows replaced did not have the problem, because a
slider stretches to whatever width it is given.
"""
function _entry_row(fig, label::AbstractString, tb::Textbox, hint::AbstractString)
    return hgrid!(
        Label(fig, label; fontsize = 14, halign = :right),
        tb,
        Label(fig, hint; fontsize = 12, color = :gray30, halign = :left);
        tellheight = true,
        tellwidth = false,
    )
end

"""
    _time_range_row(fig, times; startvalues, label, width)
        -> (GridLayout, Observable{Tuple{Int,Int}})

A labelled entry field for a time window, plus the observable carrying `(lo, hi)`.

Drop-in replacement for `IntervalSlider(fig[r, c], range = times, startvalues = …)`: place
the returned grid (`fig[r, c] = row`) and listen on the observable where the slider's
`.interval` was listened on. Both bounds are inclusive and both are guaranteed to be
elements of `times`.
"""
function _time_range_row(fig, times::AbstractVector{<:Integer};
                         startvalues = (first(times), last(times)),
                         label = "Time window",
                         width = 130)
    init = (Int(startvalues[1]), Int(startvalues[2]))
    value = Observable(init)
    str = _fmt_time_bounds(init)
    tb = Textbox(fig;
                 width = width,
                 placeholder = "t or t1-t2",
                 stored_string = str,
                 displayed_string = str,
                 reset_on_defocus = true,
                 validator = s -> _parse_time_bounds(s, times) !== nothing)
    _bind_time_box!(tb, times, value, _parse_time_bounds, _fmt_time_bounds)
    row = _entry_row(fig, label, tb, _time_hint(times))
    return row, value
end

"""
    _timestep_row(fig, times; startvalue, label, width) -> (GridLayout, Observable{Int})

A labelled entry field for a single timestep, plus the observable carrying it.

Drop-in replacement for a one-slider `SliderGrid` over `times`: place the returned grid and
listen where the slider's `.value` was listened on. The observable is `Int`, so callers
that wrapped the slider value in `Int(…)` no longer need to.
"""
function _timestep_row(fig, times::AbstractVector{<:Integer};
                       startvalue = first(times),
                       label = "Timestep",
                       width = 100)
    init = Int(startvalue)
    value = Observable(init)
    str = string(init)
    tb = Textbox(fig;
                 width = width,
                 placeholder = "t",
                 stored_string = str,
                 displayed_string = str,
                 reset_on_defocus = true,
                 validator = s -> _parse_timestep(s, times) !== nothing)
    _bind_time_box!(tb, times, value, _parse_timestep, string)
    row = _entry_row(fig, label, tb, _time_hint(times; ranges = false))
    return row, value
end
