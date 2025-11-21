println("Testing...")
using Test
using POMATWO
using HiGHS
using JuMP
using JuMP.Containers
using DataFrames
using Logging
using Statistics
using Arrow
using JLD2

function create_test_params(;
    nodes=String[],
    lines=String[],
    zones=["zone1"],
    plants=["plant1"],
    line_start=Dict{String,String}(),
    line_end=Dict{String,String}(),
    reactance=Dict{String,Float64}(),
    resistance=Dict{String,Float64}(),
    slack=String[]
)
    sets = POMATWO.Sets(
        N=nodes,
        L=lines,
        Z=zones,
        P=plants,
        S=String[],
        DC=String[],
        DISP=String[],
        NDISP=String[],
        NTC=Tuple{String,String}[],
        PRS=String[],
        PRS_STO=String[]
    )
    
    return POMATWO.Parameters(
        sets=sets,
        line_start=line_start,
        line_end=line_end,
        reactance=reactance,
        resistance=resistance,
        slack=slack
    )
end

"""
    create_mock_datafiles(; zones, nodes, exchange_data, zonal_balance_data, additional_data)

Create a mock DataFiles struct for testing purposes by writing temporary Arrow files
and loading them through the standard DataFiles constructor.

# Arguments
- `zones::Vector{String}`: List of zone names (default: ["Zone1", "Zone2"])
- `nodes::Vector{String}`: List of node names (default: ["N1", "N2"])
- `plants::Vector{String}`: List of plant names (default: ["P1", "P2"])
- `n_timesteps::Int`: Number of timesteps to generate (default: 4)
- `exchange_data::Union{DataFrame,Nothing}`: Custom EXCHANGE DataFrame, or nothing to auto-generate
- `zonal_balance_data::Union{DataFrame,Nothing}`: Custom ZonalMarketBalance DataFrame, or nothing to auto-generate
- `additional_data::Dict{Symbol,DataFrame}`: Additional DataFrames to include (e.g., :GEN, :REDISP)

# Returns
- `DataFiles`: A properly constructed DataFiles struct with mock data

# Example
```julia
# Create simple two-zone mock with default data
results = create_mock_datafiles()

# Create custom mock with specific exchange values
custom_exchange = DataFrame(
    Time = [1, 2, 1, 2],
    index = ["Z1", "Z1", "Z2", "Z2"],
    EXCHANGE = [100.0, 150.0, -100.0, -150.0]
)
results = create_mock_datafiles(zones=["Z1", "Z2"], exchange_data=custom_exchange)
```
"""
function create_mock_datafiles(;
    zones::Vector{String} = ["Zone1", "Zone2"],
    nodes::Vector{String} = ["N1", "N2"],
    plants::Vector{String} = ["P1", "P2"],
    n_timesteps::Int = 4,
    exchange_data::Union{DataFrame,Nothing} = nothing,
    zonal_balance_data::Union{DataFrame,Nothing} = nothing,
    additional_data::Dict{Symbol,DataFrame} = Dict{Symbol,DataFrame}()
)
    # Create mock Parameters
    params = create_test_params(
        zones=zones,
        nodes=nodes,
        plants=plants
    )
    
    # Generate default EXCHANGE data if not provided
    if isnothing(exchange_data)
        n_zones = length(zones)
        exchange_data = DataFrame(
            Time = repeat(1:n_timesteps, n_zones),
            index = vcat([fill(z, n_timesteps) for z in zones]...),
            EXCHANGE = vcat(
                # First zone exports
                [100.0 * i for i in 1:n_timesteps],
                # Other zones import (negative values)
                [[-(100.0 * i) / (n_zones - 1) for i in 1:n_timesteps] for _ in 2:n_zones]...
            )
        )
    end
    
    # Generate default ZonalMarketBalance data if not provided
    if isnothing(zonal_balance_data)
        n_zones = length(zones)
        zonal_balance_data = DataFrame(
            Time = repeat(1:n_timesteps, n_zones),
            Zone = vcat([fill(z, n_timesteps) for z in zones]...),
            MarketBalance = vcat([45.0 .+ rand(n_timesteps) .* 10 for _ in zones]...),
            LL = vcat([rand([0.0, 0.0, 0.0, 5.0, 10.0], n_timesteps) for _ in zones]...)
        )
    end
    
    # Create a temporary directory and write test data
    temp_dir = mktempdir()
    subrun_dir = joinpath(temp_dir, "subrun_t1-t$(n_timesteps)")
    mkpath(subrun_dir)
    
    # Write the required data files using Arrow format
    Arrow.write(joinpath(subrun_dir, "EXCHANGE.arrow"), exchange_data)
    Arrow.write(joinpath(subrun_dir, "ZonalMarketBalance.arrow"), zonal_balance_data)
    
    # Write any additional data files
    for (name, df) in additional_data
        Arrow.write(joinpath(subrun_dir, "$(name).arrow"), df)
    end
    
    # Save params
    save_object(joinpath(temp_dir, "params.jld2"), params)
    
    # Create DataFiles from the temporary directory
    results = DataFiles(temp_dir)
    
    # Note: Not cleaning up temp_dir here because:
    # 1. mktempdir() directories are auto-cleaned when Julia exits
    # 2. Immediate cleanup can cause issues on Windows with file locking
    
    return results
end

@testset "POMATWO.jl" begin
    include(joinpath("test_cases", "cases.jl"))
    include(joinpath("test_cases", "test_data_load.jl"))
    include(joinpath("test_cases", "test_model_config.jl"))
    include(joinpath("test_cases", "test_data_reporting.jl"))
    include(joinpath("test_cases", "test_network_validation.jl"))
    include(joinpath("test_cases", "test_ptdf_omission.jl"))
    include(joinpath("test_cases", "test_data_load_validations.jl"))
    include(joinpath("test_cases", "test_read_output.jl"))
    test_data_load()
    test_model_creation()
    test_data_reporting()
    test_read_output()
end
 