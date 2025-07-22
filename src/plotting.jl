function stack_vals(df, col)
    types, mat = @chain df begin
        @rsubset :variable == col
        unstack(:plant_type, :value, combine = sum)
        select!(Not([:Time, :variable]))
        disallowmissing!
        names(_), Array(_)
    end

    return types, Matrix{Float64}(cumsum(mat, dims = 2))
end

function prepare_disp_plot_data(results, scalefactor, time_horizon)
    prices_by_zone = Dict()
    load_by_zone = Dict()
    dispatch_by_zone = Dict()

    results.params.colors["exchange"] = "#9526b7"
    results.params.colors["LL"] = "#ff0000"
    results.params.colors["CU"] = "#ff7373"

    for z in results.params.sets.Z

        df_gen_plant_type = @chain results.GEN begin
            @rsubset :Time in time_horizon
            @rsubset! results.params.plant2zone[:index] == z
            @rtransform! :plant_type = results.params.plant_type[:index]
            @by [:Time, :plant_type] :value = scalefactor * sum(:GEN)
            @orderby :Time
        end

        df_charge_plant_type = @chain results.CHARGE begin
            @rsubset :Time in time_horizon
            @rsubset! results.params.plant2zone[:index] == z
            @rtransform! :plant_type = results.params.plant_type[:index]
            @by [:Time, :plant_type] :value = -scalefactor * sum(:CHARGE)
            @orderby :Time
        end

        df_ex = @chain results.EXCHANGE begin
            @rsubset :Time in time_horizon
            @rsubset! :index == z
            @rtransform! begin
                :plant_type = "exchange"
                :value = scalefactor * sum(:EXCHANGE)
            end
            # @rtransform! :value_pos = min(0, :value)
            # @rtransform! :value_neg = -max(0, :value)
            @orderby :Time
        end

        df_LL = @chain results.ZonalMarketBalance begin
            @rsubset :Time in time_horizon
            @rsubset! :Zone == z
            @rtransform! begin
                :plant_type = "LL"
                :value = scalefactor * sum(:LL)
            end
        end

        df_CU = @chain results.GEN begin
            @rsubset :Time in time_horizon
            @rsubset! :index in results.params.plants_in_zone[z]
            @rtransform! begin
                :plant_type = "CU"
            end
            @by [:Time, :plant_type] :value = -scalefactor * sum(:CU)
        end

        df_merged = reduce(
            vcat,
            [df_gen_plant_type, df_charge_plant_type, df_LL, df_CU, df_ex],
            cols = :intersect,
        )#
        orig_load = results.params.nodal_load
        #prs_load = data.params.nodal_load_no_prs
        df_load = DataFrame(
            (
                Time = t,
                orig_load = sum(
                    orig_load[n][t] / 1e3 for
                    n in results.params.nodes_in_zone[z] if haskey(orig_load, n) &&
                    length(results.params.nodes_in_zone[z]) > 0 &&
                    length(orig_load[n][t]) > 0;
                    init = 0,
                ),  # Ensure init=0 for empty collections
            ) for t in time_horizon
        )
        df_price = @chain results.ZonalMarketBalance begin
            @rsubset :Time in time_horizon
            @rsubset :Zone == z
            @orderby :Time
        end

        df_dispatch = @chain df_merged begin
            @rtransform :pos = :value >= 0 ? :value : 0
            @rtransform :neg = :value < 0 ? :value : 0
            select!(Not(:value))
            stack([:pos, :neg])
        end

        merge!(prices_by_zone, Dict(z => df_price))
        merge!(load_by_zone, Dict(z => df_load))
        merge!(dispatch_by_zone, Dict(z => df_dispatch))
        # pbz = Dict(zone => df_price)
        # lbz = Dict(zone => df_load)
    end
    return prices_by_zone, load_by_zone, dispatch_by_zone
end

