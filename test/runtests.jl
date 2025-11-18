println("Testing...")
using Test
using POMATWO
using HiGHS
using JuMP
using JuMP.Containers
using DataFrames
using Logging

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
 