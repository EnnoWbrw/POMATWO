const DEFAULT_PLOT_COLORS = Dict(
    "exchange" => "#9526b7",
    "LL" => "#ff0000",
    "CU" => "#ff7373",
    "Net injection" => "#b2a1d5",
)

_time_values(time_horizon) = collect(time_horizon)
_time_set(time_horizon) = Set(_time_values(time_horizon))
_plot_colors(results) = merge(copy(results.params.colors), DEFAULT_PLOT_COLORS)
_series_values(df, col) = hasproperty(df, col) ? collect(getproperty(df, col)) : Float64[]
_color_for(colors, type) = get(colors, type, :gray60)

function _value_at(profile, t)
    try
        value = profile[t]
        return ismissing(value) ? 0.0 : Float64(value)
    catch
        return 0.0
    end
end

function _load_at(params, zone, t)
    nodes = get(params.nodes_in_zone, zone, String[])
    isempty(nodes) && return 0.0
    return sum(_value_at(params.nodal_load[n], t) / 1e3 for n in nodes if haskey(params.nodal_load, n); init = 0.0)
end

function _empty_dispatch_cache(time_values)
    return (
        time = time_values,
        pos_types = String[],
        pos_mat = zeros(Float64, length(time_values), 0),
        neg_types = String[],
        neg_mat = zeros(Float64, length(time_values), 0),
    )
end

function _matrix_for_types(df, time_values, types)
    mat = zeros(Float64, length(time_values), length(types))
    type_pos = Dict(type => i for (i, type) in enumerate(types))
    time_pos = Dict(t => i for (i, t) in enumerate(time_values))
    for row in eachrow(df)
        ti = get(time_pos, row.Time, nothing)
        ci = get(type_pos, row.plant_type, nothing)
        if ti !== nothing && ci !== nothing
            mat[ti, ci] += row.value
        end
    end
    return mat
end

function _dispatch_cache(df, time_values)
    isempty(df) && return _empty_dispatch_cache(time_values)

    pos_df = filter(:value => >=(0), df)
    neg_df = filter(:value => <(0), df)
    pos_types = sort(unique(String.(pos_df.plant_type)))
    neg_types = sort(unique(String.(neg_df.plant_type)))
    pos_mat = cumsum(_matrix_for_types(pos_df, time_values, pos_types), dims = 2)
    neg_mat = cumsum(_matrix_for_types(neg_df, time_values, neg_types), dims = 2)

    return (
        time = time_values,
        pos_types = pos_types,
        pos_mat = pos_mat,
        neg_types = neg_types,
        neg_mat = neg_mat,
    )
end

function _with_plant_metadata(df, params, time_set)
    isempty(df) && return DataFrame()
    filtered = filter(:Time => t -> t in time_set, df)
    isempty(filtered) && return DataFrame()
    enriched = transform(
        filtered,
        :index => ByRow(i -> get(params.plant2zone, i, missing)) => :zone,
        :index => ByRow(i -> get(params.plant_type, i, "unknown")) => :plant_type,
    )
    dropmissing!(enriched, :zone)
    return enriched
end

function _aggregate_by_zone_type(df, value_col, scalefactor; sign = 1.0)
    isempty(df) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    grouped = groupby(df, [:zone, :Time, :plant_type])
    return combine(grouped, value_col => (x -> sign * scalefactor * sum(x)) => :value)
end

function _aggregate_exchange(results, scalefactor, time_set)
    isempty(results.EXCHANGE) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    df = filter(:Time => t -> t in time_set, results.EXCHANGE)
    isempty(df) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    transform!(df, :index => :zone)
    df.plant_type .= "exchange"
    grouped = groupby(df, [:zone, :Time, :plant_type])
    return combine(grouped, :EXCHANGE => (x -> scalefactor * sum(x)) => :value)
end

function _aggregate_zonal_balance(results, scalefactor, time_set, col, plant_type; sign = 1.0)
    isempty(results.ZonalMarketBalance) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    df = filter(:Time => t -> t in time_set, results.ZonalMarketBalance)
    isempty(df) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    transform!(df, :Zone => :zone)
    df.plant_type .= plant_type
    grouped = groupby(df, [:zone, :Time, :plant_type])
    return combine(grouped, col => (x -> sign * scalefactor * sum(x)) => :value)
