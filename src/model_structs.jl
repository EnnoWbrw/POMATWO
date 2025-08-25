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
    ModelSetup{T<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}

A container struct that holds the basic configuration for the market simulation model.

# Fields
- `Scenario::String`: A descriptive name or identifier for the model scenario.
- `TimeHorizon::TimeHorizon`: Time settings for the simulation (see section on 'TimeHorizon').
- `MarketType::T`: Type of market structure to simulate (see section 'MarketType'). Defaults to `ZonalMarket()`.
- `ProsumerSetup::ProsumerSetup`: Configuration of prosumer behavior in the model (see section 'ProsumerSetup'). Defaults to `NoProsumer()`.
- `RedispatchSetup::RedispatchSetup`: Configuration of redispatch modeling in the simulation (see section 'RedispatchSetup'). Defaults to `NoRedispatch()`.

This struct supports keyword-based construction using default values where provided.

# Example
```julia
ModelSetup(
    ;Scenario = "TestSetup",
    TimeHorizon = TimeHorizon(; offset = 0, split = 24, stop = 48),
    MarketType = NodalMarketWithRedispatch(target_zone = "DE"),
    ProsumerSetup = NoProsumer(),
    RedispatchSetup = DCLF(PhaseAngle),
    
)
```
"""
Base.@kwdef struct ModelSetup{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    Scenario::String
    TimeHorizon::TimeHorizon
    MarketType::MT = ZonalMarket()
    ProsumerSetup::PS = NoProsumer()
    RedispatchSetup::RD = NoRedispatch()
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
struct ModelRun{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup}
    params::Parameters
    setup::ModelSetup{MT, PS, RD}
    solver::Any

    resultdir::String
    scenarioname::String
    scen_dir::String
    overwrite::Bool

    function ModelRun(
        params::Parameters,
        setup::ModelSetup{T, S, R},
        solver;
        resultdir::String = "results",
        scenarioname::String = randstring(6),
        overwrite::Bool = false,
    ) where {T<:MarketType, S<:ProsumerSetup, R<:RedispatchSetup}
        scen_dir = joinpath(resultdir, scenarioname)
        if isdir(scen_dir) && !overwrite
            error("Directory $scen_dir already exists. Set overwrite=true to overwrite.")
        end

        mkpath(scen_dir)

        new{T, S, R}(params, setup, solver, resultdir, scenarioname, scen_dir, overwrite)
    end
end


### SubRun
const AffVarLink = Union{AffExpr,VariableRef,LinkConstraintRef}

"""
    SubRun{MT, PS, RD, MS}

Low-level container representing a single submodel (e.g. one timestep or market state).
Contains the JuMP submodules, market state, and associated variable containers.

# Fields
- `results::Dict{Symbol,DataFrame}`: Output results from the optimization.
- `vars::Dict{Symbol,OptiNode}`: Mapping of module names to OptiNodes.
- `modelrun::ModelRun`: Reference to the parent model run.
- `market_state::MarketState`: The current market state simulated.
- `optigraph::OptiGraph`: Graph structure linking all model modules.
- `disp`, `ndisp`, `sto`, `network`, `prosumer`, `balance`: JuMP modules.

Created internally and passed to module-building functions.
"""
struct SubRun{MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup, MS<:MarketState}
    results::Dict{Symbol,DataFrame}
    vars::Dict{Symbol,OptiNode}

    modelrun::ModelRun{MT, PS, RD}
    market_state::MS

    optigraph::OptiGraph
    disp::OptiNode
    ndisp::OptiNode
    sto::OptiNode
    network::OptiNode
    prosumer::OptiNode
    balance::OptiNode

    function SubRun(mr::ModelRun{MT, PS, RD}, market_state::T) where {MT<:MarketType, PS<:ProsumerSetup, RD<:RedispatchSetup, T<:MarketState}
        results = Dict{Symbol,DataFrame}()
        vars = Dict{Symbol,OptiNode}()

        m = OptiGraph()
        vars[:disp] = disp = add_module!(m, "disp")
        vars[:ndisp] = ndisp = add_module!(m, "ndisp")
        vars[:sto] = sto = add_module!(m, "sto")
        vars[:network] = network = add_module!(m, "network")
        vars[:prosumer] = prosumer = add_module!(m, "prosumer")
        vars[:balance] = balance = add_module!(m, "balance")

        self = new{MT, PS, RD, T}(
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