function prepare_redisp_plot_data(results, scalefactor, time_horizon)
    prices_by_zone = Dict()
    load_by_zone = Dict()
    dispatch_by_zone = Dict()

    results.params.colors["exchange"] = "#9526b7"
    results.params.colors["LL"] = "#ff0000"
    results.params.colors["CU"] = "#ff7373"
    results.params.colors["Net injection"] = "#b2a1d5"

    for z in results.params.sets.Z

        df_gen_plant_type = @chain results.REDISP begin
            @rsubset :Time in time_horizon
            @rsubset! results.params.plant2zone[:index] == z
            @rtransform! :plant_type = results.params.plant_type[:index]
            @by [:Time, :plant_type] :value = scalefactor * sum(:GEN_REDISP)
            @orderby :Time
        end

        df_charge_plant_type = @chain results.REDISP begin
            @rsubset :Time in time_horizon
            @rsubset! results.params.plant2zone[:index] == z
            @rtransform! :plant_type = results.params.plant_type[:index]
            @by [:Time, :plant_type] :value = -scalefactor * sum(:CHARGE_REDISP)
            @orderby :Time
        end
        #### Prosumer ###

        # df_prs = @chain data.PRS begin
        #     @rsubset :Time in dispatch_plot_selection.time
        #     @rsubset! data.params.plant2zone[:index] in dispatch_plot_selection.zone
        #     @rtransform! :plant_type = "prosumer"
        #     @by [:Time, :plant_type] :value = scalefactor*sum(:PRS_NETINPUT)
        #     @orderby :Time
        # end

        # df_ex = @chain results.EXCHANGE begin
        #     @rsubset :Time in time_horizon
        #     @rsubset! :index == z
        #     @rtransform! begin
        #         :plant_type = "exchange"
        #         :value = scalefactor*sum(:EXCHANGE)
        #     end
        #     # @rtransform! :value_pos = min(0, :value)
        #     # @rtransform! :value_neg = -max(0, :value)
        #     @orderby :Time
        # end

        df_redisp = @chain results.NETINPUT begin
            @rsubset :Time in time_horizon
            @rsubset! :index in results.params.nodes_in_zone[z]
            @rtransform! begin
                :plant_type = "Net injection"
            end
            @by [:Time, :plant_type] :value = scalefactor * sum(:NETINPUT)
        end

        df_LL = @chain results.NodalMarketRedispBalance begin
            @rsubset :Time in time_horizon
            @rsubset! :Node in results.params.nodes_in_zone[z]
            @rtransform! begin
                :plant_type = "LL"
            end
            @by [:Time, :plant_type] :value = scalefactor * sum(:LL)
        end

        df_CU = @chain results.REDISP begin
            @rsubset :Time in time_horizon
            @rsubset! :index in results.params.plants_in_zone[z]
            @rtransform! begin
                :plant_type = "CU"
            end
            @by [:Time, :plant_type] :value = -scalefactor * sum(:CU_REDISP)
        end


        df_merged = reduce(
            vcat,
            [df_gen_plant_type, df_charge_plant_type, df_redisp, df_LL, df_CU],
            cols = :intersect,
        )#df_ex,
        orig_load = results.params.nodal_load
        #prs_load = data.params.nodal_load_no_prs
        df_load = DataFrame(
            (
                Time = t,
                orig_load = sum(
                    orig_load[n][t] / 1e3 for
                    n in results.params.nodes_in_zone[z] if haskey(orig_load, n) &&
                    length(results.params.nodes_in_zone[z]) > 0 &&
                    length(orig_load[n][t]) > 0;
                    init = 0,
                ),  # Ensure init=0 for empty collections
            ) for t in time_horizon
        )
        df_price = @chain results.ZonalMarketBalance begin
            @rsubset :Time in time_horizon
            @rsubset :Zone == z
            @orderby :Time
        end

        df_dispatch = @chain df_merged begin
            @rtransform :pos = :value >= 0 ? :value : 0
            @rtransform :neg = :value < 0 ? :value : 0
            select!(Not(:value))
            stack([:pos, :neg])
        end

        merge!(prices_by_zone, Dict(z => df_price))
        merge!(load_by_zone, Dict(z => df_load))
        merge!(dispatch_by_zone, Dict(z => df_dispatch))
        # pbz = Dict(zone => df_price)
        # lbz = Dict(zone => df_load)
    end
    return prices_by_zone, load_by_zone, dispatch_by_zone
