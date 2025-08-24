"""
    run(mr::ModelRun)

Executes the configured POMATWO model simulation for the given [`ModelRun`](@ref) object.

Saves input parameters to the results folder and runs the internal optimization routine.

# Arguments
- `mr::ModelRun`: The simulation object containing model configuration and input data.

# Side Effects
- Writes `params.jld2` to the scenario output directory.
- Stores simulation results in output files.
"""
function run(mr::ModelRun)
    @info "Saving parameters to results folder"
    save_object(joinpath(mr.scen_dir, "params.jld2"), mr.params)
    _run(mr)
end

"""
    _run(mr::ModelRun{MT, PS}) where {MT<:Union{ZonalMarket,NodalMarket}, PS<:NoProsumer}

Runs the market simulation for zonal or nodal market types without prosumer optimization.
Performs day-ahead optimization and stores results for each time split.
"""
function _run(mr::ModelRun{MT, PS}) where {MT<:Union{ZonalMarket,NodalMarket}, PS<:NoProsumer}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{MT, PS}) where {MT<:Union{ZonalMarket,NodalMarket}, PS<:ProsumerOptimization}

Runs the market simulation for zonal or nodal market types with prosumer optimization.
Performs day-ahead optimization, then prosumer optimization, and stores results for each time split.
"""
function _run(mr::ModelRun{MT, PS}) where {MT<:Union{ZonalMarket,NodalMarket}, PS<:ProsumerOptimization}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        # Prosumer optimization
        ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
        da_results = prev_results_for_redispatch(sr)
        da_results[:price] = get_balance(mr.setup.MarketType, sr)
        market_state = ProsumerOptimizationState(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
        @suppress optimize!(sr)
        fetch_results(sr)
        write_results(sr)
        da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{MT, PS}) where {MT<:Union{NodalMarketWithRedispatch,ZonalMarketWithRedispatch}, PS<:NoProsumer}

Runs the market simulation for nodal or zonal market types with redispatch and no prosumer optimization.
Performs day-ahead and redispatch optimization, storing results for each time split.
"""
function _run(mr::ModelRun{MT, PS}) where {MT<:Union{NodalMarketWithRedispatch,ZonalMarketWithRedispatch}, PS<:NoProsumer}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        da_results = prev_results_for_redispatch(sr)
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Redispatch -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        if termination_status(sr.optigraph) != MOI.OPTIMAL
            @show termination_status(sr.optigraph)
        end
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    _run(mr::ModelRun{MT, PS}) where {MT<:Union{NodalMarketWithRedispatch,ZonalMarketWithRedispatch}, PS<:ProsumerOptimization}

Runs the market simulation for nodal or zonal market types with redispatch and prosumer optimization.
Performs day-ahead, prosumer, and redispatch optimization, storing results for each time split.
"""
function _run(mr::ModelRun{MT, PS}) where {MT<:Union{NodalMarketWithRedispatch,ZonalMarketWithRedispatch}, PS<:ProsumerOptimization}
    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"
        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)
        da_results = prev_results_for_redispatch(sr)
        # Prosumer optimization
        ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
        da_results = prev_results_for_redispatch(sr)
        da_results[:price] = get_balance(mr.setup.MarketType, sr)
        market_state = ProsumerOptimizationState(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
        @suppress optimize!(sr)
        fetch_results(sr)
        write_results(sr)
        da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        # Redispatch optimization
        ProgressMeter.update!(prog, desc = "Redispatch -> Building Model")
        market_state = Redispatch(T, da_results)
        sr = SubRun(mr, market_state)
        ProgressMeter.update!(prog, desc = "Redispatch -> Optimizing")
        @suppress optimize!(sr)
        ProgressMeter.update!(prog, desc = "Redispatch -> Fetching Results")
        if termination_status(sr.optigraph) != MOI.OPTIMAL
            @show termination_status(sr.optigraph)
        end
        fetch_results(sr)
        write_results(sr)
        finish!(prog, desc = "Subrun -> Done")
    end
end

"""
    run_intraday(datapath, Gates::Int, params, scen_name)

Runs intraday market simulations for multiple gates using provided data files and parameters.

# Arguments
- `datapath`: Path to the directory containing input data files.
- `Gates::Int`: Number of intraday gates to simulate.
- `params`: Model parameters object.
- `scen_name`: Scenario name prefix for output directories.

# Side Effects
- Reads availability and load data for each gate.
- Writes results for each gate to a separate scenario directory.
"""
function run_intraday(datapath, Gates::Int, params, scen_name)
    files = readdir(datapath)
    for g = 1:Gates
        if !("avail_ID_$g.csv" in files)
            throw(
                DomainError(
                    "avail_ID_$g.csv",
                    "Intraday availibility data must be named as: 'avail_ID_g' with g being the gate number",
                ),
            )
        end
    end

    for ID = 1:Gates
        avail = read_csv(joinpath(datapath, "avail_ID_$ID.csv"))
        for (name, column) in pairs(eachcol(avail))
            params.avail_planttype_zonal[string(name), "ES"] = HourlyProfile(column)
        end

        for p in params.sets.P
            pt = params.plant_type[p]
            n = params.plant2node[p]
            z = params.plant2zone[p]
            if haskey(params.avail_planttype_nodal, (pt, n))
                params.avail[p] = params.avail_planttype_nodal[pt, n]
            elseif haskey(params.avail_planttype_zonal, (pt, z))
                params.avail[p] = params.avail_planttype_zonal[pt, z]
            else
                params.avail[p] = FixedProfile(1)
            end
        end

        df_demand = read_csv(joinpath(datapath, "nodal_load.csv"))
        s = names(df_demand)[1] in ["Hour", "index"] ? 2 : 1
        for col in pairs(eachcol(df_demand[!, s:end]))
            params.nodal_load[string(col[1])] = HourlyProfile(Vector(col[2]))
        end

        for n in setdiff(params.sets.N, keys(params.nodal_load))
            params.nodal_load[n] = FixedProfile(0)
        end

        setup = ModelSetup(
            "TestSetup",
            TimeHorizon(; offset = 0, split = 24, stop = 24),
            ZonalMarket(target_zone = "ES"),
            NoProsumer(),
        )

        solver = optimizer_with_attributes(Gurobi.Optimizer, "OutputFlag" => 0)

        mr = ModelRun(
            params,
            setup,
            solver;
            scenarioname = "$(scen_name)_ID_$ID",
            overwrite = true,
        )

        run(mr)
    end
end