end

function _aggregate_node_table_by_zone(df, params, time_set, index_col, value_col, plant_type, scalefactor; sign = 1.0)
    isempty(df) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    node2zone = params.node2zone
    filtered = filter(:Time => t -> t in time_set, df)
    isempty(filtered) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    enriched = transform(filtered, index_col => ByRow(n -> get(node2zone, n, missing)) => :zone)
    dropmissing!(enriched, :zone)
    isempty(enriched) && return DataFrame(zone = String[], Time = Int[], plant_type = String[], value = Float64[])
    enriched.plant_type .= plant_type
    grouped = groupby(enriched, [:zone, :Time, :plant_type])
    return combine(grouped, value_col => (x -> sign * scalefactor * sum(x)) => :value)
end

function _price_by_zone(results, time_set)
    price_by_zone = Dict{String,DataFrame}()
    for z in results.params.sets.Z
        price_by_zone[z] = @chain results.ZonalMarketBalance begin
            @rsubset :Time in time_set
            @rsubset :Zone == z
            @orderby :Time
        end
    end
    return price_by_zone
end

function _load_by_zone(results, time_values)
    return Dict(
        z => DataFrame(Time = time_values, orig_load = [_load_at(results.params, z, t) for t in time_values])
        for z in results.params.sets.Z
    )
end

function _dispatch_by_zone(results, merged, time_values)
    dispatch_by_zone = Dict{String,NamedTuple}()
    grouped = isempty(merged) ? nothing : groupby(merged, :zone)
    for z in results.params.sets.Z
        zone_df = grouped === nothing || !haskey(grouped, (z,)) ? DataFrame() : grouped[(z,)]
        dispatch_by_zone[z] = _dispatch_cache(zone_df, time_values)
    end
    return dispatch_by_zone
end

function prepare_disp_plot_data(results, scalefactor, time_horizon)
    time_values = _time_values(time_horizon)
    time_set = Set(time_values)
    gen = _with_plant_metadata(results.GEN, results.params, time_set)
    charge = _with_plant_metadata(results.CHARGE, results.params, time_set)

    parts = [
        _aggregate_by_zone_type(gen, :GEN, scalefactor),
        _aggregate_by_zone_type(charge, :CHARGE, scalefactor; sign = -1.0),
        _aggregate_zonal_balance(results, scalefactor, time_set, :LL, "LL"),
        _aggregate_by_zone_type(gen, :CU, scalefactor; sign = -1.0),
        _aggregate_exchange(results, scalefactor, time_set),
    ]
    merged = reduce(vcat, parts, cols = :union)

    return _price_by_zone(results, time_set), _load_by_zone(results, time_values), _dispatch_by_zone(results, merged, time_values)
end

function prepare_redisp_plot_data(results, scalefactor, time_horizon)
    time_values = _time_values(time_horizon)
    time_set = Set(time_values)
    redisp = _with_plant_metadata(results.REDISP, results.params, time_set)

    parts = [
        _aggregate_by_zone_type(redisp, :GEN_REDISP, scalefactor),
        _aggregate_by_zone_type(redisp, :CHARGE_REDISP, scalefactor; sign = -1.0),
        _aggregate_node_table_by_zone(results.NETINPUT, results.params, time_set, :index, :NETINPUT, "Net injection", scalefactor),
        _aggregate_node_table_by_zone(results.NodalMarketRedispBalance, results.params, time_set, :Node, :LL, "LL", scalefactor),
        _aggregate_by_zone_type(redisp, :CU_REDISP, scalefactor; sign = -1.0),
    ]
    merged = reduce(vcat, parts, cols = :union)

    return _price_by_zone(results, time_set), _load_by_zone(results, time_values), _dispatch_by_zone(results, merged, time_values)
end

