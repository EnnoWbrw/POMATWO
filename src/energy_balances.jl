### Component wiring and the generic energy balance
#
# This file connects the ModelComponent interface (components.jl) to the concrete
# builder functions (technologies.jl, prosumer.jl) and defines the single generic
# energy-balance link constraint that replaces the former per-market-type
# `link_components` methods.

const DAor2DA = Union{DayAhead,TwoDayAhead}

"""
    components(setup::ModelSetup, ms::MarketState) -> Vector{ModelComponent}

Ordered list of components built into a `SubRun` for the given market state:
the built-in components plus any user components from `setup.components`.
The prosumer optimization stage builds only the prosumer component.
"""
function components(setup::ModelSetup, ::MarketState)
    return vcat(
        ModelComponent[
            DispatchableGen(),
            NonDispatchableGen(),
            StorageComp(),
            NetworkComp(),
            ProsumerComp(),
        ],
        setup.components,
    )
end

components(setup::ModelSetup, ::ProsumerOptimizationState) = ModelComponent[ProsumerComp()]

### build! adapters — delegate to the existing builder functions

build!(::DispatchableGen, sr::SubRun) = add_disp_generators(sr)
build!(::NonDispatchableGen, sr::SubRun) = add_ndisp_generators(sr)
build!(::StorageComp, sr::SubRun) = add_storage(sr)
build!(::NetworkComp, sr::SubRun) = add_network(sr)
build!(::ProsumerComp, sr::SubRun) = add_prosumer(sr)

### Region sets and load per balance scope

regions(::NodalScope, params::Parameters) = params.sets.N
regions(::ZonalScope, params::Parameters) = params.sets.Z

balance_load(::NodalScope, params::Parameters, n, t) = params.nodal_load[n][t]
function balance_load(::ZonalScope, params::Parameters, z, t)
    return sum(
        params.nodal_load[n][t] for
        n in params.nodes_in_zone[z] if haskey(params.nodal_load, n);
        init = 0.0,
    )
end

### injection methods for the built-in components
#
# Sign convention: positive = supply at the region. Member lists per region are
# cached on the component instance (one instance per SubRun) so the set algebra
# runs once per region instead of once per (region, t).

# helper: sum container entries [i, t] over ids; nothing when ids is empty
function _sum_at(container, ids, t)
    isempty(ids) && return nothing
    ex = AffExpr()
    for i in ids
        add_to_expression!(ex, container[i, t])
    end
    return ex
end

_members(::NodalScope, params) = params.plants_in_node
_members(::ZonalScope, params) = params.plants_in_zone
_sto_members(::NodalScope, params) = params.storages_in_node
_sto_members(::ZonalScope, params) = params.storages_in_zone

# Dispatchable generation: GEN (day-ahead / basecase), GEN_REDISP (redispatch)
function injection(
    c::DispatchableGen, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DAor2DA}
    params = sr.modelrun.params
    ids = get!(() -> intersect(params.sets.DISP, _members(scope, params)[r]), c.members, r)
    return _sum_at(sr.vars[:disp][:GEN], ids, t)
end

function injection(
    c::DispatchableGen, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:Redispatch}
    params = sr.modelrun.params
    ids = get!(() -> intersect(params.sets.DISP, _members(scope, params)[r]), c.members, r)
    return _sum_at(sr.vars[:disp][:GEN_REDISP], ids, t)
end

# Non-dispatchable generation: FEEDIN / FEEDIN_REDISP.
# In redispatch with active prosumers, prosumer plants leave the NDISP set
# (their behaviour is fixed via the prosumer component instead).
function injection(
    c::NonDispatchableGen, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DAor2DA}
    params = sr.modelrun.params
    ids = get!(() -> intersect(params.sets.NDISP, _members(scope, params)[r]), c.members, r)
    return _sum_at(sr.vars[:ndisp][:FEEDIN], ids, t)
end

function injection(
    c::NonDispatchableGen, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:Redispatch}
    params = sr.modelrun.params
    has_prs = !(sr.modelrun.setup.ProsumerSetup isa NoProsumer)
    ids = get!(c.members, r) do
        ndisp = has_prs ? setdiff(params.sets.NDISP, params.sets.PRS) : params.sets.NDISP
        intersect(ndisp, _members(scope, params)[r])
    end
    return _sum_at(sr.vars[:ndisp][:FEEDIN_REDISP], ids, t)
end

# Storage: GEN - CHARGE / GEN_REDISP - CHARGE_REDISP
function _sto_injection(c::StorageComp, sr::SubRun, scope::BalanceScope, r, t, genkey, chargekey)
    params = sr.modelrun.params
    ids = get!(() -> _sto_members(scope, params)[r], c.members, r)
    isempty(ids) && return nothing
    GEN = sr.vars[:sto][genkey]
    CHARGE = sr.vars[:sto][chargekey]
    ex = AffExpr()
    for s in ids
        add_to_expression!(ex, GEN[s, t])
        add_to_expression!(ex, -1.0, CHARGE[s, t])
    end
    return ex