end

# Function to update the plot based on the observables
function update_plot!(fig, ax, ax2, disp, load, price, time_horizon, colors)
    start = time_horizon[1]
    nd = time_horizon[end]
    pos_types, pos_mat = stack_vals(disp[], "pos")
    neg_types, neg_mat = stack_vals(disp[], "neg")

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

    for i = 1:size(pos_mat, 2)
        prev = i == 1 ? 0 : pos_mat[:, i-1]
        type = pos_types[i]
        color = colors[type]
        band = band!(ax, start:nd, prev, pos_mat[:, i], color = color, label = type)
        push!(handles, band)
        push!(labels, type)
    end

    for i = 1:size(neg_mat, 2)
        prev = i == 1 ? 0 : neg_mat[:, i-1]
        type = neg_types[i]
        color = colors[type]
        band = band!(ax, start:nd, prev, neg_mat[:, i], color = color)
        # push!(handles, band)
        #  push!(labels, type)
    end

    load_line = lines!(
        ax,
        start:nd,
        load[].orig_load[start:end],
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles, load_line)
    push!(labels, "Load")

    price_line = lines!(
        ax2,
        start:nd,
        price[].MarketBalance[start:end],
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

    # Observable for the selected zone
    disp = Observable(dispatch_by_zone[results.params.sets.Z[1]])
    price = Observable(prices_by_zone[results.params.sets.Z[1]])
    load = Observable(load_by_zone[results.params.sets.Z[1]])

    on(zone_menu.selection) do selected
        disp[] = dispatch_by_zone[selected]
        price[] = prices_by_zone[selected]
        load[] = load_by_zone[selected]
    end

    ax = Axis(fig[1:2, 1], xlabel = "Hour", ylabel = "GW", title = "Generation")

    ax2 = Axis(fig[1:2, 1], ylabel = "EUR/MWh", yaxisposition = :right)

    hidexdecorations!(ax2)
    linkxaxes!(ax, ax2)
    # Initial plot
    update_plot!(fig, ax, ax2, disp, load, price, time_horizon, results.params.colors)

    # Update the plot when the observables change
    on(disp) do _
        update_plot!(fig, ax, ax2, disp, load, price, time_horizon, results.params.colors)
    end
    on(load) do _
        update_plot!(fig, ax, ax2, disp, load, price, time_horizon, results.params.colors)
    end
    on(price) do _
        update_plot!(fig, ax, ax2, disp, load, price, time_horizon, results.params.colors)
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
    time_horizon,
    colors,
)
    start = time_horizon[1]
    nd = time_horizon[end]
    pos_types, pos_mat = stack_vals(disp[], "pos")
    neg_types, neg_mat = stack_vals(disp[], "neg")

    pos_types_d, pos_mat_d = stack_vals(disp_d[], "pos")
    neg_types_d, neg_mat_d = stack_vals(disp_d[], "neg")

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

    for i = 1:size(pos_mat, 2)
        prev = i == 1 ? 0 : pos_mat[:, i-1]
        type = pos_types[i]
        color = colors[type]
        band = band!(ax, start:nd, prev, pos_mat[:, i], color = color, label = type)
        push!(handles, band)
        push!(labels, type)
    end

    for i = 1:size(neg_mat, 2)
        prev = i == 1 ? 0 : neg_mat[:, i-1]
        type = neg_types[i]
        color = colors[type]
        band = band!(ax, start:nd, prev, neg_mat[:, i], color = color)
        # push!(handles, band)
        #  push!(labels, type)
    end

    for i = 1:size(pos_mat_d, 2)
        prev = i == 1 ? 0 : pos_mat_d[:, i-1]
        type = pos_types_d[i]
        color = colors[type]
        band = band!(ax3, start:nd, prev, pos_mat_d[:, i], color = color, label = type)
        push!(handles_d, band)
        push!(labels_d, type)
    end

    for i = 1:size(neg_mat_d, 2)
        prev = i == 1 ? 0 : neg_mat_d[:, i-1]
        type = neg_types_d[i]
        color = colors[type]
        band = band!(ax3, start:nd, prev, neg_mat_d[:, i], color = color)
        # push!(handles, band)
        #  push!(labels, type)
    end

    load_line = lines!(
        ax,
        start:nd,
        load[].orig_load,
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles, load_line)
    push!(labels, "Load")

    load_line_d = lines!(
        ax3,
        start:nd,
        load_d[].orig_load,
        color = :black,
        linestyle = :dash,
        label = "original load",
    )
    push!(handles_d, load_line_d)
    push!(labels_d, "Load")

    price_line = lines!(
        ax2,
        start:nd,
        price[].MarketBalance,
        color = :black,
        linestyle = :dot,
        label = "Day-Ahead Price",
    )
    push!(handles_d, price_line)
    push!(labels_d, "Day-Ahead price")

    price_line_d = lines!(
        ax4,
        start:nd,
        price_d[].MarketBalance,
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


    # Observable for the selected zone
    disp = Observable(dispatch_by_zone[results.params.sets.Z[1]])
    price = Observable(prices_by_zone[results.params.sets.Z[1]])
    load = Observable(load_by_zone[results.params.sets.Z[1]])

    # Observable for the selected zone
    disp_d = Observable(dispatch_by_zone_d[results.params.sets.Z[1]])
    price_d = Observable(prices_by_zone_d[results.params.sets.Z[1]])
    load_d = Observable(load_by_zone_d[results.params.sets.Z[1]])

    on(zone_menu.selection) do selected
        disp[] = dispatch_by_zone[selected]
        price[] = prices_by_zone[selected]
        load[] = load_by_zone[selected]

        disp_d[] = dispatch_by_zone_d[selected]
        price_d[] = prices_by_zone_d[selected]
        load_d[] = load_by_zone_d[selected]
    end

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

    # Initial plot
    update_plot_comb!(
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
        time_horizon,
        results.params.colors
    )


    # Update the plot when the observables change
    on(disp) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end
    on(load) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end
    on(price) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end

    on(disp_d) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end
    on(load_d) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end
    on(price_d) do _
        update_plot_comb!(
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
            time_horizon,
            results.params.colors
        )
    end


    return fig
end


project(x, y) = MapTiles.project((x, y), MapTiles.wgs84, MapTiles.web_mercator)
project_point2f(x, y) = project(x, y) |> Point2f



function prepare_lineplot_data(results_path, data, exclude_dc_lines, threshhold)
    results = DataFiles(results_path)
    if exclude_dc_lines
        lines_input = select!(
            CSV.read(data[:lines], DataFrame),
            [:index, :node_i, :node_j, :lat_i, :lon_i, :lat_j, :lon_j],
        )
    else
        ac_lines = select!(
            CSV.read(data[:lines], DataFrame),
            [:index, :node_i, :node_j, :lat_i, :lon_i, :lat_j, :lon_j],
        )
        dc_lines = select!(
            CSV.read(data[:dclines], DataFrame),
            [:index, :node_i, :node_j, :lat_i, :lon_i, :lat_j, :lon_j],
        )
        lines_input = vcat(ac_lines, dc_lines)
    end

    line_from_to = Dict(
        row.index => (
            project_point2f.(row.lon_i, row.lat_i),
            project_point2f.(row.lon_j, row.lat_j),
        ) for row in eachrow(lines_input)
    )
    nodes = CSV.read(data[:nodes], DataFrame)
    node_lonlat =
        Dict(row.index => project_point2f.(row.lon, row.lat) for row in eachrow(nodes))


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

function create_lineplot_layout(figsize = (800, 1000))
    GLMakie.activate!(inline = false)
    #figsize = (800, 1000)
    cutout = (5.5, 15, 47, 55)
    provider = CartoDB()

    fig = Figure(; size = figsize)
    ax = Axis(fig[1, 1])
    extent = Extent(X = (cutout[1], cutout[2]), Y = (cutout[3], cutout[4]))
    tm = Tyler.Map(extent; provider, figure = fig, axis = ax)
    wait(tm)
    return fig, ax

end

function create_lineplot(
    results_path,
    type::String = "max",
    exclude_dc_lines::Bool = false,
    threshhold::Float64 = 0.95,
)

    if type != "max" && type != "avg"
        throw("Type not supported, please choose 'max' or 'avg' you entered: $type")
    end

    results, df_line_util, line_from_to, node_lonlat, df_redisp_combined =
        prepare_lineplot_data2(results_path, exclude_dc_lines, threshhold)

    fig, ax = create_lineplot_layout()


    if type == "max"

        for row in eachrow(df_line_util)
            from, to = line_from_to[row.index]
            lw = 1.5
            c = row.max_color
            lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
        end

        Colorbar(
            fig[1, 2],
            colormap = ColorSchemes.lajolla,
            limits = (0, maximum(Array(results.LINEFLOW.Time))),
        )
        ax.xlabel = "Linecolor based on count, where line utls. >= $threshhold"
    elseif type == "avg"

        for row in eachrow(df_line_util)
            from, to = line_from_to[row.index]
            lw = 1.5
            c = row.avg_color
            lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
        end

        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla, limits = (0.0, 100))
        ax.xlabel = "Linecolor based on avarage line utls. in selected timeframe"
    end

    for row in keys(node_lonlat)

        point = node_lonlat[row]
        c = :black
        scatter!(ax, point, color = c, markersize = 5)
    end

    return fig