# Function to update the plot based on the observables
function update_plot!(fig, ax, ax2, disp, load, price, colors)
    plot_time = disp.time
    empty!(ax)
    empty!(ax2)

    # Clear previous legends
    for leg in fig.content
        if leg isa Legend
            delete!(leg)
        end
    end

    handles = []
    labels = []

    for i = 1:size(disp.pos_mat, 2)
        prev = i == 1 ? 0 : disp.pos_mat[:, i-1]
        type = disp.pos_types[i]
        color = _color_for(colors, type)
        band = band!(ax, plot_time, prev, disp.pos_mat[:, i], color = color, label = type)
        push!(handles, band)
        push!(labels, type)
    end

    for i = 1:size(disp.neg_mat, 2)
        prev = i == 1 ? 0 : disp.neg_mat[:, i-1]
        type = disp.neg_types[i]
        color = _color_for(colors, type)
        band!(ax, plot_time, prev, disp.neg_mat[:, i], color = color)
    end

    load_line = lines!(
        ax,
        load.Time,
        load.orig_load,
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles, load_line)
    push!(labels, "Load")

    price_line = lines!(
        ax2,
        price.Time,
        _series_values(price, :MarketBalance),
        color = :black,
        linestyle = :dot,
        label = "price",
    )
    push!(handles, price_line)
    push!(labels, "Day-Ahead Price")

    autolimits!(ax)
    autolimits!(ax2)

    # Create combined legend
    # axislegend(ax, handles, labels,  position=:ct, orientation=:horizontal, nbanks=2,tellwidth=false)

    Legend(fig[2, 2], handles, labels, "Legend", nbanks = 2, position = :ct)
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
    prices_by_zone, load_by_zone, dispatch_by_zone = data_prep(results, scalefactor, time_horizon)
    fig = Figure(size = (1200, 800))

    # Dropdown menu for selecting a zone
    zone_menu = Menu(fig, options = results.params.sets.Z, fontsize = 30)

    fig[1, 2] = vgrid!(Label(fig, "Market Zone", fontsize = 30, width = 400), zone_menu)

    ax = Axis(fig[1:2, 1], xlabel = "Hour", ylabel = "GW", title = "Generation")

    ax2 = Axis(fig[1:2, 1], ylabel = "EUR/MWh", yaxisposition = :right)

    hidexdecorations!(ax2)
    linkxaxes!(ax, ax2)

    function redraw!(selected)
        update_plot!(fig, ax, ax2, dispatch_by_zone[selected], load_by_zone[selected], prices_by_zone[selected], colors)
    end

    redraw!(results.params.sets.Z[1])
    on(zone_menu.selection) do selected
        redraw!(selected)
    end

    return fig
