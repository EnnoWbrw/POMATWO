"""
Helper function to reconstruct a Parameters object from a JLD2.ReconstructedMutable
or any object with similar field structure. Attempts to extract known fields and
create a new Parameters with defaults for any missing fields.
"""
function reconstruct_parameters(old_obj)
    try
        # Get all field names from the current Parameters struct
        current_fields = fieldnames(Parameters)
        
        # Try to extract values from the old object
        kwargs = Dict{Symbol, Any}()
        
        for field in current_fields
            if hasproperty(old_obj, field)
                kwargs[field] = getproperty(old_obj, field)
            end
        end
        
        # Create a new Parameters with the extracted values
        # Any missing fields will use their defaults from the @kwdef struct
        return Parameters(; kwargs...)
    catch e
        @warn "Failed to reconstruct Parameters from old object: $(typeof(e)) - $(e)"
        return Parameters()
    end
end

"""
    DataFiles

A container for loading and storing output data related to a model run. Each field corresponds to a specific dataset represented as a `DataFrame`.
The constructor can be called by providing the directory that contains the results. The path to the specific results of each model run consists of the 'resultdir' and the 'scenarioname' (see section [`ModelRun`](@ref)).
# Fields
- `params::Parameters`: Configuration and model parameters loaded from `params.jld2`.
- `CHARGE::DataFrame`: Charging data for storage units.
- `EXCHANGE::DataFrame`: Net position per zone.
- `BIL_EXCHANGE::DataFrame`: Bilateral exchange per zone pair (`From`, `To`).
- `GEN::DataFrame`: Power generation data.
- `REDISP::DataFrame`: Redispatch actions and adjustments.
- `PRS::DataFrame`: Prosumer results.
- `LINEFLOW::DataFrame`: AC line power flow data.
- `DCLINEFLOW::DataFrame`: DC line power flow data.
- `NETINPUT::DataFrame`: Net input to zones or nodes.
- `NTC::DataFrame`: **Legacy.** The name `BIL_EXCHANGE` was written under before the
  rename; populated only when loading a result directory produced by an older version.
- `STO_LVL::DataFrame`: Storage level data of the day-ahead stage.
- `STO_LVL_REDISP::DataFrame`: Storage levels of the redispatch stage (equivalently
  `DataFiles(dir, Redispatch).STO_LVL`).
- `ZonalMarketBalance::DataFrame`: Market balance data aggregated per zone.
- `NodalMarketBalance::DataFrame`: Market balance data at the nodal level.
- `NodalMarketRedispBalance::DataFrame`: Redispatch-adjusted nodal market balance.
- `FBMC_INF::DataFrame`: FBMC infeasibility slack values per CNE line and time period.
- `RAM::DataFrame`: Flow-based domain as used by the day-ahead FBMC constraints, per CNE line and time period: `RAM_POS`/`RAM_NEG` (remaining available margin), `F0` (basecase reference flow the RAM was derived from), `fmax` (line capacity) and the `FRM`/`minRAM` fractions of that run. The 70 %-rule is reproducible from the table alone: `RAM_POS == max(fmax - F0 - FRM*fmax, minRAM*fmax)`. Empty for runs without a flow-based exchange formulation.
- `REFDAY_MATCH::DataFrame`: Reference-day basecase trace — per (group, target_time) the matched reference time, cluster metadata (may be `missing` where a join found no counterpart) and whether the global fallback match was used. Empty for runs without a [`ReferenceDayBasecase`](@ref).
- `REFDAY_GROUPS::DataFrame`: Reference-day basecase trace — group → node membership of the matching scope (join with `REFDAY_MATCH` on `:group` for per-node reference times, see [`refday_reference_times`](@ref)). Loaded from the scenario root, not the subrun folders.
- `REFDAY_SHIFT::DataFrame`: Reference-day basecase trace — sparse per (Time, node, component) net-injection deltas applied by the shift (physical levers `RES_prestep`, `RES`, `conv`, `load`, `sto`, plus `balance` from the global balance pass; for `load` the actual load change is `-delta`). Also carries per (Time, zone) `np_relax` rows (zone label in the `node` column) recording how far each zone's net position was left relaxed toward the reference.

# Constructors
```julia
DataFiles(dir::String)                      # composite view across stages (see below)
DataFiles(dir::String, Redispatch)          # one market state, dispatched on its type
DataFiles(dir::String; type = "REDISP")     # same, by name or legacy alias
```

Each [`MarketState`](@ref) writes its result tables under its own filename prefix
(`DayAhead_GEN.arrow`, `Redispatch_NETINPUT.arrow`, ...; see [`result_prefix`](@ref)), so
stages of the same run never overwrite each other.

`DataFiles(dir)` returns a **composite** view: per table the latest pipeline stage that
wrote it wins (`Redispatch` > `ProsumerOptimizationState` > `DayAhead`), which is what a
single result set looked like before the per-stage prefixes existed. `TwoDayAhead` is
excluded — a flow-based basecase is reachable only via an explicit
`DataFiles(dir, TwoDayAhead)`. Two tables are pinned rather than resolved by recency:
`STO_LVL` always comes from the day-ahead, and the redispatch levels appear as
`STO_LVL_REDISP`.

Result directories written before per-stage prefixes still load: a directory containing no
stage-prefixed file at all is treated as a legacy layout and read under the old names.

# Example
```julia

results_path = joinpath("results", scen_name)

### reading in the result files
results = DataFiles(results_path)

### only the day-ahead stage, e.g. to inspect flows the redispatch stage used to overwrite
da = DataFiles(results_path, DayAhead)
```
"""
struct DataFiles
    params::Parameters

    CHARGE::DataFrame
    EXCHANGE::DataFrame
    BIL_EXCHANGE::DataFrame
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
    FBMC_INF::DataFrame
    RAM::DataFrame
    REFDAY_MATCH::DataFrame
    REFDAY_GROUPS::DataFrame
    REFDAY_SHIFT::DataFrame

    function DataFiles(dir; type = nothing)
        folders = filter(isdir, readdir(dir, join = true))
        subrun_folders = filter(x -> occursin(r"subrun", x), folders)
        legacy = _is_legacy_layout(subrun_folders)

        # `type = ""` kept meaning "everything in one view" before per-stage prefixes
        state = (type === nothing || isempty(type)) ? nothing : market_state_type(type)

        self = Dict{Symbol,DataFrame}()
        fields = fieldnames_excl(DataFiles, [:params])

        # tables stored once at the scenario root instead of per subrun folder
        root_tables = (:REFDAY_GROUPS,)

        for name in fields
            if name in root_tables
                file = joinpath(dir, "$name.arrow")
                self[name] = isfile(file) ? load_arrow_unlocked([file]) : DataFrame()
                continue
            end
            self[name] = _load_table(subrun_folders, name, state, legacy)
        end

        values = [self[field] for field in fields]

        # Load params with backward compatibility: fall back to an empty Parameters()
        # when the stored struct schema doesn't match the current Parameters type.
        params_file = joinpath(dir, "params.jld2")
        params::Parameters = try
            loaded = load_object(params_file)
            # Check if it's the correct type; if not, try to reconstruct or fall back
            if loaded isa Parameters
                loaded
            else
                @warn "Loaded params is not a Parameters type (got $(typeof(loaded))); using default Parameters()"
                Parameters()
            end
        catch e
            # Try a secondary path: open the file with JLD2.load and see if we can reconstruct
            try
                obj = JLD2.load(params_file)
                # JLD2 may return a ReconstructedMutable object when the struct changed
                # Try to extract field values and build a new Parameters
                if haskey(obj, "single_stored_object")
                    loaded = obj["single_stored_object"]
                    if loaded isa Parameters
                        loaded
                    else
                        # Try to reconstruct from field values
                        reconstruct_parameters(loaded)
                    end
                else
                    @warn "Could not find params in $(params_file); using default Parameters()"
                    Parameters()
                end
            catch inner_e
                @warn "Could not load params from $(params_file); using default Parameters() due to: $(typeof(e)) - $(e)"
                Parameters()
            end
        end

        return new(params, values...)
    end
