
"""
    zonal_ptdf(PTDF, GSK) -> DenseAxisArray

Compute zonal PTDF (l×z) as PTDF(l×n) * GSK(n×z).

GSK rows are reordered to match PTDF's column (node) order before multiplying,
so the result is correct regardless of how the two arrays were built.
"""
function zonal_ptdf(PTDF::DenseAxisArray, GSK::DenseAxisArray)
    nodes_ptdf = axes(PTDF, 2)
    nodes_gsk  = axes(GSK, 1)
    @assert length(nodes_ptdf) == length(nodes_gsk) "PTDF is l×n, GSK must be n×z (size mismatch)"
    @assert Set(collect(nodes_ptdf)) == Set(collect(nodes_gsk)) "PTDF and GSK must cover the same node set"
    # Reorder GSK rows to match PTDF column order for a correct matrix product
    GSK_aligned = GSK[collect(nodes_ptdf), :]
    PTDFz_mat = round.(PTDF.data * GSK_aligned.data, digits=4)
    PTDFz = JuMP.Containers.DenseAxisArray(PTDFz_mat, axes(PTDF, 1), axes(GSK, 2))
    return PTDFz
end

"""
    zone_to_zone_ptdf(PTDFz; exclude_self=true)

Build the zone→zone PTDF for all ordered pairs (z_export, z_import).

- `PTDFz` is a DenseAxisArray(l×z) from `zonal_ptdf`.
- Returns a DenseAxisArray where:
   * Rows are indexed by line labels (from PTDFz)
   * Columns are indexed by (z_export, z_import) tuples
   * m = z*(z-1) if `exclude_self` (default), else z*z

# Example
```julia
PTDFz = zonal_ptdf(PTDFn, GSK)  # Returns DenseAxisArray with lines × zones
PTDFzz = zone_to_zone_ptdf(PTDFz)  # Returns DenseAxisArray with lines × zone_pairs
# Access specific zone-to-zone PTDF: PTDFzz[line_id, ("DE", "FR")]
```
"""
function zone_to_zone_ptdf(PTDFz::DenseAxisArray; exclude_self::Bool=true)
    lines = axes(PTDFz, 1)
    zones = axes(PTDFz, 2)
    
    l = length(lines)
    z = length(zones)
    m = exclude_self ? z*(z-1) : z*z
    
    T = eltype(PTDFz)
    M = Matrix{T}(undef, l, m)
    pairs = Vector{Tuple{String,String}}(undef, m)
    
    k = 1
    for z_import in zones          # importer
        for z_export in zones      # exporter
            if exclude_self && z_export == z_import
                continue
            end
            # column = PTDFz[:, importer] - PTDFz[:, exporter]
            # Use DenseAxisArray indexing directly with zone labels
            M[:, k] = PTDFz[:, z_import] .- PTDFz[:, z_export]
            pairs[k] = (z_export, z_import)
            k += 1
        end
    end
    
    # Return as DenseAxisArray indexed by lines and zone pairs
    PTDFzz = Containers.DenseAxisArray(M, lines, pairs)
    return PTDFzz
end



"""
    define_cne(params::Parameters, PTDFzz::DenseAxisArray; threshold::Float64=0.05)

Identify Critical Network Elements (CNE) based on zone-to-zone PTDF values and store results in params.

A line is classified as a CNE if the maximum absolute PTDF value across all zone pairs
exceeds the specified threshold. Lines not meeting this criterion are zeroed out in the
returned matrix. The cne_indicator results are saved to params.cne_indicator as a
dictionary indexed by (line, (zone_export, zone_import)).

# Arguments
- `params::Parameters`: Parameters object where cne_indicator will be stored
- `PTDFzz`: DenseAxisArray from `zone_to_zone_ptdf` (lines × zone pairs)
- `threshold`: Absolute value threshold for PTDF selection (default 0.05)

# Returns
- `CNE`: DenseAxisArray with entries below threshold zeroed out

# Side Effects
- Updates `params.cne_indicator` with binary indicators (1 if above threshold, 0 otherwise)

# Example
```julia
PTDFzz = zone_to_zone_ptdf(PTDFz)
CNE = define_cne!(params, PTDFzz; threshold=0.05)
```
"""
function define_cne!(params::Parameters, PTDFzz::DenseAxisArray; threshold::Float64=0.05)
    # If no initial list is provided, start from all network lines
    if isempty(params.cne)
        append!(params.cne, params.sets.L)
    end

    fbccr_zones = Set(params.sets.FBCCR)

    # A line qualifies as CNE only if at least one endpoint node belongs to an FBCCR zone
    # and its max absolute PTDF across all zone pairs exceeds the threshold
    filter!(params.cne) do line
        z_start = get(params.node2zone, get(params.line_start, line, ""), "")
        z_end   = get(params.node2zone, get(params.line_end,   line, ""), "")
        (z_start in fbccr_zones || z_end in fbccr_zones) &&
            maximum(abs.(PTDFzz[line, :])) > threshold
    end
