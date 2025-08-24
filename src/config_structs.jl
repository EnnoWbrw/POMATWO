### MarketTypes
"""
    MarketType

Abstract supertype for market setup descriptors. Subtypes specify the market structure (zonal or nodal) and whether redispatch is considered.

# Subtypes
- [`ZonalMarket`](@ref): Simple zonal market without redispatch.
- [`ZonalMarketWithRedispatch`](@ref): Zonal market including redispatch actions.
- [`NodalMarket`](@ref): Nodal market without redispatch.
- [`NodalMarketWithRedispatch`](@ref): Nodal market including redispatch actions.

These types are used to parameterize simulations or models, allowing code to dispatch on market design and redispatch handling.
"""
abstract type MarketType end

"""
    ZonalMarketWithRedispatch(; target_zone = nothing)

Represents a zonal market model with redispatch enabled. This market type is defined by a clearing of zonal markets, followed by a calculation of resulting network flows and redispatch.
Optionally, a specific target zone or set of zones can be specified, altough this currently has no effect on model creation.
"""
Base.@kwdef struct ZonalMarketWithRedispatch <: MarketType
    target_zone::Union{String,Vector{String},Nothing} = nothing
end

"""
    ZonalMarket(; target_zone=nothing)

Represents a standard zonal market model without redispatch. In zonal market models the energy balance is defined at zonal level. 
Optionally, a specific target zone or set of zones can be specified, altough this currently has no effect on model creation.
"""
Base.@kwdef struct ZonalMarket <: MarketType
    target_zone::Union{String,Vector{String},Nothing} = nothing
end

const ZonalMarketType = Union{ZonalMarket,ZonalMarketWithRedispatch}

"""
    NodalMarket

Represents a nodal market model without redispatch. In nodal markets the energy balance is created at nodal level and markets are cleared subject to network constraints.
"""
struct NodalMarket <: MarketType end

"""
    NodalMarketWithRedispatch(; target_zone=nothing)

Represents a nodal market model with redispatch enabled. This market type is defined by a clearing of nodal markets, followed by a calculation of resulting network flows and redispatch.
Optionally, a specific target zone or set of zones can be specified, altough this currently has no effect on model creation.
"""
Base.@kwdef struct NodalMarketWithRedispatch <: MarketType
    target_zone::Union{String,Vector{String},Nothing} = nothing
end

const NodalMarketType = Union{NodalMarket,NodalMarketWithRedispatch}

"""
    ProsumerSetup

Abstract supertype for prosumer market participation models.
Subtypes specify whether and how prosumers are represented in the simulation.

# Subtypes
- [`NoProsumer`](@ref): No prosumers are modeled.
- [`ProsumerOptimization`](@ref): Prosumers are modeled with explicit optimization (variable sell/buy prices and retail tariff types).
"""
abstract type ProsumerSetup end

"""
    NoProsumer

Represents a market setup with no prosumer participation.
"""
struct NoProsumer <: ProsumerSetup end

"""
    ProsumerOptimization(; sell_price, buy_price=0, retail_type=:buy_price)

Represents a prosumer setup where prosumer actions are explicitly optimized with respect to market conditions.

# Keyword Arguments
- `sell_price::Float64`: Price at which the prosumer can sell electricity to the market or grid.
- `buy_price::Float64`: Price at which the prosumer buys electricity from the market/grid. Defaults to `0`.
- `retail_type::Symbol`: Retail tariff structure. Must be one of `:buy_price`, `:flat`, or `:realtime`. Default is `:buy_price`.

An error is thrown if `retail_type` is not valid.

# Example
```julia
ProsumerOptimization(sell_price=0.12, buy_price=0.22)
```
"""
struct ProsumerOptimization <: ProsumerSetup
    sell_price::Float64
    buy_price::Float64
    retail_type::Symbol

    function ProsumerOptimization(;
        sell_price,
        buy_price = 0,
        retail_type::Symbol = :buy_price,
    )

        if !(retail_type in [:buy_price, :flat, :realtime])
            error("retail_type must be one of [:buy_price, :flat, :realtime]")
        end

        return new(sell_price, buy_price, retail_type)
    end
