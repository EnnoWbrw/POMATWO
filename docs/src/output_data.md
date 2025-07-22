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