end

"""
    DataFiles(dir, ::Type{MS}) where {MS<:MarketState}

Load the result tables written by one market state, e.g.
`DataFiles(dir, Redispatch)`. Preferred over the string form.
"""
DataFiles(dir, ::Type{MS}) where {MS<:MarketState} = DataFiles(dir; type = result_prefix(MS))

### Result-file resolution
#
# A stage-prefixed file is `<StateName>_<TABLE>.arrow`. A directory holding none of those
# was written before per-stage prefixes existed and is read under the old names instead.
# Detection is per directory, not per file, so an explicit `type = "2DA"` on a legacy
# directory can never silently fall back to day-ahead data.

"""Canonical stage prefix of a result filename, or `nothing` when it carries none."""
function _file_stage(filename::AbstractString)
    i = findfirst('_', filename)
    i === nothing && return nothing
    T = trymarket_state_type(filename[1:prevind(filename, i)])
    return T === nothing ? nothing : result_prefix(T)
end

_is_legacy_layout(subrun_folders) = !any(
    _file_stage(f) !== nothing
    for folder in subrun_folders for f in readdir(folder) if endswith(f, ".arrow")
)

# Stages that make up the default composite view, latest pipeline stage first. TwoDayAhead
# is deliberately absent: a flow-based basecase is only reachable by asking for it. A new
# MarketState needs an entry here only if it should take part in the default view.
const COMPOSITE_STATES = (Redispatch, ProsumerOptimizationState, DayAhead)