end

### MarketStates
abstract type MarketState end
struct DayAhead <: MarketState
    Time::UnitRange{Int}
end

struct ProsumerOptimizationState <: MarketState
    Time::UnitRange{Int}
    price::Any
end
struct Redispatch <: MarketState
    Time::UnitRange{Int}
    da_market_result::Dict
end

### TimeHorizon
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
setup = ModelSetup(
    "TestSetup",
    TimeHorizon(start = 1, stop = 8760, split = 24, offset = 12),
    ZonalMarketWithRedispatch(target_zone = "DE"),
    NoProsumer(),
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
    ModelSetup{T<:MarketType}

A container struct that holds the basic configuration for the market simulation model.

# Fields
- `Scenario::String`: A descriptive name or identifier for the model scenario.
- `TimeHorizon::TimeHorizon`: Time settings for the simulation (see section on 'TimeHorizon').
- `MarketType::T`: Type of market structure to simulate (see section 'MarketType'). Defaults to `ZonalMarket()`.
- `ProsumerSetup::ProsumerSetup`: Configuration of prosumer behavior in the model (see section 'ProsumerSetup'). Defaults to `NoProsumer()`.

This struct supports keyword-based construction using default values where provided.

# Example
```julia
ModelSetup(
    "TestSetup",
    TimeHorizon(; offset = 0, split = 24, stop = 48),
    NodalMarketWithRedispatch(target_zone = "DE"),
    NoProsumer(),
)
```
"""
Base.@kwdef struct ModelSetup{MT<:MarketType, PS<:ProsumerSetup}
    Scenario::String
    TimeHorizon::TimeHorizon
    MarketType::MT = ZonalMarket()
    ProsumerSetup::PS = NoProsumer()
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

Base.@kwdef struct Sets
    P::Vector{String} = Vector{String}()
    S::Vector{String} = Vector{String}()
    DISP::Vector{String} = Vector{String}()
    NDISP::Vector{String} = Vector{String}()
    Z::Vector{String} = Vector{String}()
    N::Vector{String} = Vector{String}()
    L::Vector{String} = Vector{String}()
    DC::Vector{String} = Vector{String}()
    NTC::Vector{Tuple{String,String}} = Vector{Tuple{String,String}}()
    PRS::Vector{String} = Vector{String}()
    PRS_STO::Vector{String} = Vector{String}()
end

"""
    Parameters

A central container that holds all data required for running the POMATWO electricity market model.  
This struct is typically created by the [`load_data`](@ref) function and passed into the simulation via [`ModelRun`](@ref).

It includes detailed parameter mappings for power plants, grid infrastructure, demand, prosumers, and internal mappings used for optimization and visualization.

# Overview of Field Groups

- **Sets**:
  - `sets::Sets`: Holds index sets for nodes, plants, time steps, etc.

- **Power Plant Parameters**:
  - Maximum capacities (`gmax`, `gmax_storage`), efficiencies (`eta`), marginal costs (`mc`), availabilities (`avail`, `avail_planttype_nodal`, ...), and plant-to-type mappings.

- **Plant Type Metadata**:
  - Vectors of plant types (e.g., `dispatchable`, `storage_types`) and color mappings (`plant_type2color`).

- **Node and Grid Parameters**:
  - Node-to-zone mappings, node coordinates, AC/DC line parameters (`reactance`, `acline_capacity`, etc.).

- **Demand and Exchange**:
  - Nodal/zonal load (`nodal_load`, `zonal_load`), inflow data, fixed exchanges, and optional prosumer-modified demand.

- **Zonal Parameters**:
  - Net Transfer Capacities (`ntc`) and import/export mappings.

- **Prosumer and Storage Data**:
  - Storage state, inflows, and derived demand profiles.

- **Internal Mappers**:
  - Mappings like `plants_in_zone`, `plant2node`, `nodes_in_zone` to simplify model formulation.

- **Plotting**:
  - Color assignments used for plotting technologies or regions (`colors`).

# Notes

This struct is designed to support keyword-based construction, but in practice it is **rarely created manually**. Use [`load_data`](@ref) to construct a complete and consistent `Parameters` instance from input files.

"""
Base.@kwdef struct Parameters
    sets::Sets = Sets()

    # power plant parameters
    gmax::Dict{String,Float64} = Dict{String,Float64}()
    eta::Dict{String,Float64} = Dict{String,Float64}()
    gmax_storage::Dict{String,Float64} = Dict{String,Float64}()
    storage::Dict{String,Float64} = Dict{String,Float64}()
    mc::Dict{String,Profile} = Dict{String,Profile}()
    avail::Dict{String,Profile} = Dict{String,Profile}()
    avail_planttype_nodal::Dict{Tuple{String,String},Profile} =
        Dict{Tuple{String,String},Profile}()
    avail_planttype_zonal::Dict{Tuple{String,String},Profile} =
        Dict{Tuple{String,String},Profile}()
    plant_type::Dict{String,String} = Dict{String,String}()

    # plant types
    plant_type2color::Dict{String,String} = Dict{String,String}()
    dispatchable::Vector{String} = Vector{String}()
    nondispatchable::Vector{String} = Vector{String}()
    storage_types::Vector{String} = Vector{String}()
    fuel_price::Dict{String,Profile} = Dict{String,Profile}()
    co2content::Dict{String,Float64} = Dict{String,Float64}()
    historical_generation::Dict{String,Profile} = Dict{String,Profile}()
    min_generation::Dict{String,Profile} = Dict{String,Profile}()

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

    # dcline parameters
    dcline_capacity::Dict{String,Float64} = Dict{String,Float64}()
    dc_start::Dict{String,String} = Dict{String,String}()
    dc_end::Dict{String,String} = Dict{String,String}()

    # demand parameters
    nodal_load::Dict{String,Profile} = Dict{String,Profile}()
    zonal_load::Dict{String,Profile} = Dict{String,Profile}()
    inflow::Dict{String,Profile} = Dict{String,Profile}()
    fixed_exchange::Dict{String,Profile} = Dict{String,Profile}()

    # zone parameters
    ntc::Dict{Tuple{String,String},Float64} = Dict{Tuple{String,String},Float64}()

    # prosumer parameters
    prosumer_types::Vector{String} = Vector{String}()
    prs_demand::Dict{String,Profile} = Dict{String,Profile}()
    nodal_load_no_prs::Dict{String,Profile} = Dict{String,Profile}()

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

end

const AffOrVar = Union{AffExpr,VariableRef}

"""
    ModelRun{MT<:MarketType}(params::Parameters, setup::ModelSetup{MT}, solver; 
                             resultdir="results", scenarioname=randstring(6), overwrite=false)

Encapsulates a single simulation run of a market model, including its setup, solver, and output configuration.

# Arguments
- `params::Parameters`: Input parameters for model creation (see section 'Parameters').
- `setup::ModelSetup{MT}`: Struct containing the scenario description, time horizon, market type, and prosumer setup (see section [`ModelSetup`](@ref)).
- `solver`: Optimization solver used in the simulation.

# Keyword Arguments
- `resultdir::String = "results"`: Base directory where results will be stored.
- `scenarioname::String = randstring(6)`: Unique identifier for the scenario; used to create a subdirectory.
- `overwrite::Bool = false`: Whether to overwrite existing result directories.

# Fields
- `params`: See above.
- `setup`: See above.
- `solver`: See above.
- `resultdir`: Base directory path for storing results.
- `scenarioname`: Name/identifier for this specific scenario run.
- `scen_dir`: Full path to the scenario-specific result directory (`joinpath(resultdir, scenarioname)`).
- `overwrite`: Whether existing directories can be overwritten.

# Behavior
- Automatically creates a result directory for the run.
- Throws an error if the scenario directory exists and `overwrite=false`.
"""
struct ModelRun{MT<:MarketType, PS<:ProsumerSetup}
    params::Parameters
    setup::ModelSetup{MT, PS}
    solver::Any

    resultdir::String
    scenarioname::String
    scen_dir::String
    overwrite::Bool

    function ModelRun(
        params::Parameters,
        setup::ModelSetup{T, S},
        solver;
        resultdir::String = "results",
        scenarioname::String = randstring(6),
        overwrite::Bool = false,
    ) where {T<:MarketType, S<:ProsumerSetup}
        scen_dir = joinpath(resultdir, scenarioname)
        if isdir(scen_dir) && !overwrite
            error("Directory $scen_dir already exists. Set overwrite=true to overwrite.")
        end

        mkpath(scen_dir)

        new{T, S}(params, setup, solver, resultdir, scenarioname, scen_dir, overwrite)
    end
end


### SubRun
const AffVarLink = Union{AffExpr,VariableRef,LinkConstraintRef}

struct SubRun{MT<:MarketType,T<:MarketState}

    results::Dict{Symbol,DataFrame}
    vars::Dict{Symbol,OptiNode}

    modelrun::ModelRun{MT}
    market_state::T

    optigraph::OptiGraph
    disp::OptiNode
    ndisp::OptiNode
    sto::OptiNode
    network::OptiNode
    prosumer::OptiNode
    balance::OptiNode

    function SubRun(mr::ModelRun{MT}, market_state::T) where {MT<:MarketType,T<:MarketState}

        results = Dict{Symbol,DataFrame}()
        vars = Dict{Symbol,OptiNode}()

        m = OptiGraph()
        vars[:disp] = disp = add_module!(m, "disp")
        vars[:ndisp] = ndisp = add_module!(m, "ndisp")
        vars[:sto] = sto = add_module!(m, "sto")
        vars[:network] = network = add_module!(m, "network")
        vars[:prosumer] = prosumer = add_module!(m, "prosumer")
        vars[:balance] = balance = add_module!(m, "balance")

        self = new{MT,T}(
            results,
            vars,
            mr,
            market_state,
            m,
            disp,
            ndisp,
            sto,
            network,
            prosumer,
            balance,
        )

        create_energybalance(self)

        return self
    end
end

const results_value_cols = Dict(
    :GEN => [:GEN, :CU],
    :CHARGE => :CHARGE,
    :STO_LVL => :STO_LVL,
    :NETINPUT => [:NETINPUT, :DELTA],
    :LINEFLOW => [:LINEFLOW, :LINEINF],
    :DCLINEFLOW => [:DCLINEFLOW, :LINEINF],
    :EXCHANGE => :EXCHANGE,
    :NTC => :NTC,
    :REDISP => [
        :GEN_REDISP,
        :GEN_UP,
        :GEN_DOWN,
        :CU_REDISP,
        :CHARGE_REDISP,
        :CHARGE_UP,
        :CHARGE_DOWN,
    ],
    :CHARGE_REDISP => [:CHARGE_REDISP, :CHARGE_UP, :CHARGE_DOWN, :CU_REDISP],
    :STO_LVL_REDISP => :STO_LVL_REDISP,
    :NodalMarketBalance => [:CU, :LL],
    :NodalMarketRedispBalance => [:CU, :LL],
    :ZonalMarketBalance => [:CU, :LL],
    :PRS =>
        [:PRS_TOTAL_GEN, :PRS_NETINPUT, :PRS_SELF, :PRS_CU, :PRS_BUY, :PRS_SELL, :INF],
)

const results_dual_cols = Dict(
    :NodalMarketBalance => :MarketBalance,
    :NodalMarketRedispBalance => :MarketBalance,
    :ZonalMarketBalance => :MarketBalance,
)

const AffOrVarOrFloatOrInt = Union{AffExpr,VariableRef,Float64,Int}