end

function injection(
    c::StorageComp, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DAor2DA}
    return _sto_injection(c, sr, scope, r, t, :GEN, :CHARGE)
end

function injection(
    c::StorageComp, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:Redispatch}
    return _sto_injection(c, sr, scope, r, t, :GEN_REDISP, :CHARGE_REDISP)
end

# Network: EXCHANGE at zonal scope, NETINPUT at nodal scope. These are different
# formulations (zonal exchange vs. DC load flow), not aggregations of each other.
injection(::NetworkComp, sr::SubRun, ::ZonalScope, z, t) = sr.vars[:network][:EXCHANGE][z, t]
injection(::NetworkComp, sr::SubRun, ::NodalScope, n, t) = sr.vars[:network][:NETINPUT][n, t]

# Prosumer: in the day-ahead/basecase stages prosumer demand enters the balance as
# negative injection (demand); in redispatch the fixed prosumer net input (from the
# prosumer optimization stage) enters as injection. Without prosumers: nothing.
function injection(
    c::ProsumerComp, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerOptimization,RD<:RedispatchSetup,MS<:DAor2DA}
    params = sr.modelrun.params
    ids = get!(() -> intersect(params.sets.PRS, _members(scope, params)[r]), c.members, r)
    isempty(ids) && return nothing
    return AffExpr(-sum(params.prs_demand[prs][t] for prs in ids))
end

function injection(
    c::ProsumerComp, sr::SubRun{MT,PS,RD,MS}, scope::BalanceScope, r, t,
) where {MT<:MarketType,PS<:ProsumerOptimization,RD<:RedispatchSetup,MS<:Redispatch}
    params = sr.modelrun.params
    ids = get!(() -> intersect(params.sets.PRS, _members(scope, params)[r]), c.members, r)
    return _sum_at(sr.vars[:prosumer][:PRS_NETINPUT], ids, t)
end

### Generic energy balance

"""
    link_balance(sr::SubRun)

Create the energy-balance link constraint for the subrun: for every region of the
[`balance_scope`](@ref) and every timestep, the sum of all component
[`injection`](@ref)s plus curtailment/lost-load slacks must equal the load.

The constraint is registered on the optigraph as `ZonalMarketBalance` (zonal scope)
or `NodalMarketBalance` (nodal scope) — these names are relied on for dual/price
extraction (`get_balance`). Results are stored under `:ZonalMarketBalance`,
`:NodalMarketBalance`, or `:NodalMarketRedispBalance` (redispatch stages).
"""
function link_balance(sr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:MarketState}
    params = sr.modelrun.params
    scope = balance_scope(sr.modelrun.setup.MarketType, sr.market_state)
    R = regions(scope, params)
    T = sr.market_state.Time
    m = sr.optigraph
    balance = sr.vars[:balance]

    infeas_cost = 9000

    @variable(balance, 0 <= CU[R, T])
    @variable(balance, 0 <= LL[R, T])
    @objective(balance, Min, infeas_cost * sum(CU[r, t] + LL[r, t] for r in R, t in T))

    function lhs(r, t)
        ex = AffExpr()
        for c in sr.components
            inj = injection(c, sr, scope, r, t)
            inj === nothing || add_to_expression!(ex, inj)
        end
        return ex
    end

    if scope isa ZonalScope
        @linkconstraint(
            m,
            ZonalMarketBalance[r = R, t = T],
            lhs(r, t) - CU[r, t] == balance_load(scope, params, r, t) - LL[r, t]
        )
        _push_balance_results!(sr, :ZonalMarketBalance, :Zone, ZonalMarketBalance, CU, LL, R, T)
    else
        @linkconstraint(
            m,
            NodalMarketBalance[r = R, t = T],
            lhs(r, t) - CU[r, t] == balance_load(scope, params, r, t) - LL[r, t]
        )
        key = MS <: Redispatch ? :NodalMarketRedispBalance : :NodalMarketBalance
        _push_balance_results!(sr, key, :Node, NodalMarketBalance, CU, LL, R, T)
    end

    return m
end

# The prosumer optimization stage has no market balance of its own.
link_balance(sr::SubRun{MT,PS,RD,MS}) where {MT<:MarketType,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:ProsumerOptimizationState} = nothing

function _push_balance_results!(sr::SubRun, key::Symbol, regioncol::Symbol, con, CU, LL, R, T)
    if !haskey(sr.results, key)
        sr.results[key] = DataFrame(;
            Time = Int[],
            regioncol => String[],
            MarketBalance = LinkConstraintRef[],
            CU = VariableRef[],
            LL = VariableRef[],
        )
    end
    for r in R, t in T
        push!(
            sr.results[key],
            (;
                Time = t,
                regioncol => r,
                MarketBalance = con[r, t],
                CU = CU[r, t],
                LL = LL[r, t],
            ),
        )
    end
end
