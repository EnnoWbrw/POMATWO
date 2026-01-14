
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

function  calc_ram(params, TwoDayAhead_result, PTDFzz)
    # Placeholder RAM calculation
    # In practice, this would involve detailed calculations based on network data
    return Dict(zip(params.sets.L,[22, 32, 28]))   # Example fixed RAM factor
end

function calc_fbmc_params(sr::SubRun, params::Parameters, TwoDayAhead_result::Dict ; zone_order=nothing, normalize_empty::Symbol=:flat)
    # Extract GSKStrategy from the market setup
    market_type = sr.modelrun.setup.MarketType
    gsk_strategy = market_type.exchange_formulation.GSKStrategy
    
    GSK = build_gsk(params, gsk_strategy; normalize_empty=normalize_empty)
    PTDFn = dict_to_matrix(params.ptdf) 
    PTDFz = zonal_ptdf(PTDFn, GSK)
    PTDFzz = zone_to_zone_ptdf(PTDFz; exclude_self=true)
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
