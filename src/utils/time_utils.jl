
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
