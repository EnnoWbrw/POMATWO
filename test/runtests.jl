println("Testing...")
using Test
using POMATWO
using HiGHS
using JuMP
using JuMP.Containers
using DataFrames
using Logging
@testset "POMATWO.jl" begin
    include(joinpath("test_cases", "cases.jl"))
    include(joinpath("test_cases", "test_data_load.jl"))
    include(joinpath("test_cases", "test_model_config.jl"))
    include(joinpath("test_cases", "test_data_reporting.jl"))
    include(joinpath("test_cases", "test_network_validation.jl"))
    test_data_load()
    test_model_creation()
    test_data_reporting()
end
 