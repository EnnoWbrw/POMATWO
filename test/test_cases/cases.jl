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

)