end
# Function to update the plot based on the observables
function update_plot_comb!(
    fig,
    ax,
    ax2,
    ax3,
    ax4,
    disp,
    load,
    price,
    disp_d,
    load_d,
    price_d,
    colors,
)
    empty!(ax)
    empty!(ax2)
    empty!(ax3)
    empty!(ax4)
    # Clear previous legends
    for leg in fig.content
        if leg isa Legend
            delete!(leg)
        end
    end

    handles = []
    labels = []

    handles_d = []
    labels_d = []

    for i = 1:size(disp.pos_mat, 2)
        prev = i == 1 ? 0 : disp.pos_mat[:, i-1]
        type = disp.pos_types[i]
        color = _color_for(colors, type)
        band = band!(ax, disp.time, prev, disp.pos_mat[:, i], color = color, label = type)
        push!(handles, band)
        push!(labels, type)
    end

    for i = 1:size(disp.neg_mat, 2)
        prev = i == 1 ? 0 : disp.neg_mat[:, i-1]
        type = disp.neg_types[i]
        color = _color_for(colors, type)
        band!(ax, disp.time, prev, disp.neg_mat[:, i], color = color)
    end

    for i = 1:size(disp_d.pos_mat, 2)
        prev = i == 1 ? 0 : disp_d.pos_mat[:, i-1]
        type = disp_d.pos_types[i]
        color = _color_for(colors, type)
        band = band!(ax3, disp_d.time, prev, disp_d.pos_mat[:, i], color = color, label = type)
        push!(handles_d, band)
        push!(labels_d, type)
    end

    for i = 1:size(disp_d.neg_mat, 2)
        prev = i == 1 ? 0 : disp_d.neg_mat[:, i-1]
        type = disp_d.neg_types[i]
        color = _color_for(colors, type)
        band!(ax3, disp_d.time, prev, disp_d.neg_mat[:, i], color = color)
    end

    load_line = lines!(
        ax,
        load.Time,
        load.orig_load,
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles, load_line)
    push!(labels, "Load")

    load_line_d = lines!(
        ax3,
        load_d.Time,
        load_d.orig_load,
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles_d, load_line_d)
    push!(labels_d, "Load")

    price_line = lines!(
        ax2,
        price.Time,
        _series_values(price, :MarketBalance),
        color = :black,
        linestyle = :dot,
        label = "Day-Ahead Price",
    )
    push!(handles_d, price_line)
    push!(labels_d, "Day-Ahead price")

    lines!(
        ax4,
        price_d.Time,
        _series_values(price_d, :MarketBalance),
        color = :black,
        linestyle = :dot,
        label = "Day-Ahead Price",
    )

    autolimits!(ax)
    autolimits!(ax2)
    autolimits!(ax3)
    autolimits!(ax4)
    # Create combined legend
    # axislegend(ax, handles, labels,  position=:ct, orientation=:horizontal, nbanks=2,tellwidth=false)


    Legend(fig[2:3, 2], handles, labels, "Redispatch", nbanks = 3, position = :ct)#,tellwidth=false, orientation=:horizontal

    Legend(fig[4, 2], handles_d, labels_d, "Day-Ahead", nbanks = 3, position = :ct)#, #orientation=:horizontal
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

    prices_by_zone, load_by_zone, dispatch_by_zone =
        prepare_redisp_plot_data(results, scalefactor, time_horizon)
    prices_by_zone_d, load_by_zone_d, dispatch_by_zone_d =
        prepare_disp_plot_data(results, scalefactor, time_horizon)

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

    function redraw!(selected)
        update_plot_comb!(
            fig,
            ax,
            ax2,
            ax3,
            ax4,
            dispatch_by_zone[selected],
            load_by_zone[selected],
            prices_by_zone[selected],
            dispatch_by_zone_d[selected],
            load_by_zone_d[selected],
            prices_by_zone_d[selected],
            colors
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

function _redisp_node_summary(results)
    if isempty(results.REDISP)
        return DataFrame()
    end

    plant_nodes = results.params.plant2node
    filtered = filter(:index => i -> haskey(plant_nodes, i), results.REDISP)
    isempty(filtered) && return DataFrame()
    df_redisp = transform(filtered, :index => ByRow(i -> plant_nodes[i]) => :node)
    df_redisp = combine(
        groupby(df_redisp, :node),
        :GEN_UP => sum => :gen_up,
        :GEN_DOWN => sum => :gen_down,
        :CU_REDISP => sum => :cu,
        :CHARGE_UP => sum => :charge_up,
        :CHARGE_DOWN => sum => :charge_down,
    )

    if isempty(results.NodalMarketRedispBalance)
        return df_redisp
    end

    CU_balance = combine(groupby(results.NodalMarketRedispBalance, :Node), :CU => sum => :cu_balance)
    return leftjoin(df_redisp, CU_balance, on = :node => :Node)
end

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
        df_line_util[!, :avg_color] = []
        df_line_util[!, :max_color] = []
        return df_line_util
    end

    df_line_util[!, :avg_color] = get(ColorSchemes.lajolla, clamp.(df_line_util.avg, 0, 1))
    df_line_util[!, :max_color] = get(ColorSchemes.lajolla, df_line_util.max, :extrema)
    return df_line_util
end

function _line_endpoints_from_data(data, exclude_dc_lines)
    nodes = CSV.read(data[:nodes], DataFrame)
    missing_cols = setdiff(["index", "lon", "lat"], names(nodes))
    if !isempty(missing_cols)
        error("Node file is missing required column(s): $(join(missing_cols, ", ")). "
            * "Found: $(join(names(nodes), ", "))")
    end

    node_coords = Dict(row.index => (row.lon, row.lat) for row in eachrow(nodes))
    node_lonlat = Dict(n => project_point2f(c[1], c[2]) for (n, c) in node_coords)
    ac_lines = select(CSV.read(data[:lines], DataFrame), [:index, :node_i, :node_j])
    lines_input = ac_lines

    if !exclude_dc_lines
        dc_lines = select(CSV.read(data[:dclines], DataFrame), [:index, :node_i, :node_j])
        lines_input = vcat(ac_lines, dc_lines, cols = :union)
    end

    line_from_to = Dict()
    for row in eachrow(lines_input)
        if haskey(node_coords, row.node_i) && haskey(node_coords, row.node_j)
            from = project_point2f(node_coords[row.node_i][1], node_coords[row.node_i][2])
            to = project_point2f(node_coords[row.node_j][1], node_coords[row.node_j][2])
            line_from_to[row.index] = (from, to)
        end
    end

    return line_from_to, node_lonlat
end

function _line_endpoints_from_results(results, exclude_dc_lines)
    params = results.params
    node_lonlat = Dict(
        n => project_point2f(params.node_coords[n][1], params.node_coords[n][2])
        for n in params.sets.N if haskey(params.node_coords, n)
    )
    line_from_to = Dict()

    for l in params.sets.L
        if haskey(params.line_start, l) && haskey(params.line_end, l)
            start_node = params.line_start[l]
            end_node = params.line_end[l]
            if haskey(node_lonlat, start_node) && haskey(node_lonlat, end_node)
                line_from_to[l] = (node_lonlat[start_node], node_lonlat[end_node])
            end
        end
    end

    if !exclude_dc_lines
        for l in params.sets.DC
            if haskey(params.dc_start, l) && haskey(params.dc_end, l)
                start_node = params.dc_start[l]
                end_node = params.dc_end[l]
                if haskey(node_lonlat, start_node) && haskey(node_lonlat, end_node)
                    line_from_to[l] = (node_lonlat[start_node], node_lonlat[end_node])
                end
            end
        end
    end

    return line_from_to, node_lonlat
end

function _prepare_lineplot_common(results, data, exclude_dc_lines, threshold)
    line_from_to, node_lonlat = data === nothing ?
        _line_endpoints_from_results(results, exclude_dc_lines) :
        _line_endpoints_from_data(data, exclude_dc_lines)
    df_line_util = _line_utilization_table(results, exclude_dc_lines, threshold)
    df_redisp_combined = _redisp_node_summary(results)
    return results, df_line_util, line_from_to, node_lonlat, df_redisp_combined
end

function _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshold)
    if !(type in ("max", "avg"))
        throw(ArgumentError("Type not supported, please choose 'max' or 'avg'. You entered: $type"))
    end

    color_col = type == "max" ? :max_color : :avg_color
    for row in eachrow(df_line_util)
        if haskey(line_from_to, row.index)
            from, to = line_from_to[row.index]
            lines!(ax, [from, to], color = (row[color_col], 0.98), linewidth = 1.5)
        end
    end

    if type == "max"
        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla, limits = (0, isempty(df_line_util) ? 1 : maximum(df_line_util.max)))
        ax.xlabel = "Line color indicates count of timesteps with utilization >= $(threshold * 100)%"
    else
        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla, limits = (0.0, 1.0))
        ax.xlabel = "Line color based on average line utilization in selected timeframe"
    end

    for point in values(node_lonlat)
        scatter!(ax, point, color = :black, markersize = 5)
    end

    return fig