# Tables that belong to the run rather than to a market state, and so are never prefixed.
const UNPREFIXED_TABLES = (:REFDAY_MATCH, :REFDAY_SHIFT)

const _Candidate = Tuple{Union{DataType,Nothing},Symbol}

"""
    _candidates(field, state, legacy) -> Vector{_Candidate}

Files to try for one `DataFiles` field, in priority order. `nothing` as the state means the
legacy unprefixed name.
"""
function _candidates(field::Symbol, state, legacy::Bool)::Vector{_Candidate}
    # Reference-day traces belong to the run, not to a stage, and are always unprefixed.
    field in UNPREFIXED_TABLES && return _Candidate[(nothing, field)]
    # `STO_LVL` has always meant the day-ahead levels; the redispatch stage's levels are a
    # separate field, so neither is resolved by recency.
    if state === nothing
        field === :STO_LVL        && return [(DayAhead, :STO_LVL), (nothing, :STO_LVL)]
        field === :STO_LVL_REDISP && return [(Redispatch, :STO_LVL), (nothing, :STO_LVL_REDISP)]
        field === :NTC            && return [(nothing, :NTC)]           # pre-rename name only
        field === :BIL_EXCHANGE   && return vcat([(S, field) for S in COMPOSITE_STATES],
                                                 [(nothing, :BIL_EXCHANGE), (nothing, :NTC)])
        return vcat([(S, field) for S in COMPOSITE_STATES], [(nothing, field)])
    end
    # explicit stage
    field === :STO_LVL_REDISP &&
        return state === Redispatch ? _Candidate[(Redispatch, :STO_LVL)] : _Candidate[]
    field === :NTC && return legacy ? _Candidate[(nothing, :NTC)] : _Candidate[]
    out = _Candidate[(state, field)]
    legacy && push!(out, (nothing, field))
    return out
end

"""Legacy filename of `table` for `state`: unprefixed, except the basecase's `2DA`."""
_legacy_name(state, table::Symbol) = state === TwoDayAhead ? "2DA$table" : string(table)

function _load_table(subrun_folders, field::Symbol, state, legacy::Bool)
    for (S, table) in _candidates(field, state, legacy)
        # a legacy directory holds no prefixed files at all, so only try those it can have
        S !== nothing && legacy && continue
        fname = S === nothing ? _legacy_name(state, table) : "$(result_prefix(S))_$(table)"
        files = [joinpath(folder, "$fname.arrow") for folder in subrun_folders]
        filter!(isfile, files)
        isempty(files) || return load_arrow_unlocked(files)
    end
    return DataFrame()
end

function load_arrow_unlocked(files::Vector{String})
    dfs = DataFrame[]
    sizehint!(dfs, length(files))

    for f in files
        # Important: isolate lifetime in a local scope
        df = let
            bytes = read(f)                      # file handle closes immediately
            tbl = Arrow.Table(bytes)             # in-memory bytes, no file mmap
            DataFrame(tbl; copycols=true)        # detach from Arrow columns
        end
        push!(dfs, df)
    end

    # Combine after all files are detached
    return isempty(dfs) ? DataFrame() : vcat(dfs...; cols=:union)
end