end


"""
    calc_ram(params, TwoDayAhead_results, PTDFz, PTDFzz, PTDFn, T; minRAM, FRM)

Compute the Available Remaining Margin (RAM) for every CNE line and timestep.

The calculation follows the standard FBMC methodology:

1. Basecase flow (f0):  
   `f0[l,t] = lineflow[l,t] - Σ_z PTDFz[l,z] * NP[z,t]`

2. Additional Margin Requirement (AMR) — ensures the 70 %‑rule:  
   `AMR[l,t] = max(0, minRAM * f̄[l] - (f̄[l] - f0[l,t] - FRM[l]))`

3. RAM:  
   `RAM[l,t] = f̄[l] - f0[l,t] - FRM[l] + AMR[l,t]`

# Arguments
- `params`: model parameters (acline_capacity, nodes_in_zone, cne, sets.Z)
- `TwoDayAhead_results`: dict with `:lineflows` (DenseAxisArray [l,t]) and `:netinput` (DenseAxisArray [n,t])
- `PTDFz`: zonal PTDF matrix (l×z)
- `PTDFzz`: zone-to-zone PTDF matrix (l×zone_pairs)
- `PTDFn`: nodal PTDF matrix (l×n)
- `T`: time range

# Keyword Arguments
- `minRAM`: minimum RAM fraction of line capacity (default `0.7`, i.e. 70 %-rule)
- `FRM`: Flow Reliability Margin as a fraction of capacity (default `0.0`)

# Returns
- `ram`: DenseAxisArray indexed by `(line, t, direction)` where `direction ∈ ["pos", "neg"]`,
  accessible as `ram[l, t, "pos"]` or `ram[l, t, "neg"]`
"""
function calc_ram(params::Parameters, TwoDayAhead_results::Dict, PTDFz::DenseAxisArray, PTDFzz::DenseAxisArray, PTDFn::DenseAxisArray, T::UnitRange; minRAM::Float64=0.7, FRM::Float64=0.1)
    cne_lines = params.cne

    # lineflows[l, t] and netinput[n, t] from TwoDayAhead basecase
    lineflows    = TwoDayAhead_results[:lineflows]
    netinput_ac  = TwoDayAhead_results[:netinput_ac]

    # Net position per zone per timestep: NP[z, t] = Σ_n∈z netinput[n, t]
    zones = params.sets.Z
    NP = Dict{Tuple{String, Int}, Float64}()
    for z in zones, t in T
        NP[z, t] = -sum(netinput_ac[n, t] for n in params.nodes_in_zone[z])
    end

    # Basecase flow f0[l, t]: observed flow minus the part explained by zonal net positions
    # f0[l,t] = lineflow[l,t] - Σ_z PTDFz[l,z] * NP[z,t]
    l0 = Dict{Tuple{String, Int}, Float64}()
    for l in cne_lines, t in T
        l0[l, t] = lineflows[l, t] - sum(PTDFz[l, z] * NP[z, t] for z in zones)
    end
    # Steps to include non flow based zones (which is not currently accounted for):
    #𝐹⃗0FB -> flow per CNEC in the situation without commercial exchanges within the flow based CCR
    #𝐹⃗0FB = 𝐹⃗𝑟𝑒𝑓 − 𝐏𝐓𝐃𝐅𝒇 𝑁𝑃⃗𝑟𝑒𝑓FB
    #𝐹⃗0𝑎𝑙𝑙 = 𝐹𝑟𝑒𝑓 − 𝐏𝐓𝐃𝐅𝒂𝒍𝒍 𝑁𝑃⃗𝑟𝑒𝑓𝑎𝑙𝑙 
    #𝐹⃗𝑢𝑎𝑓 = 𝐹⃗0FB − 𝐹⃗0𝑎𝑙𝑙
    #𝐴𝑀𝑅 = 𝑚𝑎𝑥 (𝑅𝑎𝑚𝑟 ∙ 𝐹𝑚𝑎𝑥 − 𝐹𝑢𝑎𝑓 − (𝐹𝑚𝑎𝑥 − 𝐹𝑅𝑀 − 𝐹0FB),
    #              0.2 ∙ 𝐹𝑚𝑎𝑥 − (𝐹𝑚𝑎𝑥 − 𝐹𝑅𝑀 − 𝐹0FB), 0)
    # see: https://www.acer.europa.eu/sites/default/files/documents/Media/News/Documents/Amendment-DA-CCM-CCR-2026.pdf
    # P. 32 ff.

    # Build RAM as DenseAxisArray indexed by (line, t, direction)
    # RAM_pos[l,t]: maximum flow in positive direction
    # RAM_neg[l,t]: maximum flow in negative direction (negative value)
    #
    # init_pos  = Fmax - f0 - FRM
    # init_neg  = -Fmax - f0 + FRM
    # AMR_pos   = max(0, minRAM * Fmax  - init_pos)   ≥ 0
    # AMR_neg   = min(0, minRAM * -Fmax - init_neg)   ≤ 0
    # RAM_pos   = init_pos + AMR_pos   → floor at  minRAM * Fmax
    # RAM_neg   = init_neg + AMR_neg   → ceiling at minRAM * -Fmax
    directions = ["pos", "neg"]
    ram_data = Array{Float64, 3}(undef, length(cne_lines), length(T), 2)

    for (i, line) in enumerate(cne_lines)
        f_max   = get(params.acline_capacity, line, 0.0)
        frm_abs = FRM * f_max
        for (j, t) in enumerate(T)
            f0       = l0[line, t]
            init_pos = f_max - f0 - frm_abs
            init_neg = -f_max - f0 + frm_abs
            amr_pos  = max(0.0,  minRAM *  f_max - init_pos)
            amr_neg  = min(0.0,  minRAM * -f_max - init_neg)
            ram_data[i, j, 1] = init_pos + amr_pos   # RAM_pos: floor at minRAM*Fmax
            ram_data[i, j, 2] = init_neg + amr_neg   # RAM_neg: ceiling at minRAM*(-Fmax)
        end
    end

    ram = Containers.DenseAxisArray(ram_data, cne_lines, collect(T), directions)
    return ram