end


function create_lineplot(
    results_path,
    data,
    type::String = "max",
    exclude_dc_lines::Bool = false,
    threshhold::Float64 = 0.95,
)

    if type != "max" && type != "avg"
        throw("Type not supported, please choose 'max' or 'avg' you entered: $type")
    end

    results, df_line_util, line_from_to, node_lonlat, df_redisp_combined =
        prepare_lineplot_data(results_path, data, exclude_dc_lines, threshhold)

    fig, ax = create_lineplot_layout()


    if type == "max"

        for row in eachrow(df_line_util)
            from, to = line_from_to[row.index]
            lw = 1.5
            c = row.max_color
            lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
        end

        Colorbar(
            fig[1, 2],
            colormap = ColorSchemes.lajolla,
            limits = (0, maximum(Array(results.LINEFLOW.Time))),
        )
        ax.xlabel = "Linecolor based on count, where line utls. >= $threshhold"
    elseif type == "avg"

        for row in eachrow(df_line_util)
            from, to = line_from_to[row.index]
            lw = 1.5
            c = row.avg_color
            lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
        end

        Colorbar(fig[1, 2], colormap = ColorSchemes.lajolla, limits = (0.0, 100))
        ax.xlabel = "Linecolor based on avarage line utls. in selected timeframe"
    end

    for row in keys(node_lonlat)

        point = node_lonlat[row]
        c = :black
        scatter!(ax, point, color = c, markersize = 5)
    end

    return fig
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
    ac_lines = select!(CSV.read(data[:lines], DataFrame), [:lat_i, :lon_i, :lat_j, :lon_j])
    dc_lines =
        select!(CSV.read(data[:dclines], DataFrame), [:lat_i, :lon_i, :lat_j, :lon_j])
    nodes = CSV.read(data[:nodes], DataFrame)
    fig, ax = create_lineplot_layout()


    for row in eachrow(ac_lines)
        from = project_point2f.(row.lon_i, row.lat_i)
        to = project_point2f.(row.lon_j, row.lat_j)
        lw = 1
        c = :black
        lines!(ax, [from, to], color = (c, 0.98), linewidth = lw)
    end

    for row in eachrow(dc_lines)
        from = project_point2f.(row.lon_i, row.lat_i)
        to = project_point2f.(row.lon_j, row.lat_j)
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


function POMATWO.plot_total_gen(results, kind, zone)
    df = summarize_result(transform_results_by_type(results, kind, zone))


    categories = names(df)  # Extract column names as labels
    values = vec(Matrix(df)) ./ 1000  # Convert DataFrame row to a vector of values and scales form MWh to GWh
    colors = [results.params.colors[c] for c in categories]
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
        colors = [results.params.colors[c] for c in categories]
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