"""
    refday_reference_times(results::DataFiles) -> DataFrame

Per-(node, target_time) reference times of a reference-day basecase run:
`REFDAY_GROUPS ⋈ REFDAY_MATCH` on `:group`. Empty (with a warning) when the
results carry no reference-day trace.
"""
function refday_reference_times(results::DataFiles)
    if isempty(results.REFDAY_GROUPS) || isempty(results.REFDAY_MATCH)
        @warn "refday_reference_times: results carry no reference-day trace (not a ReferenceDayBasecase run?)."
        return DataFrame()
    end
    return innerjoin(results.REFDAY_GROUPS, results.REFDAY_MATCH; on = :group)
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

    zone_plants = Set(get(results.params.plants_in_zone, zone, String[]))
    gen_by_type = @chain getfield(results, kind) begin
        transform(:index => ByRow(x -> get(results.params.plant_type, x, "unknown")) => :type)
        filter(:index => x -> x in zone_plants, _)
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

"""
    get_redispatch_by_type_node(results::DataFiles)

Calculates the difference between day-ahead generation (GEN) and redispatch generation (GEN_REDISP) 
for each technology type at each node across all time steps.

# Arguments
- `results::DataFiles`: DataFiles object containing generation data, redispatch data, and parameters.

# Returns
A DataFrame with the following columns:
- `Time`: Time step
- `node`: Node identifier
- `type`: Technology/plant type
- `GEN`: Day-ahead generation value
- `GEN_REDISP`: Redispatch generation value
- `difference`: The difference (GEN_REDISP - GEN), representing redispatch adjustments

Positive differences indicate upward redispatch, negative values indicate downward redispatch.

# Notes
- Only includes plants that appear in both GEN and REDISP data.
- Results are grouped by Time, node, and technology type.
- Empty DataFrames for GEN or REDISP will result in an empty output DataFrame.

# Example
```julia
julia> redispatch_diff = get_redispatch_by_type_node(results)
100×6 DataFrame
 Row │ Time   node    type     GEN      GEN_REDISP  difference
     │ Int64  String  String   Float64  Float64     Float64
─────┼──────────────────────────────────────────────────────────
   1 │     1  N1      wind      60.0        65.0         5.0
   2 │     1  N1      coal       0.0         0.0         0.0
   3 │     2  N2      gas       50.0        45.0        -5.0
  ⋮  │   ⋮      ⋮       ⋮        ⋮          ⋮           ⋮
```
"""
function get_redispatch_by_type_node(results::DataFiles)
    # Check if GEN and REDISP data are available
    if isempty(results.GEN) || isempty(results.REDISP)
        @warn "GEN or REDISP data is empty. Returning empty DataFrame."
        return DataFrame(
            Time = Int[],
            node = String[],
            type = String[],
            GEN = Float64[],
            GEN_REDISP = Float64[],
            difference = Float64[]
        )
    end

    # Process GEN data: add node and type information
    gen_by_node_type = @chain results.GEN begin
        transform!(
            :index => ByRow(x -> results.params.plant2node[x]) => :node,
            :index => ByRow(x -> results.params.plant_type[x]) => :type
        )
        select(:Time, :node, :type, :index, :GEN)
        groupby([:Time, :node, :type])
        DataFrames.combine(:GEN => sum => :GEN)
    end

    # Process REDISP data: add node and type information
    redisp_by_node_type = @chain results.REDISP begin
        transform!(
            :index => ByRow(x -> results.params.plant2node[x]) => :node,
            :index => ByRow(x -> results.params.plant_type[x]) => :type
        )
        select(:Time, :node, :type, :index, :GEN_REDISP)
        groupby([:Time, :node, :type])
        DataFrames.combine(:GEN_REDISP => sum => :GEN_REDISP)
    end

    # Join the two dataframes and calculate difference
    result = leftjoin(gen_by_node_type, redisp_by_node_type, 
                     on = [:Time, :node, :type])
    
    # Replace missing values with 0.0 (in case some nodes/types only appear in one dataset)
    result.GEN_REDISP = coalesce.(result.GEN_REDISP, 0.0)
    
    # Calculate the difference (redispatch adjustment)
    result.difference = result.GEN_REDISP .- result.GEN
    
    # Sort for better readability
    sort!(result, [:Time, :node, :type])
    
    return result
end

