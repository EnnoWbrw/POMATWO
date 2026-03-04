
"""
    zonal_ptdf(PTDF, GSK) -> Matrix

Compute zonal PTDF (l×z) as PTDF(l×n) * GSK(n×z).

Assumes that the columns of PTDF correspond to `nodes` in the same order
used to build GSK.
"""
function zonal_ptdf(PTDF::DenseAxisArray, GSK::DenseAxisArray)
    @assert size(PTDF, 2) == size(GSK, 1) "PTDF is l×n, GSK must be n×z"
   PTDFz_mat = round.(PTDF.data * GSK.data, digits=4)
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

Filters the zone-to-zone PTDF matrix to retain only lines with absolute PTDF values 
above the specified threshold for each zone pair. The cne_indicator results are saved
to params.cne_indicator as a dictionary indexed by (line, (zone_export, zone_import)).

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
function define_cne(params::Parameters, PTDFzz::DenseAxisArray; threshold::Float64=0.05)
    lines = axes(PTDFzz, 1)
    pairs = axes(PTDFzz, 2)
    
    # Create a copy to avoid modifying original
    CNE = Containers.DenseAxisArray(copy(PTDFzz.data), lines, pairs)
    
    # Zero out all entries with absolute value below threshold
    CNE.data[abs.(CNE.data) .< threshold] .= 0
    
    # Store binary indicator matrix in params: 1 if above threshold, 0 otherwise
    for (i, line) in enumerate(lines)
        for (j, pair) in enumerate(pairs)
            indicator = abs(PTDFzz.data[i, j]) >= threshold ? 1 : 0
            params.cne_indicator[line, pair] = indicator
        end
    end
    
    return CNE
end


"""
    calc_ram(params::Parameters, TwoDayAhead_results::Dict, PTDFzz::DenseAxisArray)

Build Reserve Available Margin (RAM) for transmission lines.

For non-CNE lines, RAM equals the line capacity from params. For CNE lines, RAM is the maximum of:
1. 70% of line capacity, or
2. Line capacity minus current lineflow.

# Arguments
- `params::Parameters`: Parameters object containing acline_capacity and cne_indicator
- `TwoDayAhead_results::Dict`: Results dictionary with :lineflows key containing lineflow data
- `PTDFzz::DenseAxisArray`: Zone-to-zone PTDF matrix (lines × zone pairs)

# Returns
- `ram::Dict{String,Float64}`: Dictionary mapping line names to their RAM values
"""
function calc_ram(params::Parameters, TwoDayAhead_results::Dict, PTDFzz::DenseAxisArray)
    lines = axes(PTDFzz, 1)
    pairs = axes(PTDFzz, 2)
    
    # Initialize RAM dictionary
    ram = Dict{String,Float64}()
    
    # Get lineflows from TwoDayAhead_results
    lineflows = TwoDayAhead_results[:lineflows]

    get_lineflow(line::String) = if lineflows isa AbstractDict
        abs(get(lineflows, line, 0.0))
    elseif lineflows isa DenseAxisArray
        line_idx = findfirst(==(line), axes(lineflows, 1))
        isnothing(line_idx) && return 0.0

        if ndims(lineflows) == 1
            abs(lineflows.data[line_idx])
        elseif ndims(lineflows) == 2
            maximum(abs, @view lineflows.data[line_idx, :])
        else
            error("Unsupported lineflows dimensions in calc_ram: $(ndims(lineflows)). Expected 1D or 2D.")
        end
    else
        error("Unsupported lineflows container type in calc_ram: $(typeof(lineflows)).")
    end
    
    # Process each line
    for (i, line) in enumerate(lines)
        # Check if this line is a CNE (any 1 in its row)
        is_cne = any(get(params.cne_indicator, (line, pair), 0) == 1 for pair in pairs)
        
        # Get capacity from params
        capacity = get(params.acline_capacity, line, 0.0)
        
        if is_cne
            # For CNE lines: max of 70% capacity or (capacity - lineflow)
            flow = get_lineflow(line)
            option1 = 0.7 * capacity
            option2 = capacity - flow
            ram[line] = max(option1, option2)
        else
            # For non-CNE lines: full capacity
            ram[line] = capacity
        end
    end   
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
function calc_fbmc_params(sr::SubRun, params::Parameters, TwoDayAhead_result::Dict ; zone_order=nothing, normalize_empty::Symbol=:flat)
    # Extract GSKStrategy from the market setup
    market_type = sr.modelrun.setup.MarketType
    gsk_strategy = market_type.exchange_formulation.GSKStrategy
    
    GSK = build_gsk(params, gsk_strategy; normalize_empty=normalize_empty)
    PTDFn = dict_to_matrix(params.ptdf) 
    PTDFz = zonal_ptdf(PTDFn, GSK)
    PTDFzz = zone_to_zone_ptdf(PTDFz; exclude_self=true)
    CNE = define_cne(params, PTDFzz; threshold=0.05)
    RAM = calc_ram(params, TwoDayAhead_result, PTDFzz)
    fbmc_params = Dict(
        :GSK => GSK,
        :PTDFn => PTDFn,
        :PTDFz => PTDFz,
        :PTDFzz => PTDFzz,
        :RAM => RAM 
    )
    return fbmc_params
end
