# ============================================================================
# Reference-day matching for the D2CF-style FBMC basecase
# ----------------------------------------------------------------------------
# Stage 1 of the reference-day basecase methodology (see utils/refday_basecase.jl):
# partition the time axis into clusters (days), build per-cluster generation
# profiles, and match every target cluster to its most similar predecessor
# within a lookback window. Matching can be scoped: globally (one reference day
# for the whole system), per bidding zone, or per custom TSO control area —
# mimicking how each TSO builds the D2CF for its own area before merging.
# ============================================================================

# ---------------------------------------------------------------------------
# Matching scope: a partition of the node set.
# (Named *MatchScope to avoid clashing with the BalanceScope subtype ZonalScope.)
# ---------------------------------------------------------------------------

"""
    MatchScope

Abstract supertype for the node partition over which reference-day matching is
performed. Each group independently selects its own reference day.

# Subtypes
- [`GlobalMatchScope`](@ref): one group spanning the whole system.
- [`ZonalMatchScope`](@ref): one group per bidding zone.
- [`AreaMatchScope`](@ref): custom TSO control areas via a node → area map.
"""
abstract type MatchScope end

"One group spanning the whole system (global matching, the default)."
struct GlobalMatchScope <: MatchScope end

"One group per bidding zone (per-TSO matching at bidding-zone granularity)."
struct ZonalMatchScope <: MatchScope end

"""
    AreaMatchScope(node2area::Dict{String,String})

Custom TSO control areas: explicit node → area assignment. Lets several bidding
zones form one control area, or one zone span several areas.
"""
struct AreaMatchScope <: MatchScope
    node2area::Dict{String,String}
end

"Node partition for a scope: Dict(group_label => sorted node vector)."
node_groups(::GlobalMatchScope, params::Parameters) =
    Dict("ALL" => sort(collect(params.sets.N)))
node_groups(::ZonalMatchScope, params::Parameters) =
    Dict(z => sort(collect(v)) for (z, v) in params.nodes_in_zone)
function node_groups(s::AreaMatchScope, params::Parameters)
    groups = Dict{String,Vector{String}}()
    for n in params.sets.N
        haskey(s.node2area, n) || error("AreaMatchScope: node $n has no area assignment")
        push!(get!(groups, s.node2area[n], String[]), n)
    end
    foreach(sort!, values(groups))
    return groups
end

# ---------------------------------------------------------------------------
# DataFrame preparation helpers
# ---------------------------------------------------------------------------

"Assign each Time step to a contiguous cluster of `cluster_size` steps (out-of-place)."
function add_time_cluster(df, cluster_size::Int = 24)
    df = copy(df)
    df[!, :Cluster] = ceil.(Int, df[!, :Time] ./ cluster_size)
    return df
end

"Assign each Time step to a contiguous cluster of `cluster_size` steps (in-place)."
function add_time_cluster!(df, cluster_size::Int = 24)
    df[!, :Cluster] = ceil.(Int, df[!, :Time] ./ cluster_size)
    return df
end

"""
    filter_powerplants(df; plant_indicies, type_in_name, type_in_planttype)

Filter a plant-indexed result table by explicit plant list, substring of the
plant name, or substring of the plant type (first non-`nothing` filter wins).
"""
function filter_powerplants(df; plant_indicies::Union{Vector{String},Nothing} = nothing,
                            type_in_name::Union{Vector{String},Nothing} = nothing,
                            type_in_planttype::Union{Vector{String},Nothing} = nothing)
    df = copy(df)
    if !isnothing(plant_indicies)
        df = filter(row -> row.index in plant_indicies, df)
    elseif !isnothing(type_in_name)
        df = filter(row -> any(t -> occursin(t, row.index), type_in_name), df)
    elseif !isnothing(type_in_planttype)
        df = filter(row -> any(t -> occursin(t, row.plant_type), type_in_planttype), df)
    end
    return df
end

"In-place variant of [`filter_powerplants`](@ref)."
function filter_powerplants!(df; plant_indicies::Union{Vector{String},Nothing} = nothing,
                             type_in_name::Union{Vector{String},Nothing} = nothing,
                             type_in_planttype::Union{Vector{String},Nothing} = nothing)
    if !isnothing(plant_indicies)
        filter!(row -> row.index in plant_indicies, df)
    elseif !isnothing(type_in_name)
        filter!(row -> any(t -> occursin(t, row.index), type_in_name), df)
    elseif !isnothing(type_in_planttype)
        filter!(row -> any(t -> occursin(t, row.plant_type), type_in_planttype), df)
    end
    return df