"""
    get_market_statistics(results::DataFiles, zone::String="DE")

Calculate statistical overview of key market parameters for a specified zone.

Computes descriptive statistics (mean, median, standard deviation, min, max, sum) 
for exchange flows, lost load events, and market prices in the given zone. Returns 
both a summary statistics table and a time series dataframe for detailed analysis.

# Arguments
- `results::DataFiles`: DataFiles object containing model results with EXCHANGE and ZonalMarketBalance data.
- `zone::String="DE"`: Zone identifier for which to calculate statistics. Defaults to "DE".

# Returns
A tuple containing two DataFrames:
1. **Statistics DataFrame**: Contains rows for each statistic (mean, median, std, min, max, sum) 
   for three parameters (Exchange, Lost_Load, Price). Additional rows with `NaN` values mark 
   the presence of time series data. Columns are:
   - `metric::String`: The statistical measure or "timeseries"
   - `parameter::String`: The parameter name (Exchange, Lost_Load, or Price)
   - `value::Float64`: The computed statistical value (or value vector for timeseries markers)

If EXCHANGE or ZonalMarketBalance data is empty, returns empty DataFrames with appropriate structure.

# Notes
- Lost Load statistics include a `count_positive` metric indicating the number of time steps 
  with positive lost load events.
- Exchange values represent net flows for the specified zone.
- Prices are extracted from the MarketBalance column of ZonalMarketBalance.

# Example
```julia
julia> stats_df = get_market_statistics(results, "DE")

julia> stats_df
18×3 DataFrame
 Row │ metric          parameter   value    
     │ String          String      Float64  
─────┼─────────────────────────────────────
   1 │ mean            Exchange     150.5
   2 │ median          Exchange     145.0
   3 │ std             Exchange      45.2
   ⋮  │       ⋮             ⋮          ⋮
"""
function get_market_statistics(results::DataFiles, zone::String="DE")
    if isempty(results.EXCHANGE) || isempty(results.ZonalMarketBalance)
        @warn "EXCHANGE or ZonalMarketBalance data is empty. Returning empty DataFrame. Nodal market statistics currently not available."
        return DataFrame(
            metric = String[],
            parameter = String[],
            value = Float64[]
        )
    end

    if !(zone in results.params.sets.Z)
        @warn "Zone '$zone' not found in EXCHANGE data. Returning empty DataFrame."
        return DataFrame(
            metric = String[],
            parameter = String[],
            value = Float64[]
        )
    end
    # Extract Exchange data for the specified zone
    zone_exchange = filter(row -> row.index == zone, results.EXCHANGE)
    
    # Extract market balance data for the specified zone
    market_zone = filter(row -> row.Zone == zone, results.ZonalMarketBalance)
    
    # Filter for positive lost load events
    LL_zone = filter(row -> row.LL > 0, market_zone)
    
    # Extract time series
    exchange_series = zone_exchange.EXCHANGE
    ll_series = market_zone.LL
    price_series = market_zone.MarketBalance
    
    # Create statistical summary DataFrame
    stats_df = POMATWO.DataFrame(
        metric = String[],
        parameter = String[],
        value = Union{Int64, Vector{Int64},Float64, Vector{Float64}}[]
    )
    
    # Exchange statistics
    push!(stats_df, ("mean", "Exchange", mean(exchange_series)))
    push!(stats_df, ("median", "Exchange", median(exchange_series)))
    push!(stats_df, ("std", "Exchange", std(exchange_series)))
    push!(stats_df, ("min", "Exchange", minimum(exchange_series)))
    push!(stats_df, ("max", "Exchange", maximum(exchange_series)))
    push!(stats_df, ("sum", "Exchange", sum(exchange_series)))
    
    # Lost Load statistics
    push!(stats_df, ("mean", "Lost_Load", mean(ll_series)))
    push!(stats_df, ("median", "Lost_Load", median(ll_series)))
    push!(stats_df, ("std", "Lost_Load", std(ll_series)))
    push!(stats_df, ("min", "Lost_Load", minimum(ll_series)))
    push!(stats_df, ("max", "Lost_Load", maximum(ll_series)))
    push!(stats_df, ("sum", "Lost_Load", sum(ll_series)))
    push!(stats_df, ("count_positive", "Lost_Load", Float64(nrow(LL_zone))))
    
    # Price statistics
    push!(stats_df, ("mean", "Price", mean(price_series)))
    push!(stats_df, ("median", "Price", median(price_series)))
    push!(stats_df, ("std", "Price", std(price_series)))
    push!(stats_df, ("min", "Price", minimum(price_series)))
    push!(stats_df, ("max", "Price", maximum(price_series)))
    
    # Add time series as a single row
    push!(stats_df, ("timeseries", "Exchange", exchange_series))
    push!(stats_df, ("timeseries", "Lost_Load", ll_series))
    push!(stats_df, ("timeseries", "Price", price_series))
    push!(stats_df, ("timeseries", "Time", market_zone.Time))
    return stats_df
