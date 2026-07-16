function make_data_files(datapath; files)
    out = Dict{Symbol, Union{String, Vector{String}}}()
    for (key, fname) in files
        if isa(fname, Vector)
            out[key] = [joinpath(datapath, f) for f in fname]
        else
            out[key] = joinpath(datapath, fname)
        end
    end
    return out
end


cases = Dict(
    "case 1" => let
        filepath = joinpath(@__DIR__, "data", "test_data_3_nodes_prosumer")
        Dict(
            :filepath => filepath,
            :data_files => make_data_files(filepath; files = Dict(
                :plants => "plants.csv",
                :nodes => "nodes.csv",
                :zones => "zones.csv",
                :lines => "lines.csv",
                :dclines => "dclines.csv",
                :demand => "nodal_load.csv",
                :types => "planttypes.csv",
            )),
            :expected => Dict(
                :gmax_keys => Set(["p1", "p2"]), 
                :gmax => Dict("p1" => 140.0, "p2" => 300.0), 
                :plant_type => Dict("p1" => "wind", "p2" => "coal"), 
                :slack => "n1", 
                :nodes_in_zone_DE => 2,
            )
        )
    end,
    "case 2" => let
        filepath = joinpath(@__DIR__, "data", "test_data_3_nodes_prosumer")
        Dict(
            :filepath => filepath,
            :data_files => make_data_files(filepath; files = Dict(
                :plants => ["plants.csv", "prosumer_plants.csv"],
                :nodes => "nodes.csv",
                :zones => "zones.csv",
                :lines => "lines.csv",
                :dclines => "dclines.csv",
                :demand => "nodal_load.csv",
                :types => "planttypes.csv",
                :avail => "availability.csv",
                :prs_demand =>  "prosumer_demand.csv",
            )),
            :expected => Dict(
                :gmax_keys => Set(["p1", "p2", "prs_n2"]),
                :gmax => Dict("p1" => 140.0, "p2" => 300.0, "prs_n2" => 40),
                :plant_type => Dict("p1" => "wind", "p2" => "coal", "prs_n2" => "prosumer"),
                :slack => "n1",
                :nodes_in_zone_DE => 3,
                :prs_storage => Dict(:name => ["prs_n2"],:cap => 12, :vol => 55)
            )
        )
    end,
    # Purpose-built case for bidirectional non-dispatchable redispatch.
    #
    # Two zones (Z1 = {n1}, Z2 = {n2, n3}) on a meshed triangle with equal susceptances,
    # slack at n1. Wind sits at n3 (400 MW), gas at n1 (300 MW, mc 50); load is 100 at n1
    # and 80 at n2. The NTC of 40 caps Z2's export, so the day-ahead has to curtail wind
    # (gen 120, CU 280) while gas runs at 60 — economic curtailment, the wind is still
    # blowing.
    #
    # Nodally that schedule overloads line l1 (n1-n2, capacity 5). Because n1 is the slack,
    # gas cannot shift the flow on l1 on its own; the only lever is the injection at n3,
    # whose PTDF on l1 is negative. So the congestion is relieved by *recalling* curtailed
    # wind at n3 and taking gas down at n1 — impossible before non-dispatchables could be
    # redispatched upward, where the model instead has to resort to lost load at n2.
    "case 3" => let
        filepath = joinpath(@__DIR__, "data", "test_data_3_nodes_res_recall")
        Dict(
            :filepath => filepath,
            :data_files => make_data_files(filepath; files = Dict(
                :plants => "plants.csv",
                :nodes => "nodes.csv",
                :zones => "zones.csv",
                :lines => "lines.csv",
                :dclines => "dclines.csv",
                :demand => "nodal_load.csv",
                :types => "planttypes.csv",
                :ntc => "ntc.csv",
            )),
            :expected => Dict(
                :da_gen => Dict("g1" => 60.0, "w3" => 120.0),
                :da_cu => Dict("w3" => 280.0),
                # per hour, with recall enabled
                :res_recall => 25.0,
                :disp_down => 25.0,
            )
        )
    end,

)