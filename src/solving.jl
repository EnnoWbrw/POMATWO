"""
    run(mr::ModelRun)

Executes the configured POMATWO model simulation for the given [`ModelRun`](@ref) object.

This function performs the following:
- Saves the input parameters object to the results folder for traceability.
- Executes the internal optimization and simulation routine.

# Arguments
- `mr::ModelRun`: The simulation object that contains the model configuration (`ModelSetup`) and preloaded input data (`Parameters`).

# Side Effects
- Writes `params.jld2` to the scenario output directory specified in `mr.scen_dir`.
- Stores simulation results within the `ModelRun` instance and in associated output files.

# Example

```julia
data_files= Dict{Symbol,String}(
    :plants => joinpath(datapath, "plants.csv"),
    :nodes => joinpath(datapath, "nodes.csv"),
    :zones => joinpath(datapath, "zones.csv"),
    :lines => joinpath(datapath, "lines.csv"),
    :dclines => joinpath(datapath, "dclines.csv"),
    :demand => joinpath(datapath, "nodal_load.csv"),
    :types => joinpath(datapath, "planttypes.csv"),
)
setup = ModelSetup(
    "TestSetup",
    TimeHorizon(stop = 4),
    ZonalMarketWithRedispatch(),
    NoProsumer()
    )
params = load_data(data_files)
mr = ModelRun(setup, params, solver)

run(mr)  # executes the market simulation
```
"""
function run(mr::ModelRun)
    @info "Saving parameters to results folder"

    save_object(joinpath(mr.scen_dir, "params.jld2"), mr.params)

    _run(mr)
end


function _run(mr::ModelRun{MT}) where {MT<:Union{ZonalMarket,NodalMarket}}

    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"

        prog = ProgressUnknown(desc = "DayAhead", spinner = true, dt = 0.1)
        ### DayAhead
        market_state = DayAhead(T)
        ProgressMeter.update!(prog, desc = "DayAhead -> Building Model")
        sr = SubRun(mr, market_state)

        ProgressMeter.update!(prog, desc = "DayAhead -> Optimizing")
        @suppress optimize!(sr)

        ProgressMeter.update!(prog, desc = "DayAhead -> Fetching Results")
        fetch_results(sr)
        write_results(sr)

        ### Prosumer
        if !(mr.setup.ProsumerSetup isa NoProsumer)
            ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
            da_results = prev_results_for_redispatch(sr)
            if mr.setup.MarketType isa ZonalMarketType
            da_results[:price] = dual.(sr.optigraph[:ZonalMarketBalance])
            elseif mr.setup.MarketType isa NodalMarketType
                da_results[:price] = dual.(sr.optigraph[:NodalMarketBalance])
            else
                @error "Prosumer optimization is not supported for the selected market type"
            end
            market_state = ProsumerOptimizationState(T, da_results)
            sr = SubRun(mr, market_state)

            ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
            @suppress optimize!(sr)
            fetch_results(sr)
            write_results(sr)
            da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        end

        finish!(prog, desc = "Subrun -> Done")
    end
end


function _run(mr::ModelRun{MT}) where {MT<:Union{NodalMarketWithRedispatch,ZonalMarketWithRedispatch}}

    for T in split(mr.setup.TimeHorizon)
        @info "Starting subrun for period from $(T[1]) to $(T[end])"

        ## DayAhead
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

        ### Prosumer
        if !(mr.setup.ProsumerSetup isa NoProsumer)
            ProgressMeter.update!(prog, desc = "Prosumer -> Building Model")
            if mr.setup.MarketType isa ZonalMarketType
            da_results[:price] = dual.(sr.optigraph[:ZonalMarketBalance])
            elseif mr.setup.MarketType isa NodalMarketType
                da_results[:price] = dual.(sr.optigraph[:NodalMarketBalance])
            else
                @error "Prosumer optimization is not supported for the selected market type"
            end
            market_state = ProsumerOptimizationState(T, da_results)
            sr = SubRun(mr, market_state)

            ProgressMeter.update!(prog, desc = "Prosumer -> Optimizing")
            @suppress optimize!(sr)
            fetch_results(sr)
            write_results(sr)
            da_results[:prs_netinput] = value.(sr.vars[:prosumer][:PRS_NETINPUT])
        end

        ## Redispatch
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

function prev_results_for_redispatch(sr::SubRun)
    d = sr.vars

    return Dict(
        :disp_generation => value.(d[:disp][:GEN]),
        :ndisp_cu => value.(d[:ndisp][:CU]),
        :sto_generation => value.(d[:sto][:GEN]),
        :sto_charge => value.(d[:sto][:CHARGE]),
    )
end


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
            #elseif !("nodal_load.csv" in files)
            #    throw(DomainError("nodal_load.csv", "Intraday load data must be named as: 'nodal_load_ID_g' with g being the gate number"))
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