end



function prepare_lineplot_data(results_path, data, exclude_dc_lines, threshhold)
    results = DataFiles(results_path)
    nodes = CSV.read(data[:nodes], DataFrame)
    missing_cols = setdiff(["index", "lon", "lat"], names(nodes))
    if !isempty(missing_cols)
        error("Node file is missing required column(s): $(join(missing_cols, ", ")). "
            * "Found: $(join(names(nodes), ", "))")
    end
    node_coords = Dict(row.index => (row.lon, row.lat) for row in eachrow(nodes))
    node_lonlat = Dict(n => project_point2f.(c[1], c[2]) for (n, c) in node_coords)

    if exclude_dc_lines
        lines_input = select!(
            CSV.read(data[:lines], DataFrame),
            [:index, :node_i, :node_j],
        )
    else
        ac_lines = select!(
            CSV.read(data[:lines], DataFrame),
            [:index, :node_i, :node_j],
        )
        dc_lines = select!(
            CSV.read(data[:dclines], DataFrame),
            [:index, :node_i, :node_j],
        )
        lines_input = vcat(ac_lines, dc_lines)
    end

    line_from_to = Dict(
        row.index => (
            project_point2f.(node_coords[row.node_i][1], node_coords[row.node_i][2]),
            project_point2f.(node_coords[row.node_j][1], node_coords[row.node_j][2]),
        ) for row in eachrow(lines_input)
    )


    df_redisp = @chain results.REDISP begin
        @rsubset (:index in keys(results.params.plant2node))
        @rtransform :node = results.params.plant2node[:index]
        @by :node begin
            :gen_up = sum(:GEN_UP)
            :gen_down = sum(:GEN_DOWN)
            :cu = sum(:CU_REDISP)
            :charge_up = sum(:CHARGE_UP)
            :charge_down = sum(:CHARGE_DOWN)
        end
    end

    CU_balance = @chain results.NodalMarketRedispBalance begin
        @by :Node begin
            :cu_balance = sum(:CU)
        end
    end

    df_redisp_combined = leftjoin(df_redisp, CU_balance, on = :node => :Node)



    # agg_redisp = @chain df_redisp begin
    #     stack(Not(:node))
    #     @by :variable begin
    #         :value = sum(:value) /1e3
    #     end
    # end

    #bins = [0, 1, 1000, 2000, Inf]
    #fmt(from, to, i; leftclosed, rightclosed) = i - 1

    df_line_util = @chain results.LINEFLOW begin
        @rtransform :util = abs(:LINEFLOW) / :line_capacity
        @by :index begin
            :avg = mean(:util)
            :max = count(>=(threshhold), :util)
        end
        # @transform :category_max = cut(:max, bins, labels=fmt)
    end

    if exclude_dc_lines == false

        df_line_util_dc = @chain results.DCLINEFLOW begin
            @rtransform :util = abs(:DCLINEFLOW) / :line_capacity
            @by :index begin
                :avg = mean(:util)
                :max = count(>=(threshhold), :util)
            end
            # @transform :category_max = cut(:max, bins, labels=fmt)
        end

        df_line_util = append!(df_line_util, df_line_util_dc)
    end

    df_line_util[!, "avg_color"] = get(ColorSchemes.:lajolla, df_line_util.avg)
    df_line_util[!, "max_color"] = get(ColorSchemes.:lajolla, df_line_util.max, :extrema)

    return results, df_line_util, line_from_to, node_lonlat, df_redisp_combined