end


function dict_to_matrix(d::Dict{Tuple{String, String}, Float64})
    # Extract unique row and column keys
    rows = sort(unique([k[1] for k in keys(d)]))
    cols = sort(unique([k[2] for k in keys(d)]))
    
    # Create matrix
    matrix = zeros(Float64, length(rows), length(cols))
    
    # Fill matrix
    for ((row_key, col_key), value) in d
        i = findfirst(==(row_key), rows)
        j = findfirst(==(col_key), cols)
        matrix[i, j] = value
    end
    
    return  JuMP.Containers.DenseAxisArray(matrix, rows, cols)
end

"""
    calc_fbmc_params(sr::SubRun, params::Parameters, TwoDayAhead_result::Dict; zone_order=nothing, normalize_empty=:flat)

Calculate FBMC parameters: GSK, PTDFn, PTDFz, PTDFzz.

# Arguments
- `sr::SubRun`: SubRun containing the model run setup (used to extract GSKStrategy)
- `params::Parameters`: Parameters containing network data
- `TwoDayAhead_result::Dict`: Results from the TwoDayAhead basecase optimization

# Keyword Arguments
- `zone_order`: Optional vector specifying the order of zones. If `nothing`, zones are sorted.
- `normalize_empty`: Symbol controlling handling of zones with zero total weight in GSK.    
    * `:zero` → column of zeros
    * `:flat` → uniform distribution across zone members (default)

# Returns
- `Dict` with keys:
    * `:GSK` => GSK matrix (n×z)
    * `:PTDFn` => Nodal PTDF matrix (l×n)
    * `:PTDFz` => Zonal PTDF matrix (l×z)
    * `:PTDFzz` => Zone-to-zone PTDF matrix (l×m)
    * `:RAM` => Dict mapping lines to remaining available margin
"""
function calc_fbmc_params(sr::SubRun, params::Parameters, TwoDayAhead_result::Dict, T; kwargs...)
    # Extract GSKStrategy from the market setup and delegate to the strategy-based core
    gsk_strategy = sr.modelrun.setup.MarketType.exchange_formulation.GSKStrategy
    return calc_fbmc_params(gsk_strategy, params, TwoDayAhead_result, T; kwargs...)
end

"""
    calc_fbmc_params(gsk_strategy::GSKStrategy, params, basecase_result, T; kwargs...)

Core FBMC parameter calculation, independent of a `SubRun`. `basecase_result`
is any dict with `:netinput_ac` (n×t) and `:lineflows` (l×t) — from the
`TwoDayAhead` optimization or from [`build_refday_basecase`](@ref).
"""
function calc_fbmc_params(gsk_strategy::GSKStrategy, params::Parameters, TwoDayAhead_result::Dict, T; zone_order=nothing, normalize_empty::Symbol=:flat, minRAM::Float64=0.7, FRM::Float64=0.1)
    GSK = build_gsk(params, gsk_strategy; normalize_empty=normalize_empty)
    PTDFn = dict_to_matrix(params.ptdf) 
    PTDFz = zonal_ptdf(PTDFn, GSK)
    PTDFzz = zone_to_zone_ptdf(PTDFz; exclude_self=true)
    define_cne!(params, PTDFzz; threshold=0.05)
    cne = params.cne
    PTDFz  = PTDFz[cne, :]
    PTDFzz = PTDFzz[cne, :]
    RAM = calc_ram(params, TwoDayAhead_result, PTDFz, PTDFzz, PTDFn, T; minRAM=minRAM, FRM=FRM)
    fbmc_params = Dict(
        :GSK => GSK,
        :PTDFn => PTDFn,
        :PTDFz => PTDFz,
        :PTDFzz => PTDFzz,
        :RAM => RAM 
    )
    return fbmc_params
end
