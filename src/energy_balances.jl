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

"""
    derive_results!(sr::SubRun)

Fill in result tables that are cheaper computed from solved values than carried as JuMP
expressions. Called once per stage from `_run_states`, after [`fetch_results`](@ref) has
resolved every expression already in `sr.results`, and before the tables are written.
No-op by default.
"""
derive_results!(::SubRun) = nothing

# PTDF line flows of a zonal day-ahead, the counterpart to `report_nodal_flows!`.
#
# `params.ptdf` is import-positive: it maps NETINPUT to LINEFLOW without a sign flip (see
# the sign-convention section of CLAUDE.md). Read from the dict directly — the axes of
# `dict_to_matrix` are lexicographically sorted, not in `sets.L`/`sets.N` order.
function derive_results!(
    sr::SubRun{ZonalMarket{XF},PS,RD,MS},
) where {XF<:ExchangeFormulation,PS<:ProsumerSetup,RD<:RedispatchSetup,MS<:DayAhead}
    params = sr.modelrun.params
    N, L = params.sets.N, params.sets.L
    @unpack acline_capacity, ptdf = params
    (isempty(L) || isempty(ptdf) || !haskey(sr.results, :NETINPUT)) && return nothing
    T = collect(sr.market_state.Time)

    # Keyed rather than positional: the nodal table's row order is this stage's own
    # (`report_nodal_flows!`), but a keyed lookup cannot silently transpose if that
    # changes or another writer appends to :NETINPUT first.
    acinj = Dict{Tuple{String,Int},Float64}(
        (String(r.index), Int(r.Time)) => Float64(r.ACINJECTION)
        for r in eachrow(sr.results[:NETINPUT])
    )

    P = [get(ptdf, (l, n), 0.0) for l in L, n in N]        # lines x nodes
    A = [acinj[(n, t)] for n in N, t in T]                 # nodes x hours
    flows = P * A                                          # lines x hours, one BLAS call

    # Replaces the empty frame `df_lineflow` initialised during the build: these values are
    # already floats and must not be run through `fetch_results` again.
    sr.results[:LINEFLOW] = DataFrame(
        index = repeat(L, inner = length(T)),
        Time = repeat(T, outer = length(L)),
        LINEFLOW = vec(permutedims(flows)),                # row-major: t fastest, then l
        line_capacity = [acline_capacity[l] for l in L for t in T],
    )
    return nothing
end

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

    # The PTDF line flows are NOT built here. They enter no constraint — the point of
    # these flows is that they can be overloaded — so they are pure reporting, and as
    # JuMP expressions they are ruinous: `add_to_expression!` flattens, so every `LINEFLOW[l,t]`
    # would hold one term per plant (the PTDF row is dense over the nodes, and each
    # `ACINJECTION[n,t]` is itself a sum over that node's plants). That is lines x hours x
    # plants terms to build and, later, to resolve. `derive_results!` computes the same
    # numbers after the solve as one PTDF matrix product over the solved ACINJECTION.

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

### Opt-in: pin zonal net positions during redispatch to their day-ahead values
#
# Redispatch (`add_network` for `MS<:Redispatch`, technologies.jl) always dispatches to
# `add_dclf` regardless of `MarketType` — there is no `:EXCHANGE` variable/expression on
# the redispatch `:network` node, zonal or nodal. So "the zonal net position in redispatch"
# is not a variable to constrain directly; it has to be rebuilt as the sum of nodal
# `NETINPUT` over each zone's nodes. Both `NETINPUT` (here) and the day-ahead `EXCHANGE`
# it is pinned against (`zonal_net_position` in df_utils.jl) are import-positive under the
# same convention (see the sign-convention section of CLAUDE.md), so no sign flip is
# needed to compare them.

"""
    fix_net_positions!(sr::SubRun)

No-op for every stage except an opted-in redispatch (`DCLF.fix_net_positions == true`),
where it constrains each zone's net position to exactly equal its day-ahead cleared value.
"""
fix_net_positions!(::SubRun) = nothing

function fix_net_positions!(
    sr::SubRun{MT,PS,DCLF{LF},MS},
) where {MT<:MarketType,PS<:ProsumerSetup,LF<:DCLFFormulation,MS<:Redispatch}
    sr.modelrun.setup.RedispatchSetup.fix_net_positions || return nothing

    params = sr.modelrun.params
    @unpack nodes_in_zone = params
    Z = params.sets.Z
    T = sr.market_state.Time
    m = sr.network
    NETINPUT = sr.vars[:network][:NETINPUT]

    haskey(sr.market_state.da_market_result, :zonal_net_position) || error(
        "fix_net_positions = true but the day-ahead result has no :zonal_net_position " *
        "entry. This requires the day-ahead SubRun to have populated it (see " *
        "`prev_results_for_redispatch` in df_utils.jl).",
    )
    np_da = sr.market_state.da_market_result[:zonal_net_position]

    # Skip zones with no nodes rather than emitting a trivially-infeasible `0 == np_da` row.
    zones = [z for z in Z if !isempty(get(nodes_in_zone, z, String[]))]

    @constraint(
        m,
        FixNetPosition[z = zones, t = T],
        sum(NETINPUT[n, t] for n in nodes_in_zone[z]) == np_da[z, t]
    )

    return nothing
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