end


function prepare_lineplot_data2(results_path, exclude_dc_lines, threshhold)
    results = DataFiles(results_path)

    lines_input = results.params.sets.L


    line_from_to = Dict(
        l => (
            project_point2f.(
                results.params.node_coords[results.params.line_start[l]][1],
                results.params.node_coords[results.params.line_start[l]][2],
            ),
            project_point2f.(
                results.params.node_coords[results.params.line_end[l]][1],
                results.params.node_coords[results.params.line_end[l]][2],
            ),
        ) for l in lines_input
    )


    if !exclude_dc_lines
        lines_input = results.params.sets.DC
        for l in lines_input
            line_from_to[l] = (
                project_point2f.(
                    results.params.node_coords[results.params.dc_start[l]][1],
                    results.params.node_coords[results.params.dc_start[l]][2],
                ),
                project_point2f.(
                    results.params.node_coords[results.params.dc_end[l]][1],
                    results.params.node_coords[results.params.dc_end[l]][2],
                ),
            )
        end
    end

    node_lonlat = Dict(
        n =>
            project_point2f.(
                results.params.node_coords[n][1],
                results.params.node_coords[n][2],
            ) for n in results.params.sets.N
    )


    df_redisp = @chain results.REDISP begin
        @rsubset (:index in keys(results.params.plant2node))
        @rtransform :node = results.params.plant2node[:index]
        @by :node begin
            :gen_up = sum(:GEN_UP)
            :gen_down = sum(:GEN_DOWN)
            :cu = sum(:CU_REDISP)
            :charge_up = sum(:CHARGE_UP)
            :charge_down = sum(:CHARGE_DOWN)
        end
    end

    CU_balance = @chain results.NodalMarketRedispBalance begin
        @by :Node begin
            :cu_balance = sum(:CU)
        end
    end

    df_redisp_combined = leftjoin(df_redisp, CU_balance, on = :node => :Node)



    # agg_redisp = @chain df_redisp begin
    #     stack(Not(:node))
    #     @by :variable begin
    #         :value = sum(:value) /1e3
    #     end
    # end

    #bins = [0, 1, 1000, 2000, Inf]
    #fmt(from, to, i; leftclosed, rightclosed) = i - 1

    df_line_util = @chain results.LINEFLOW begin
        @rtransform :util = abs(:LINEFLOW) / :line_capacity
        @by :index begin
            :avg = mean(:util)
            :max = count(>=(threshhold), :util)
        end
        # @transform :category_max = cut(:max, bins, labels=fmt)
    end

    if exclude_dc_lines == false

        df_line_util_dc = @chain results.DCLINEFLOW begin
            @rtransform :util = abs(:DCLINEFLOW) / :line_capacity
            @by :index begin
                :avg = mean(:util)
                :max = count(>=(threshhold), :util)
            end
            # @transform :category_max = cut(:max, bins, labels=fmt)
        end

        df_line_util = append!(df_line_util, df_line_util_dc)
    end

    df_line_util[!, "avg_color"] = get(ColorSchemes.:lajolla, df_line_util.avg)
    df_line_util[!, "max_color"] = get(ColorSchemes.:lajolla, df_line_util.max, :extrema)

    return results, df_line_util, line_from_to, node_lonlat, df_redisp_combined
