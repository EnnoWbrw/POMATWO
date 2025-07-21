"""
    DataFiles

A container for loading and storing output data related to a model run. Each field corresponds to a specific dataset represented as a `DataFrame`.
The constructor can be called by providing the directory that contains the results. The path to the specific results of each model run consists of the 'resultdir' and the 'scenarioname' (see section [`ModelRun`](@ref)).
# Fields
- `params::Parameters`: Configuration and model parameters loaded from `params.jld2`.
- `CHARGE::DataFrame`: Charging data for storage units.
- `EXCHANGE::DataFrame`: Cross-border or inter-zonal energy exchange data.
- `FEEDIN::DataFrame`: Feed-in data from renewable or other sources.
- `GEN::DataFrame`: Power generation data.
- `REDISP::DataFrame`: Redispatch actions and adjustments.
- `PRS::DataFrame`: Price or reserve-related data.
- `LINEFLOW::DataFrame`: AC line power flow data.
- `DCLINEFLOW::DataFrame`: DC line power flow data.
- `NETINPUT::DataFrame`: Net input to zones or nodes.
- `NTC::DataFrame`: Net Transfer Capacities between zones.
- `STO_LVL::DataFrame`: Storage level data.
- `STO_LVL_REDISP::DataFrame`: Redispatch-related storage level changes.
- `ZonalMarketBalance::DataFrame`: Market balance data aggregated per zone.
- `NodalMarketBalance::DataFrame`: Market balance data at the nodal level.
- `NodalMarketRedispBalance::DataFrame`: Redispatch-adjusted nodal market balance.

# Constructor
```julia
DataFiles(dir::String)
```
# Example
```julia

results_path = joinpath("results", scen_name)

### reading in the result files
results = DataFiles(results_path)
```
"""
struct DataFiles
    params::Parameters

    CHARGE::DataFrame
    EXCHANGE::DataFrame
    FEEDIN::DataFrame
    GEN::DataFrame
    REDISP::DataFrame
    PRS::DataFrame
    LINEFLOW::DataFrame
    DCLINEFLOW::DataFrame
    NETINPUT::DataFrame
    NTC::DataFrame
    STO_LVL::DataFrame
    STO_LVL_REDISP::DataFrame
    ZonalMarketBalance::DataFrame
    NodalMarketBalance::DataFrame
    NodalMarketRedispBalance::DataFrame

    function DataFiles(dir)
        folders = filter(isdir, readdir(dir, join = true))
        subrun_folders = filter(x -> occursin(r"subrun", x), folders)

        self = Dict{Symbol,DataFrame}()
        fields = fieldnames_excl(DataFiles, [:params])

        for name in fields

            table_files = String[]
            sname = string(name)

            for folder in subrun_folders
                file = joinpath(folder, "$sname.arrow")
                isfile(file) && push!(table_files, file)
            end

            if !isempty(table_files)
                df = Arrow.Table(table_files) |> DataFrame
                self[name] = df
            else
                self[name] = DataFrame()
            end
        end

        values = [self[field] for field in fields]
        params = load_object(joinpath(dir, "params.jld2"))

        return new(params, values...)
    end
end

function fieldnames_excl(type, excl::Vector{Symbol})
    fields = fieldnames(type) |> collect
    filter!(x -> x ∉ excl, fields)
end

function Base.show(io::IO, df::DataFiles)

    fields = fields = fieldnames_excl(DataFiles, [:params])

    for field in fields
        dataframe = getfield(df, field)
        cols = names(dataframe)
        nrows = size(dataframe, 1)
        str = "$field:\n rows -> $nrows \n columns -> $(join(cols, ", "))"
        println(io, str)
    end
end

"""
    transform_results_by_type(results, kind, zone)

Aggregates generation results by plant type and time for a specified market kind and zone.

# Arguments
- `results`: [DataFiles](@ref) object containing generation data and parameters.
- `kind`: Symbol or string specifying the market result to extract (`:REDISP`, `:GEN`, or `:DA`).
- `zone`: The name or key of the market zone to filter on.

# Returns
A DataFrame with time as rows and columns for each plant type, containing the sum of generation for each time step and plant type in the specified zone.

# Notes
- For `kind = :REDISP`, uses the `GEN_REDISP` field.
- For `kind = :GEN` or `:DA`, uses the `GEN` field (`:GEN` and `:DA` are treated identically).
- If an unsupported kind is given, a warning is issued and `nothing` is returned.

# Example
```Julia
julia> transform_results_by_type(results, :DA, "DE")
4×3 DataFrame
 Row │ Time   wind      coal     
     │ Int64  Float64?  Float64?
─────┼───────────────────────────
   1 │     1      60.0       0.0
   2 │     2     100.0       0.0
   3 │     3     120.0       0.0
   4 │     4     140.0      40.0
```
"""
function transform_results_by_type(results, kind, zone)
    kind = isa(kind, Symbol) ? kind : Symbol(kind)
    if kind == :REDISP
        gen = :GEN_REDISP
    elseif kind == :GEN
        gen = :GEN
    elseif kind == :DA
        gen = :GEN
        kind = :GEN
    else
        @warn "kind not supported. Supported kinds are: :REDISP - for Redispatch,  :GEN and :DA - for Day-Ahead. :GEN and :DA yield the same results"
        return nothing
    end

    gen_by_type = @chain getfield(results, kind) begin
        transform!(:index => ByRow(x -> results.params.plant_type[x]) => :type)
        filter(:index => x -> x in results.params.plants_in_zone[zone], _)
        select(:Time, :type, gen)
        groupby([:Time, :type])
        DataFrames.combine(gen => sum => :value)
        unstack(:Time, :type, :value)
        # remove :Time if you want only types as columns
        # select(Not(:Time))  # Uncomment if needed
    end

    return gen_by_type
end

"""
    summarize_result(result_table)

Summarizes a generation results table by summing each column (plant type) over all time steps.

# Arguments
- `result_table`: DataFrame produced by `transform_results_by_type`.

# Returns
A DataFrame with a single row, where each column contains the total sum of generation (over all time steps) for the corresponding plant type.

# Example
```julia
julia> summarize_result(transform_results_by_type(results, :DA, "DE"))
1×2 DataFrame
 Row │ wind     coal    
     │ Float64  Float64
─────┼──────────────────
   1 │   420.0     40.0
```
"""
function summarize_result(result_table)
    result_table = select(result_table, Not(:Time))
    summary = DataFrames.combine(result_table, All() .=> sum .=> identity)
    return summary
end
