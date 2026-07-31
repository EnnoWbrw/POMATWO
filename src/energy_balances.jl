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

### Nodal reporting for zonal day-ahead stages
#
# A zonal day-ahead market has no nodal variables: `add_network` routes to
# `add_exchange`, so `NETINPUT`/`ACINJECTION`/`LINEFLOW`/`DCLINEFLOW` — created only in
# `add_dclf` — never exist. The nodal picture is nevertheless well defined after the
# clearing: every plant has a node, so the cleared dispatch implies a nodal net input, and
# the PTDF turns that into line flows. Those are the flows the market would cause BEFORE
# redispatch, so they are deliberately NOT capacity-limited and may exceed
# `acline_capacity`. Reported here, in the same tables every other stage writes.
#
# Caveats (see "Nodal results of a zonal day-ahead" in docs/src/power_flow_ac.md):
# - `DELTA` is 0: there are no phase angles to report.
# - Under `NTC` no DC-line flows are modelled, so DC lines are assumed idle
#   (`ACINJECTION == NETINPUT`, no `DCLINEFLOW` rows). `FlowBased` does model them and its
#   `ACINJECTION`/`DCLINEFLOW` are exact.
# - The zonal balance's `CU`/`LL` slacks are zonal, not nodal, and do not enter the nodal
#   net input; when they are active the nodal tables and the zonal clearing differ by them.

"""
    report_nodal_flows!(sr::SubRun)

Persist nodal net injections and PTDF line flows for stages that have no nodal network
formulation of their own. No-op by default — nodal markets, the `TwoDayAhead` basecase and
every redispatch stage go through [`add_dclf`](@ref), which writes these tables itself.
"""
report_nodal_flows!(::SubRun) = nothing

# DC-line flow expression container of a zonal day-ahead network node, or `nothing` when the
# formulation does not model DC lines.
_zonal_dc_flow(::SubRun, ::Type{NTC}) = nothing
function _zonal_dc_flow(sr::SubRun, ::Type{FlowBased})
    isempty(sr.modelrun.params.sets.DC) && return nothing
    return sr.vars[:network][:F]
end

function report_nodal_flows!(
    sr::SubRun{ZonalMarket{XF},PS,RD,MS},
) where {XF<:ExchangeFormulation,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DayAhead}
    params = sr.modelrun.params
    T = collect(sr.market_state.Time)
    N, L, DC = params.sets.N, params.sets.L, params.sets.DC
    @unpack acline_capacity, dcline_capacity, dc_start, dc_end, ptdf = params

    # Fresh component instances: the ones on `sr.components` have their `members` caches
    # filled with zone keys (the balance ran at ZonalScope), and node keys must not be
    # mixed into the same dict. NetworkComp is skipped — its zonal EXCHANGE is not a
    # nodal quantity.
    comps = [c for c in components(sr.modelrun.setup, sr.market_state) if !(c isa NetworkComp)]
    scope = NodalScope()

    # Import-positive, like the nodal DCLF: load + charge - gen.
    NETINPUT = Containers.DenseAxisArray(Matrix{AffExpr}(undef, length(N), length(T)), N, T)
    for n in N, t in T
        ex = AffExpr(_nodal_load_at(params, n, t))
        for c in comps
            inj = injection(c, sr, scope, n, t)
            inj === nothing || add_to_expression!(ex, -1.0, inj)
        end
        NETINPUT[n, t] = ex
    end

    # ACINJECTION is the AC part of the net input: what the PTDF acts on.
    F = _zonal_dc_flow(sr, XF)
    ACINJECTION = NETINPUT
    if !isnothing(F)
        dcincidence = Containers.DenseAxisArray(zeros(Int, length(DC), length(N)), DC, N)
        for dc in DC
            dcincidence[dc, dc_start[dc]] = -1
            dcincidence[dc, dc_end[dc]] = 1
        end
        ACINJECTION =
            Containers.DenseAxisArray(Matrix{AffExpr}(undef, length(N), length(T)), N, T)
        for n in N, t in T
            ex = AffExpr()
            add_to_expression!(ex, NETINPUT[n, t])
            for dc in DC
                iszero(dcincidence[dc, n]) && continue
                add_to_expression!(ex, -dcincidence[dc, n], F[t, dc])
            end
            ACINJECTION[n, t] = ex
        end
    end

    ### to dataframe
    df_netinput(sr.results)
    df_lineflow(sr.results)

    append_results!(sr.results, :NETINPUT, DataFrame(
        index = repeat(N, inner = length(T)),
        Time = repeat(T, outer = length(N)),
        NETINPUT = [NETINPUT[n, t] for n in N for t in T],
        ACINJECTION = [ACINJECTION[n, t] for n in N for t in T],
        DELTA = zeros(length(N) * length(T)),
    ))

    # `params.ptdf` is import-positive: it maps NETINPUT to LINEFLOW without a sign flip
    # (see the sign-convention section of CLAUDE.md). Read from the dict directly — the
    # axes of `dict_to_matrix` are lexicographically sorted, not in `sets.L`/`sets.N` order.
    # No line-limit constraint: the point of these flows is that they can be overloaded.
    if !isempty(L) && !isempty(ptdf)
        LINEFLOW = Containers.DenseAxisArray(Matrix{AffExpr}(undef, length(L), length(T)), L, T)
        for l in L, t in T
            ex = AffExpr()
            for n in N
                coef = get(ptdf, (l, n), 0.0)
                iszero(coef) && continue
                add_to_expression!(ex, coef, ACINJECTION[n, t])
            end
            LINEFLOW[l, t] = ex
        end

        append_results!(sr.results, :LINEFLOW, DataFrame(
            index = repeat(L, inner = length(T)),
            Time = repeat(T, outer = length(L)),
            LINEFLOW = [LINEFLOW[l, t] for l in L for t in T],
            line_capacity = [acline_capacity[l] for l in L for t in T],
        ))
    end

    if !isnothing(F)
        append_results!(sr.results, :DCLINEFLOW, DataFrame(
            index = repeat(DC, inner = length(T)),
            Time = repeat(T, outer = length(DC)),
            DCLINEFLOW = [F[t, dc] for dc in DC for t in T],
            line_capacity = [dcline_capacity[dc] for dc in DC for t in T],
        ))
    end

    return sr.results
end

function _push_balance_results!(sr::SubRun, key::Symbol, regioncol::Symbol, con, CU, LL, R, T)
    sr.results[key] = DataFrame(
        :Time => repeat(collect(T), outer = length(R)),
        regioncol => repeat(collect(R), inner = length(T)),
        :MarketBalance => [con[r, t] for r in R for t in T],
        :CU => [CU[r, t] for r in R for t in T],
        :LL => [LL[r, t] for r in R for t in T],
    )
    return sr.results[key]
end