end

function create_lineplot_layout(figsize = (800, 1000); background_map = true)
    GLMakie.activate!(inline = false)
    fig = Figure(; size = figsize)
    ax = Axis(fig[1, 1])

    if background_map
        cutout = (5.5, 15, 47, 55)
        provider = CartoDB()
        extent = Extent(X = (cutout[1], cutout[2]), Y = (cutout[3], cutout[4]))
        tm = Tyler.Map(extent; provider, figure = fig, axis = ax)
        wait(tm)
    end

    return fig, ax
end

function create_lineplot(
    results_path,
    type::String = "max",
    exclude_dc_lines::Bool = false,
    threshhold::Float64 = 0.95;
    background_map::Bool = true,
)
    results, df_line_util, line_from_to, node_lonlat, _ =
        _prepare_lineplot_common(DataFiles(results_path), nothing, exclude_dc_lines, threshhold)
    fig, ax = create_lineplot_layout(; background_map = background_map)
    return _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshhold)
end

"""
    create_lineplot(results_path, data, type="max", exclude_dc_lines=false, threshhold=0.95)

Creates a geographical network map showing transmission line utilization with color-coded lines based on either maximum utilization frequency or average utilization.

# Arguments
- `results_path`: Path to the directory containing simulation results.
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref)).
- `type`: (optional, default: `"max"`) Visualization mode:
    - `"max"`: Color lines by the count of timesteps where utilization >= `threshhold`.
    - `"avg"`: Color lines by the average utilization across all timesteps.
- `exclude_dc_lines`: (optional, default: `false`) If `true`, only AC lines are visualized.
- `threshhold`: (optional, default: `0.95`) Utilization threshold (0-1 scale) for `"max"` mode counting.

# Plot Details
- Lines are colored using the `ColorSchemes.lajolla` colormap.
- **Max mode**: Colorbar shows the count of hours where line utilization exceeds the threshold.
- **Avg mode**: Colorbar shows average utilization percentage (0-100%).
- Network nodes are displayed as black points.
- Uses geographical coordinates with Web Mercator projection.

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
)
    results, df_line_util, line_from_to, node_lonlat, _ =
        _prepare_lineplot_common(DataFiles(results_path), data, exclude_dc_lines, threshhold)
    fig, ax = create_lineplot_layout(; background_map = background_map)
    return _render_lineplot!(fig, ax, df_line_util, line_from_to, node_lonlat, type, threshhold)
end

"""
    plot_network(data::Dict{Symbol,String})

Plots a simple network map of an energy system using line and node geographical data. AC and DC transmission lines are shown as straight connections between nodes, and all network nodes are marked.