end

"Add `:Weekday` / `:IsWeekend` columns from the cluster index anchored at `start_date` (out-of-place)."
function add_weekday(df, start_date::Date)
    df = copy(df)
    dates = start_date .+ Day.(df[!, :Cluster] .- 1)
    df[!, :Weekday] = dayname.(dates)
    df[!, :IsWeekend] = dayofweek.(dates) .>= 6
    return df
end

"Add `:Weekday` / `:IsWeekend` columns from the cluster index anchored at `start_date` (in-place)."
function add_weekday!(df, start_date::Date)
    dates = start_date .+ Day.(df[!, :Cluster] .- 1)
    df[!, :Weekday] = dayname.(dates)
    df[!, :IsWeekend] = dayofweek.(dates) .>= 6
    return df
end

"Add a `:plant_type` column from `params.plant_type` (out-of-place)."
function add_planttype(df, params::Parameters)
    df = copy(df)
    df[!, :plant_type] = [params.plant_type[row.index] for row in eachrow(df)]
    return df
end

"Add a `:plant_type` column from `params.plant_type` (in-place)."
function add_planttype!(df, params::Parameters)
    df[!, :plant_type] = [params.plant_type[row.index] for row in eachrow(df)]
    return df
end

# NOTE: named add_nodecol! (not add_node!) — Plasmo exports add_node!/add_node
# for OptiGraphs and POMATWO uses them; defining add_node! here would shadow
# the import and break model building.
"Add a `:node` column from `params.plant2node` (in-place)."
function add_nodecol!(df, params::Parameters)
    df[!, :node] = [params.plant2node[row.index] for row in eachrow(df)]
    return df
end

"Add a `:node` column from `params.plant2node` (out-of-place)."
function add_nodecol(df, params::Parameters)
    df = copy(df)
    df[!, :node] = [params.plant2node[row.index] for row in eachrow(df)]
    return df
end

# ---------------------------------------------------------------------------
# Profiles and distances
# ---------------------------------------------------------------------------

"""Precompute per-Cluster aggregated profiles (per statistic in `valuemethods`)."""
function build_cluster_profiles(df::DataFrame, keycols, valuecols, valuemethods)
    agg = DataFrames.combine(
        groupby(df, [:Cluster, keycols...]),
        [c .=> valuemethods for c in valuecols]...
    )
    return Dict(sdf.Cluster[1] => DataFrame(sdf) for sdf in groupby(agg, :Cluster))
end

"""
Weighted L1 distance between two pre-aggregated cluster profile slices.
Missing keys in the outer join count as zero. Weights are looked up per
value/statistic column, optionally refined per plant type (see [`refday_weights`](@ref)).
"""
function profile_distance(p1, p2, valuecols, weights, valuemethods)
    keycol_names = names(p1)[2:end - length(valuecols) * length(valuemethods)]
    joined = outerjoin(DataFrame(p1), DataFrame(p2), on = keycol_names, makeunique = true)
    has_plant_type = "plant_type" in keycol_names

    dist = 0.0
    for vcol in valuecols
        for method in valuemethods
            col_sym  = Symbol(string(vcol) * "_" * string(nameof(method)))
            col_sym2 = Symbol(string(col_sym) * "_1")
            x = coalesce.(joined[!, col_sym],  0.0)
            y = coalesce.(joined[!, col_sym2], 0.0)
            for i in 1:nrow(joined)
                pt = has_plant_type ? joined[i, :plant_type] : ""
                dist += refday_weights(weights, col_sym, pt) * abs(x[i] - y[i])
            end
        end
    end
    return dist
end

"""
    refday_weights(weights, col, plant_type)

Distance-weight lookup for [`profile_distance`](@ref); default 1.0.
- `Dict{Symbol,Float64}`: weight per value/statistic column.
- `Dict{Tuple{Symbol,String},Float64}`: weight per (column, plant type) pair.
"""
refday_weights(weights::AbstractDict{Symbol}, col, pt::String = "") = get(weights, Symbol(col), 1.0)
refday_weights(weights::AbstractDict{<:Tuple{Symbol,String}}, col, pt::String) = get(weights, (Symbol(col), pt), 1.0)

