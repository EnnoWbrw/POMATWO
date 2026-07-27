"""
    TimeHorizon(; start=1, stop=8760, split=24, offset=0)

Structure for defining a time horizon used in simulations or data analysis.

# Fields
- `start::Int`: The starting timestep (hour) of the time horizon (default: `1`).
- `stop::Int`: The ending timestep (hour) of the time horizon (default: `8760`).
- `split::Int`: The length (hours) of each subinterval or chunk (default: `24`).
- `offset::Int`: An offset (in timesteps or hours) applied to the time horizon (default: `0`). This allows subintervals that start at specific hours of the day. 

# Example
In this setup a time period of one year is used for market simulation. The optimizeation is cut into 365 subintervals, 
that start at hour 12 of each day.
```julia
setup = ModelSetup(;
    TimeHorizon =  TimeHorizon(start = 1, stop = 8760, split = 24, offset = 12),
    MarketType = ZonalMarket()),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle),
)
```
"""
Base.@kwdef struct TimeHorizon
    start::Int = 1
    stop::Int = 8760
    split::Int = 24
    offset::Int = 0
end

"""
    ModelSetup{T<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}

A container struct that holds the basic configuration for the market simulation model.

# Fields
- `Scenario::String`: A descriptive name or identifier for the model scenario.
- `TimeHorizon::TimeHorizon`: Time settings for the simulation (see section on 'TimeHorizon').
- `MarketType::T`: Type of market structure to simulate (see section 'MarketType'). Defaults to `ZonalMarket()`.
- `ProsumerSetup::ProsumerSetup`: Configuration of prosumer behavior in the model (see section 'ProsumerSetup'). Defaults to `NoProsumer()`.
- `RedispatchSetup::RedispatchSetup`: Configuration of redispatch modeling in the simulation (see section 'RedispatchSetup'). Defaults to `NoRedispatch()`.
- `StorageBoundary::StorageBoundary`: Boundary condition for storage levels at time-split edges (see [`StorageBoundary`](@ref)). Defaults to `CyclicStorage()`.
- `components::Vector{ModelComponent}`: Additional user-defined model components (see [`ModelComponent`](@ref)). Defaults to none.

This struct supports keyword-based construction using default values where provided.

# Example
```julia
ModelSetup(;
    TimeHorizon = TimeHorizon(; offset = 0, split = 24, stop = 48),
    MarketType = NodalMarket(PhaseAngle),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = NoRedispatch(),
    StorageBoundary = CyclicStorage()
)
```
"""
Base.@kwdef struct ModelSetup{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    TimeHorizon::TimeHorizon
    MarketType::MT = ZonalMarket()
    ProsumerSetup::PS = NoProsumer()
    RedispatchSetup::RD = NoRedispatch()
    StorageBoundary::StorageBoundary = CyclicStorage()
    components::Vector{ModelComponent} = ModelComponent[]
end

### Parameters
abstract type Profile{T} end
struct FixedProfile{T} <: Profile{T}
    val::T
end

struct HourlyProfile{T} <: Profile{T}
    val::Vector{T}

    function HourlyProfile(v::AbstractVector{T}) where {T}
        return new{T}(Vector{T}(v))
    end
end

# Concrete profile union used for the Parameters dictionaries. A small concrete
# union keeps profile access (`mc[p][t]` etc.) type-stable in the model-build hot
# loops; abstract `Profile`-valued dicts would force dynamic dispatch per lookup.
# `convert` methods let all construction sites keep storing any numeric profile —
# Dict setindex! converts to Float64 automatically.
const ConcreteProfile = Union{FixedProfile{Float64},HourlyProfile{Float64}}

Base.convert(::Type{ConcreteProfile}, p::FixedProfile{Float64}) = p
Base.convert(::Type{ConcreteProfile}, p::HourlyProfile{Float64}) = p
Base.convert(::Type{ConcreteProfile}, p::FixedProfile) = FixedProfile{Float64}(p.val)
Base.convert(::Type{ConcreteProfile}, p::HourlyProfile) = HourlyProfile(Float64.(p.val))

"""
    Sets

Container struct that holds all index sets for the model formulation.

# Fields
- `P`: All plants.
- `S`: All storage units.
- `DISP`: Dispatchable plant subset.
- `NDISP`: Non-dispatchable plant subset.
- `Z`: Zones.
- `N`: Nodes.
- `L`: AC lines.
- `DC`: DC lines.
- `NTC`: Tuple of zonal NTC identifiers.
- `PRS`: Prosumers.
- `PRS_STO`: Prosumers with storage.
"""
Base.@kwdef struct Sets
    P::Vector{String} = Vector{String}()
    S::Vector{String} = Vector{String}()
    DISP::Vector{String} = Vector{String}()
    NDISP::Vector{String} = Vector{String}()
    Z::Vector{String} = Vector{String}()
    N::Vector{String} = Vector{String}()
    L::Vector{String} = Vector{String}()
    DC::Vector{String} = Vector{String}()
    FBCCR::Vector{String} = Vector{String}()
    NTCCCR::Vector{String} = Vector{String}()
    NTC::Vector{Tuple{String,String}} = Vector{Tuple{String,String}}()
    PRS::Vector{String} = Vector{String}()
    PRS_STO::Vector{String} = Vector{String}()
end

"""
    Parameters

Container structure for all static and time-varying input data used in a power system model.

This struct encapsulates metadata, technical parameters, profiles, and mappings for generation units,
nodes, transmission infrastructure, demand, and other components relevant to electricity system modeling.
It is typically used as a central configuration object passed to optimization or simulation routines.

# Fields

## Sets
- `sets::Sets`: Collection of index sets (e.g., nodes, plants, zones) used across the model.

## Power plant parameters
- `gmax::Dict{String,Float64}`: Maximum generation capacity per plant.
- `eta::Dict{String,Float64}`: Efficiency of each plant.
- `gmax_storage::Dict{String,Float64}`: Maximum generation capacity from storage units.
- `storage::Dict{String,Float64}`: Energy storage capacity.
- `mc::Dict{String,ConcreteProfile}`: Marginal costs as time series profiles per plant.
- `avail::Dict{String,ConcreteProfile}`: Availability factor per plant over time.
- `avail_planttype_nodal::Dict{Tuple{String,String},ConcreteProfile}`: Time-dependent availability by (node, plant type).
- `avail_planttype_zonal::Dict{Tuple{String,String},ConcreteProfile}`: Time-dependent availability by (zone, plant type).
- `plant_type::Dict{String,String}`: Mapping from plant name to plant type.

## Plant type metadata
- `plant_type2color::Dict{String,String}`: Color coding for each plant type (for plotting).
- `dispatchable::Vector{String}`: List of dispatchable plant types.
- `nondispatchable::Vector{String}`: List of non-dispatchable plant types.
- `storage_types::Vector{String}`: List of storage technologies.
- `fuel_price::Dict{String,ConcreteProfile}`: Time-varying fuel price per plant type.
- `co2content::Dict{String,Float64}`: CO₂ emissions per MWh of each plant type.
- `historical_generation::Dict{String,ConcreteProfile}`: Historical generation profiles.
- `min_generation::Dict{String,ConcreteProfile}`: Minimum generation profiles.

## Node parameters
- `slack::Vector{String}`: Names of slack buses (reference nodes).
- `node2zone::Dict{String,String}`: Mapping from node to zone.
- `node_coords::Dict{String,Vector{Float64}}`: Coordinates of nodes (e.g., for plotting or distance-based calculations).

## AC line parameters
- `acline_capacity::Dict{String,Float64}`: Thermal capacity of each AC line.
- `resistance::Dict{String,Float64}`: Resistance per AC line.
- `reactance::Dict{String,Float64}`: Reactance per AC line.
- `bvector::Dict{String,Float64}`: Susceptance of each AC line.
- `circuits::Dict{String,Int64}`: Number of circuits per line.
- `voltage::Dict{String,Float64}`: Voltage level of each line.
- `line_start::Dict{String,String}`: Start node of each AC line.
- `line_end::Dict{String,String}`: End node of each AC line.

- `b::Dict{Tuple{String,String},Float64}`: Line susceptance between node pairs.
- `h::Dict{Tuple{String,String},Float64}`: Network matrix entries used in power flow approximations.
- `ptdf::Dict{Tuple{String,String},Float64}`: Power Transfer Distribution Factors between (line, node) pairs.

## DC line parameters
- `dcline_capacity::Dict{String,Float64}`: Transfer capacity of each DC line.
- `dc_start::Dict{String,String}`: Start node of each DC line.
- `dc_end::Dict{String,String}`: End node of each DC line.

## Demand parameters
- `nodal_load::Dict{String,ConcreteProfile}`: Time series of nodal demand.
- `zonal_load::Dict{String,ConcreteProfile}`: Time series of zonal demand.
- `inflow::Dict{String,ConcreteProfile}`: Time-dependent inflows to storage (e.g., hydro).
- `fixed_exchange::Dict{String,ConcreteProfile}`: Fixed cross-border or interzonal exchanges (e.g., from contracts or historical data).

## Zone parameters
- `ntc::Dict{Tuple{String,String},Float64}`: Net transfer capacity between zones.

## Prosumer parameters
- `prosumer_types::Vector{String}`: List of prosumer types modeled.
- `prs_demand::Dict{String,ConcreteProfile}`: Time series of demand from prosumers.
- `nodal_load_no_prs::Dict{String,ConcreteProfile}`: Nodal demand excluding prosumer influence.

## Mapping data
- `nodes_in_zone::Dict{String,Vector{String}}`: List of nodes per zone.
- `plants_in_zone::Dict{String,Vector{String}}`: Plants located in each zone.
- `storages_in_zone::Dict{String,Vector{String}}`: Storage units in each zone.
- `plants_in_node::Dict{String,Vector{String}}`: Plants located at each node.
- `storages_in_node::Dict{String,Vector{String}}`: Storage units at each node.
- `plant2node::Dict{String,String}`: Node location of each plant.
- `plant2zone::Dict{String,String}`: Zone location of each plant.
- `importing_ntcs::Dict{String,Vector{String}}`: NTCs importing into a given zone.
- `exporting_ntcs::Dict{String,Vector{String}}`: NTCs exporting from a given zone.

## Plotting parameters
- `colors::Dict{String,String}`: Color mapping for zones, nodes, or technologies (used in visualization).

## Extension data
- `extra::Dict{Symbol,Any}`: Input data for user-defined [`ModelComponent`](@ref)s, keyed by component label.
"""
Base.@kwdef struct Parameters
    sets::Sets = Sets()

    # power plant parameters
    gmax::Dict{String,Float64} = Dict{String,Float64}()
    eta::Dict{String,Float64} = Dict{String,Float64}()
    gmax_storage::Dict{String,Float64} = Dict{String,Float64}()
    storage::Dict{String,Float64} = Dict{String,Float64}()
    mc::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    avail::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    avail_planttype_nodal::Dict{Tuple{String,String},ConcreteProfile} =
        Dict{Tuple{String,String},ConcreteProfile}()
    avail_planttype_zonal::Dict{Tuple{String,String},ConcreteProfile} =
        Dict{Tuple{String,String},ConcreteProfile}()
    plant_type::Dict{String,String} = Dict{String,String}()

    # plant types
    plant_type2color::Dict{String,String} = Dict{String,String}()
    dispatchable::Vector{String} = Vector{String}()
    nondispatchable::Vector{String} = Vector{String}()
    storage_types::Vector{String} = Vector{String}()
    fuel_price::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    co2content::Dict{String,Float64} = Dict{String,Float64}()
    historical_generation::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    min_generation::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()

    # node parameters
    slack::Vector{String} = Vector{String}()
    node2zone::Dict{String,String} = Dict{String,String}()
    node_coords::Dict{String,Vector{Float64}} = Dict{String,Vector{Float64}}()

    # acline parameters
    acline_capacity::Dict{String,Float64} = Dict{String,Float64}()
    resistance::Dict{String,Float64} = Dict{String,Float64}()
    reactance::Dict{String,Float64} = Dict{String,Float64}()
    bvector::Dict{String,Float64} = Dict{String,Float64}()
    circuits::Dict{String,Int64} = Dict{String,Int64}()
    voltage::Dict{String,Float64} = Dict{String,Float64}()
    line_start::Dict{String,String} = Dict{String,String}()
    line_end::Dict{String,String} = Dict{String,String}()

    b::Dict{Tuple{String,String},Float64} = Dict{Tuple{String,String},Float64}()
    h::Dict{Tuple{String,String},Float64} = Dict{Tuple{String,String},Float64}()
    ptdf::Dict{Tuple{String,String},Float64} = Dict{Tuple{String,String},Float64}()
    cne::Vector{String} = Vector{String}()
    slack_zone::Dict{String,Vector{String}} = Dict{String,Vector{String}}()

    # dcline parameters
    dcline_capacity::Dict{String,Float64} = Dict{String,Float64}()
    dc_start::Dict{String,String} = Dict{String,String}()
    dc_end::Dict{String,String} = Dict{String,String}()

    # demand parameters
    nodal_load::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    zonal_load::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    inflow::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    fixed_exchange::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()

    # zone parameters
    ntc::Dict{Tuple{String,String},Float64} = Dict{Tuple{String,String},Float64}()

    # prosumer parameters
    prosumer_types::Vector{String} = Vector{String}()
    prs_demand::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()
    nodal_load_no_prs::Dict{String,ConcreteProfile} = Dict{String,ConcreteProfile}()

    # other mappers
    nodes_in_zone::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    plants_in_zone::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    storages_in_zone::Dict{String,Vector{String}} = Dict{String,Vector{String}}()

    plants_in_node::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    storages_in_node::Dict{String,Vector{String}} = Dict{String,Vector{String}}()

    plant2node::Dict{String,String} = Dict{String,String}()
    plant2zone::Dict{String,String} = Dict{String,String}()

    importing_ntcs::Dict{String,Vector{String}} = Dict{String,Vector{String}}()
    exporting_ntcs::Dict{String,Vector{String}} = Dict{String,Vector{String}}()

    # plotting parameters
    colors::Dict{String,String} = Dict{String,String}()

    # extension bag: input data for user-defined ModelComponents, keyed by component.
    # Custom loaders write params.extra[:my_component]; components read it in build!.
    extra::Dict{Symbol,Any} = Dict{Symbol,Any}()

end

const AffOrVar = Union{AffExpr,VariableRef}

"""
    ModelRun{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}(params::Parameters, setup::ModelSetup{MT,PS,DR}, solver; 
                             resultdir="results", scenarioname=randstring(6), overwrite=false)

Encapsulates a single simulation run of a market model, including its setup, solver, and output configuration.

# Arguments
- `params::Parameters`: Input parameters for model creation (see section 'Parameters').
- `setup::ModelSetup{MT,PS,DR}`: Struct containing the scenario description, time horizon, market type, and prosumer setup (see section [`ModelSetup`](@ref)).
- `solver`: Optimization solver used in the simulation.

# Keyword Arguments
- `resultdir::String = "results"`: Base directory where results will be stored.
- `scenarioname::String = randstring(6)`: Unique identifier for the scenario; used to create a subdirectory.
- `overwrite::Bool = false`: Whether to overwrite existing result directories.
- `verbose::Bool = false`: Whether the solver log is shown. When `false` the solver is silenced via `MOI.Silent`.

# Fields
- `params`: See above.
- `setup`: See above.
- `solver`: See above.
- `resultdir`: Base directory path for storing results.
- `scenarioname`: Name/identifier for this specific scenario run.
- `scen_dir`: Full path to the scenario-specific result directory (`joinpath(resultdir, scenarioname)`).
- `overwrite`: Whether existing directories can be overwritten.
- `verbose`: Whether solver output is shown.

# Behavior
- Automatically creates a result directory for the run.
- Throws an error if the scenario directory exists and `overwrite=false`.
"""
struct ModelRun{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    params::Parameters
    setup::ModelSetup{MT, PS, RD}
    solver::Any

    resultdir::String
    scenarioname::String
    scen_dir::String
    overwrite::Bool
    verbose::Bool

    function ModelRun(
        params::Parameters,
        setup::ModelSetup{T, S, R},
        solver;
        resultdir::String = "results",
        scenarioname::String = randstring(6),
        overwrite::Bool = false,
        verbose::Bool = false,
    ) where {T<:MarketType, S<:ProsumerSetup, R<:RedispatchSetup}
        scen_dir = joinpath(resultdir, scenarioname)
        if isdir(scen_dir) && !overwrite
            error("Directory $scen_dir already exists. Set overwrite=true to overwrite.")
        end

        mkpath(scen_dir)

        new{T, S, R}(params, setup, solver, resultdir, scenarioname, scen_dir, overwrite, verbose)
    end
end


### SubRun
const AffVarLink = Union{AffExpr,VariableRef,LinkConstraintRef}

"""
    SubRun{MT, PS, RD, MS}

Low-level container representing a single submodel (e.g. one timestep or market state).
Contains the model components, their OptiNodes, the market state, and result containers.

# Fields
- `results::Dict{Symbol,DataFrame}`: Output results from the optimization.
- `vars::Dict{Symbol,OptiNode}`: Mapping of component labels to OptiNodes (incl. `:balance`).
- `components::Vector{ModelComponent}`: Components built into this subrun, in build order.
- `modelrun::ModelRun`: Reference to the parent model run.
- `market_state::MarketState`: The current market state simulated.
- `optigraph::OptiGraph`: Graph structure linking all model modules.

Component nodes are accessible as `sr.vars[:disp]` etc.; the property shorthands
`sr.disp`, `sr.ndisp`, `sr.sto`, `sr.network`, `sr.prosumer`, `sr.balance` are kept
for convenience and dispatch into `vars`.

Created internally: the constructor creates one OptiNode per component (plus
`:balance`), calls [`build!`](@ref) on each component, links them through the generic
energy balance ([`link_balance`](@ref)), and finally calls [`collect_results!`](@ref).
"""
struct SubRun{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup, MS<:MarketState}
    results::Dict{Symbol,DataFrame}
    vars::Dict{Symbol,OptiNode}
    components::Vector{ModelComponent}

    modelrun::ModelRun{MT, PS, RD}
    market_state::MS

    optigraph::OptiGraph

    # pipeline context: data carried between stages and time splits
    # (e.g. :sto_lvl_start under CarryOverStorage)
    ctx::Dict{Symbol,Any}

    function SubRun(
        mr::ModelRun{MT, PS, RD},
        market_state::T,
        ctx::Dict{Symbol,Any} = Dict{Symbol,Any}(),
    ) where {MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup, T<:MarketState}
        comps = components(mr.setup, market_state)
        results = Dict{Symbol,DataFrame}()
        vars = Dict{Symbol,OptiNode}()

        m = OptiGraph()
        for c in comps
            lbl = label(c)
            haskey(vars, lbl) && error("Duplicate component label :$lbl. Every component needs a unique label.")
            vars[lbl] = add_module!(m, string(lbl))
        end
        vars[:balance] = add_module!(m, "balance")

        self = new{MT, PS, RD, T}(results, vars, comps, mr, market_state, m, ctx)

        for c in comps
            build!(c, self)
        end
        link_balance(self)
        for c in comps
            collect_results!(c, self)
        end

        return self
    end
end

# Property shorthands for the standard component nodes (sr.disp, sr.network, ...).
const _SUBRUN_NODE_PROPS = (:disp, :ndisp, :sto, :network, :prosumer, :balance)

function Base.getproperty(sr::SubRun, s::Symbol)
    s in _SUBRUN_NODE_PROPS && return getfield(sr, :vars)[s]
    return getfield(sr, s)
end

Base.propertynames(sr::SubRun) = (fieldnames(SubRun)..., _SUBRUN_NODE_PROPS...)

# Result tables whose named column holds a constraint reference to extract duals from
# (all other columns of every result table are value-extracted generically in
# fetch_results, including tables of user-defined components).
const results_dual_cols = Dict(
    :NodalMarketBalance => :MarketBalance,
    :NodalMarketRedispBalance => :MarketBalance,
    :ZonalMarketBalance => :MarketBalance,
)

const AffOrVarOrFloatOrInt = Union{AffExpr,VariableRef,Float64,Int}