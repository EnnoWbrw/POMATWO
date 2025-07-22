
read_csv(file) = CSV.read(file, DataFrame, stringtype = String)

function getts(avail, plant, t)
    if plant in keys(avail)
        return avail[plant][t]
    else
        return 1
    end
end

zbase(voltage::Number) = (voltage * 1E3)^2 / (500 * 1E6)


function value_or_number(x::T) where {T<:Union{GenericVariableRef,AffExpr}}
    return value(x)
end

function value_or_number(x)
    return x
end

function dual_or_number(x::T) where {T<:Union{ConstraintRef,AffExpr,Plasmo.LinkConstraintRef}}
    return dual(x)
end

function dual_or_number(x)
    return x
end

function fetch_results(sr::SubRun)
    for k in keys(sr.results)

        if haskey(results_value_cols, k)
            col = results_value_cols[k]
            getvalue(sr.results[k], propertynames(sr.results[k]), value_or_number)
        end

        if haskey(results_dual_cols, k)
            col = results_dual_cols[k]
            getvalue(sr.results[k], col, dual_or_number)
        end
    end
end

function write_results(sr::SubRun; format = "arrow")
    scen_dir = sr.modelrun.scen_dir
    t1, tend = sr.market_state.Time[[1, end]]
    sr_dir = mkpath(joinpath(scen_dir, "subrun_t$(t1)-t$(tend)"))

    for (varname, df) in sr.results

        filename = joinpath(sr_dir, string(varname) * "." * format)
        println(filename)

        if format == "arrow"
            try
                Arrow.write(filename, df)
            catch e
                @error "Could not write Arrow file" first(df, 25)
            end
        elseif format == "csv"
            CSV.write(filename, df)
        end
    end
end


function add_module!(m::OptiGraph, label::String)
    n = OptiNode()
    Plasmo.set_label(n, label)
    add_node!(m, n)
    return n
end

function JuMP.optimize!(sr::SubRun)
    set_optimizer(sr.optigraph, sr.modelrun.solver)
    optimize!(sr.optigraph)
end


function getvalue(df::DataFrame, col::Symbol, f::Function)
    transform!(df, col => ByRow(f) => col)
end

function getvalue(df::DataFrame, cols::Vector{Symbol}, f::Function)
    for col in cols
        getvalue(df, col, f)
    end
end


# getindex function for FixedProfile
function Base.getindex(p::FixedProfile, i)
    return p.val
end

# getindex function for HourlyProfile
function Base.getindex(p::HourlyProfile, i)
    return p.val[i]
end

# length function for FixedProfile
function Base.length(p::FixedProfile)
    return 1
end

# length function for HourlyProfile
function Base.length(p::HourlyProfile)
    return length(p.val)
end

function split(start::Int, step::Int, stop::Int)
    return [i:min((i - 1) + step, stop) for i = start:step:stop]
end

function split(th::TimeHorizon)
    offset_start = th.start + th.offset
    if offset_start > th.start
        return vcat(
            [UnitRange(th.start, th.offset)],
            split(th.start + th.offset, th.split, th.stop),
        )
    elseif offset_start == th.start
        return split(th.start, th.split, th.stop)
    else
        error("First split must be greater than or equal to start")
    end
end

function prev_period(T::UnitRange{Int}, t::Int)
    t1 = T[1]
    if t == t1
        return T[end]
    elseif t in T
        return T[t-t1]
    else
        error("t $t must be in T $(T[1]):$(T[end])")
    end
end  # function prev_period