# ---------------------------------------------------------------------------
# Cluster matching
# ---------------------------------------------------------------------------

"""
    match_by_cluster(df; lookback, keycols, valuecols, value_methods, weights, exact_weekend)

Match every cluster to its most similar predecessor within `lookback` clusters
(cyclically wrapped), then map each Time step of the target cluster to the Time
step at the same intra-cluster position of the matched cluster.

- `exact_weekend = true` restricts candidates to the same weekend/workday type;
  if that empties the candidate set (isolated weekend/holiday), the restriction
  is relaxed with a warning so no timestep is ever dropped.
- Ties are broken by circular temporal proximity.

Returns a DataFrame with columns:
`target_cluster, matched_cluster, target_time, matched_time, cluster_distance`.
"""
function match_by_cluster(
    df::DataFrame;
    lookback::Int,
    keycols = [:node, :plant_type],
    valuecols = [:GEN],
    value_methods = [median, maximum],
    weights = Dict(:GEN => 1.0),
    exact_weekend::Bool = true,
)
    clusters = sort(unique(df.Cluster))
    n_clusters = length(clusters)
    cluster_profiles = build_cluster_profiles(df, keycols, valuecols, value_methods)
    cluster_idx = Dict(c => i for (i, c) in enumerate(clusters))
    circ_dist(a, b) = min(abs(cluster_idx[a] - cluster_idx[b]),
                          n_clusters - abs(cluster_idx[a] - cluster_idx[b]))

    cluster_times = Dict(
        sdf.Cluster[1] => sort(unique(sdf.Time))
        for sdf in groupby(df, :Cluster)
    )

    cluster_weekend = Dict(
        row.Cluster => row.IsWeekend
        for row in eachrow(DataFrames.combine(groupby(df, :Cluster), :IsWeekend => first => :IsWeekend))
    )

    results = DataFrame(
        target_cluster  = Int[],
        matched_cluster = Int[],
        target_time     = Int[],
        matched_time    = Int[],
        cluster_distance = Float64[],
    )

    for (cl_idx, cl) in enumerate(clusters)
        raw_candidates = [clusters[mod1(cl_idx - i, n_clusters)] for i in 1:lookback]
        isempty(raw_candidates) && continue

        candidates = copy(raw_candidates)
        if exact_weekend
            filter!(c -> cluster_weekend[c] == cluster_weekend[cl], candidates)
            # Fallback: if no same weekend/workday candidate exists in the lookback
            # window (e.g. an isolated weekend or holiday day), relax the constraint
            # so this cluster still gets a reference and no timesteps are dropped.
            if isempty(candidates)
                @warn "Cluster $cl: no same weekend/workday candidate in lookback=$lookback; relaxing exact_weekend to keep full coverage."
                candidates = raw_candidates
            end
        end
        isempty(candidates) && continue

        dists = [profile_distance(cluster_profiles[cl], cluster_profiles[c], valuecols, weights, value_methods) for c in candidates]
        min_dist = minimum(dists)
        tied = [c for (c, d) in zip(candidates, dists) if d == min_dist]
        best_cl = length(tied) == 1 ? tied[1] : tied[argmin(circ_dist.(cl, tied))]
        best_dist = min_dist

        t_times = cluster_times[cl]
        m_times = cluster_times[best_cl]
        if length(t_times) != length(m_times)
            @warn "Cluster $cl ($(length(t_times)) steps) and cluster $best_cl ($(length(m_times)) steps) differ in length — truncating to shorter."
        end
        for (tt, mt) in zip(t_times, m_times)
            push!(results, (cl, best_cl, tt, mt, best_dist))
        end
    end

    return results
end

# ---------------------------------------------------------------------------
# Scoped matching (per-TSO)
# ---------------------------------------------------------------------------