# Arguments
- `data`: A dictionary containing file paths for required network data tables (see section [Input Data Load](@ref))

# Plot Details
- **AC lines** are drawn as solid black lines.
- **DC lines** are drawn as dashed black lines.
- **Nodes** are plotted as black points.

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
function POMATWO.plot_network(data::Dict{Symbol,String})
    nodes = CSV.read(data[:nodes], DataFrame)
    missing_cols = setdiff(["index", "lon", "lat"], names(nodes))
    if !isempty(missing_cols)
        error("Node file is missing required column(s): $(join(missing_cols, ", ")). "
            * "Found: $(join(names(nodes), ", "))")
    end
    node_coords = Dict(row.index => (row.lon, row.lat) for row in eachrow(nodes))

    ac_lines = select!(CSV.read(data[:lines], DataFrame), [:node_i, :node_j])
    dc_lines = select!(CSV.read(data[:dclines], DataFrame), [:node_i, :node_j])
    fig, ax = create_lineplot_layout()

    for row in eachrow(ac_lines)
        from = project_point2f.(node_coords[row.node_i][1], node_coords[row.node_i][2])
        to = project_point2f.(node_coords[row.node_j][1], node_coords[row.node_j][2])
        lw = 1
        c = :black
        lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
    end

    for row in eachrow(dc_lines)
        from = project_point2f.(node_coords[row.node_i][1], node_coords[row.node_i][2])
        to = project_point2f.(node_coords[row.node_j][1], node_coords[row.node_j][2])
        lw = 1
        c = :black
        lines!(ax, [from, to], color = (c, 0.98), linewidth = lw, linestyle = :dash)
    end

    for row in eachrow(nodes)
        point = project_point2f.(row.lon, row.lat)
        c = :black
        scatter!(ax, point, color = c, markersize = 5)
    end

    return fig
end


function plot_total_gen(results, kind, zone)
    df = summarize_result(transform_results_by_type(results, kind, zone))


    categories = names(df)  # Extract column names as labels
    values = vec(Matrix(df)) ./ 1000  # Convert DataFrame row to a vector of values and scales form MWh to GWh
    colors = [_color_for(_plot_colors(results), c) for c in categories]
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

    # Observables for dropdown state
    kind_obs = Observable(first(kinds))
    zone_obs = Observable(first(zones))

    # Function to generate plot data
    function get_plot_data(kind, zone)
        df = summarize_result(transform_results_by_type(results, kind, zone))
        categories = names(df)
        values = vec(Matrix(df)) ./ 1000
        colors = [_color_for(_plot_colors(results), c) for c in categories]
        return categories, values, colors
    end

    # Prepare observables for data
    categories_obs = Observable(String[])
    values_obs = Observable(Float64[])
    colors_obs = Observable([])

    # Initial fill
    cats, vals, cols = get_plot_data(kind_obs[], zone_obs[])
    categories_obs[] = cats
    values_obs[] = vals
    colors_obs[] = cols

    # Create the figure
    fig = Figure(size = (900, 600))
    ax = Axis(
        fig[2, 1],
        xticks = (1:length(categories_obs[]), categories_obs[]),
        ylabel = "GWh",
        xticklabelrotation = 45,
    )

    bars = barplot!(
        ax, 
        1:length(values_obs[]), 
        values_obs[], 
        color = colors_obs[], 
        bar_labels = :y
    )

    # Menus
    kind_menu = Menu(fig, options = kinds, width = 150)
    zone_menu = Menu(fig, options = zones, width = 150)
    fig[1, 1] = hgrid!(Label(fig, "Kind:"), kind_menu, Label(fig, "Zone:"), zone_menu)

    # Update on selection change
    function update_plot!()
    cats, vals, cols = get_plot_data(kind_menu.selection[], zone_menu.selection[])
    categories_obs[] = cats
    values_obs[] = vals
    colors_obs[] = cols

    # Clear the axis
    empty!(ax)
    # Update xticks
    ax.xticks = (1:length(cats), cats)
    # Re-create barplot
    barplot!(ax, 1:length(vals), vals, color=cols, bar_labels=:y)
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
