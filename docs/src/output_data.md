# Model Data
## Load Data Output
Model outputs are stored in .arrow files. These files are non-human-readable, but are significantly faster to process compared to other formats like CSV or XLSX. To further process model results, they can be read-in by calling the DataFiles constructor
```@docs
DataFiles
```
```@docs
check_infeasibility
```
Each market state writes its tables under its own filename prefix, so the stages of one run cannot overwrite each other. The prefix and the names accepted by `DataFiles(dir; type = ...)` are given by:
```@docs
POMATWO.result_prefix
POMATWO.market_state_type
```
The following functions can be used to create some useful tables automatically.
```@docs
transform_results_by_type
```
```@docs
summarize_result
```
```@docs
get_redispatch_by_type_node
```
```@docs
get_market_statistics
```