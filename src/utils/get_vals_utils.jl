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

function value_or_number(x::T) where {T<:Union{GenericVariableRef,AffExpr}}
    return value(x)
end

function value_or_number(x)
    return x
end

function dual_or_number(x::T) where {T<:Union{ConstraintRef,AffExpr,LinkConstraintRef}}
    return dual(x)
end

function dual_or_number(x)
    return x
end

function getts(avail, plant, t)
    if plant in keys(avail)
        return avail[plant][t]
    else
        return 1
    end
end
