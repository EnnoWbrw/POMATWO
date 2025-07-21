# Model Data
## Output Data Load
Model outputs are stored in .arrow files. These files are non-human-readable, but are significantly faster to process compared to other formats like CSV or XLXS. To further process model results, they can be read-in by calling the DataFiles constructor
```@docs
DataFiles
```
The following functions can be used to create some useful tables automatically.
```@docs
transform_results_by_type
```
```@docs
summarize_result
```

## Visualizing Output Data
POMATWO supports different visualizations to analyze the model results. 
### Interactive Plots
```@docs
plot_market_interactive(results; time_horizon=nothing, scalefactor=1/1000, kind=:DA)
```
```@docs
plot_DA_w_Redisp_interactive(results; time_horizon = nothing, scalefactor = 1/1000)
```
```@docs
plot_total_gen_interactive(results::DataFiles)
```
### Static Plots