end

"""
    check_infeasibility(results::DataFiles; tol=1e-6) -> DataFrame

Scans a `DataFiles` result object for non-zero infeasibility variables and returns a
summary of any violations found.

Checks all infeasibility slack variables written to the result tables:

| Source | Column | Description |
|---|---|---|
| `ZonalMarketBalance` | `LL`, `CU` | Zonal lost load / curtailment not handled by plant specific curtailment |
| `NodalMarketBalance` | `LL`, `CU` | Nodal lost load / curtailment not handled by plant specific curtailment |
| `NodalMarketRedispBalance` | `LL`, `CU` | Redispatch nodal lost load / curtailment  not handled by plant specific curtailment |
| `FBMC_INF` | `FBMC_INF_POS`, `FBMC_INF_NEG` | FBMC RAM constraint slacks |
| `STO_LVL` | `inf` | Day-ahead storage balance slack (`INF_POS - INF_NEG`, signed) |
| `STO_LVL_REDISP` | `inf` | Redispatch storage balance slack (signed) |
| `PRS` | `INF` | Prosumer energy balance slack |

# Arguments
- `results::DataFiles`: The loaded result object to inspect.
- `tol::Float64`: Tolerance below which absolute values are considered zero (default: `1e-6`).

# Returns
A `DataFrame` with columns:
- `source`: Name of the result table where the violation was found.
- `variable`: Name of the infeasibility column.
- `count`: Number of rows with `abs(value) > tol`.
- `total`: Sum of absolute values of all violating entries.
- `max`: Maximum absolute value observed.

Returns an empty DataFrame (same schema) when no infeasibilities are detected.

# Example
```julia
julia> check_infeasibility(results)
2×5 DataFrame
 Row │ source               variable      count  total     max
     │ String               String        Int64  Float64   Float64
─────┼────────────────────────────────────────────────────────────
   1 │ ZonalMarketBalance   LL                3    450.0   200.0
   2 │ FBMC_INF             FBMC_INF_POS      1     12.5    12.5
```
"""
function check_infeasibility(results::DataFiles; tol::Float64=1e-6)
    report = DataFrame(
        source   = String[],
        variable = String[],
        count    = Int[],
        total    = Float64[],
        max      = Float64[],
    )

    # Push a row if any abs(value) > tol in the column
    function _check!(source_name, df, col; signed=false)
        isempty(df) && return
        hasproperty(df, col) || return
        vals = Float64.(df[!, col])
        absvals = abs.(vals)
        mask = absvals .> tol
        any(mask) || return
        push!(report, (source_name, string(col), sum(mask), sum(absvals[mask]), maximum(absvals[mask])))
    end

    # Market balance slacks — CU and LL are non-negative by construction
    for (source, df) in (
        ("ZonalMarketBalance",       results.ZonalMarketBalance),
        ("NodalMarketBalance",       results.NodalMarketBalance),
        ("NodalMarketRedispBalance", results.NodalMarketRedispBalance),
    )
        _check!(source, df, :LL)
        _check!(source, df, :CU)
    end

    # FBMC RAM slacks
    _check!("FBMC_INF", results.FBMC_INF, :FBMC_INF_POS)
    _check!("FBMC_INF", results.FBMC_INF, :FBMC_INF_NEG)

    # Storage balance slack: signed expression INF_POS - INF_NEG stored as `inf`.
    # Both stages have their own storage balance, so both are scanned.
    _check!("STO_LVL", results.STO_LVL, :inf; signed=true)
    _check!("STO_LVL_REDISP", results.STO_LVL_REDISP, :inf; signed=true)

    # Prosumer energy balance slack
    _check!("PRS", results.PRS, :INF)

    if isempty(report)
        @info "No infeasibilities detected (tolerance = $tol)."
    else
        @warn "Infeasibilities detected in $(nrow(report)) variable(s):" report
    end

    return report
end