"""
    match_by_scope(gen_df, scope, params; matchkwargs...) -> DataFrame

Run [`match_by_cluster`](@ref) independently for every node group of `scope`
(rows of `gen_df` filtered by the `:node` column per group). Returns one
combined match table with an extra `:group` column. `GlobalMatchScope`
reproduces plain global matching (group label "ALL").
"""
function match_by_scope(gen_df, scope::MatchScope, params::Parameters; matchkwargs...)
    groups = node_groups(scope, params)
    parts = DataFrame[]
    for (g, gnodes) in groups
        gset = Set(gnodes)
        sub = filter(:node => in(gset), gen_df)
        if isempty(sub)
            @warn "match_by_scope: group $g has no rows in gen_df (no matchable plants); relying on fallback."
            continue
        end
        m = match_by_cluster(sub; matchkwargs...)
        m[!, :group] .= g
        push!(parts, m)
    end
    return isempty(parts) ? DataFrame() : vcat(parts...)
end

"""
    resolve_group_times(scoped_matches, scope, params, tgt_times; fallback_matches)
        -> (groupmap::DataFrame, skipped::Vector{Int})

Group-level match resolution: one `groupmap` row (`group, target_time,
matched_time, fallback::Bool`) per resolved (group, target hour), where
`fallback` marks hours the group borrowed from the global `fallback_matches`
instead of its own scoped match. Target hours where any group stays unresolved
are returned in `skipped` and contribute no rows. A `scoped_matches` table
without a `:group` column is treated as one global group.
"""
function resolve_group_times(scoped_matches, scope::MatchScope, params::Parameters, tgt_times;
                             fallback_matches = nothing)
    groups = node_groups(scope, params)

    bygroup = Dict{Tuple{String,Int},Int}()
    if !isempty(scoped_matches) && ("group" in names(scoped_matches))
        for r in eachrow(unique(scoped_matches[:, [:group, :target_time, :matched_time]]))
            bygroup[(r.group, r.target_time)] = r.matched_time
        end
    elseif !isempty(scoped_matches)
        for r in eachrow(unique(scoped_matches[:, [:target_time, :matched_time]]))
            for g in keys(groups)
                bygroup[(g, r.target_time)] = r.matched_time
            end
        end
    end

    fb = Dict{Int,Int}()
    if fallback_matches !== nothing && !isempty(fallback_matches)
        for r in eachrow(unique(fallback_matches[:, [:target_time, :matched_time]]))
            fb[r.target_time] = r.matched_time
        end
    end

    groupmap = DataFrame(group = String[], target_time = Int[],
                         matched_time = Int[], fallback = Bool[])
    skipped = Int[]
    for tt in tgt_times
        rows = Tuple{String,Int,Int,Bool}[]
        ok = true
        for g in keys(groups)
            scoped = haskey(bygroup, (g, tt))
            mt = scoped ? bygroup[(g, tt)] : get(fb, tt, nothing)
            if mt === nothing
                ok = false
                break
            end
            push!(rows, (g, tt, mt, !scoped))
        end
        if ok
            for r in rows
                push!(groupmap, r)
            end
        else
            push!(skipped, tt)
        end
    end
    isempty(skipped) ||
        @warn "resolve_group_times: $(length(skipped)) target hour(s) unresolved in at least one group and no fallback available — skipped." skipped
    return groupmap, sort(skipped)
end

"""
    resolve_ref_times(scoped_matches, scope, params, tgt_times; fallback_matches)
        -> (refmap::Dict{Tuple{String,Int},Int}, skipped::Vector{Int})

Resolve, for every (node, target_time), the reference time to borrow from: the
node's group match if available, else the global `fallback_matches` entry for
that hour. Target hours where any node stays unresolved are returned in
`skipped`. Node-level expansion of [`resolve_group_times`](@ref).
"""
function resolve_ref_times(scoped_matches, scope::MatchScope, params::Parameters, tgt_times;
                           fallback_matches = nothing)
    groupmap, skipped = resolve_group_times(scoped_matches, scope, params, tgt_times;
                                            fallback_matches = fallback_matches)
    refmap = _expand_group_times(groupmap, node_groups(scope, params))
    return refmap, skipped
end

"Expand a group-level match table to the per-(node, target_time) refmap."
function _expand_group_times(groupmap, groups::AbstractDict)
    refmap = Dict{Tuple{String,Int},Int}()
    for r in eachrow(groupmap), n in groups[r.group]
        refmap[(n, r.target_time)] = r.matched_time
    end
    return refmap
end
