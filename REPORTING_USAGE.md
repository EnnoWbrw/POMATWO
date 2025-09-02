# Example: Using the POMATWO Data Reporting System

## Overview
The POMATWO package now includes a comprehensive data reporting system that provides detailed validation feedback when loading electricity market data. This system helps identify data quality issues early and provides clear guidance for fixing them.

## Basic Usage

### Loading Data with Reports
```julia
using POMATWO

# Your data file paths
data_files = Dict{Symbol,String}(
    :plants => "data/plants.csv",
    :nodes => "data/nodes.csv", 
    :zones => "data/zones.csv",
    :demand => "data/demand.csv",
    :types => "data/planttypes.csv"
)

# Option 1: Use the new reporting function
params, report = load_data_with_report(data_files)

# Check if there were any issues
if report.has_errors
    println("❌ Data loading failed with critical errors:")
    print_report(report)
    # Handle errors before proceeding
else
    println("✅ Data loaded successfully!")
    print_report(report)  # Shows any warnings or notes
    
    # Continue with your modeling...
    setup = ModelSetup(...)
    mr = ModelRun(params, setup, solver)
    run(mr)
end
```

### Backward Compatibility
```julia
# Option 2: Use the original function (still works!)
params = load_data(data_files)
# This will show warnings/errors but continue execution
```

## Report Structure

### Report Levels
- **📝 NOTES**: Informational messages (data loaded successfully, defaults applied)
- **⚠️ WARNINGS**: Potential issues that don't prevent execution (unusual values, optional files missing)
- **❌ ERRORS**: Critical issues that prevent proper functioning (missing files, invalid data)

### Report Categories
- `file_access`: File existence and readability
- `missing_columns`: Required or optional columns not found
- `missing_values`: Missing data in required fields
- `data_type`: Non-numeric data in numeric columns
- `range_validation`: Values outside expected ranges
- `duplicate_values`: Duplicate indices or identifiers
- `configuration_error`: Critical setup issues
- `incomplete_data`: Rows with missing critical information

## Example Reports

### High-Quality Data
```
Data Validation Report:
==================================================

📝 NOTES (5):
   • file_access: Successfully found plants file [data/plants.csv]
   • structure_validation: All required columns present [data/plants.csv]
   • data_validation: Column 'g_max' validation passed [data/plants.csv]
   • data_summary: Loaded 15 plants successfully [data/plants.csv]
   • processing_complete: Data processing completed successfully [post-processing]
```

### Problematic Data
```
Data Validation Report:
==================================================

❌ ERRORS (3):
   • file_access: Required demand file does not exist [data/demand.csv]
   • range_validation: Column 'g_max' has 1 non-positive values (must be > 0) [data/plants.csv]
   • configuration_error: No slack bus defined (need at least one node with slack=1) [data/nodes.csv]

⚠️ WARNINGS (2):
   • range_validation: Found 2 efficiency values outside [0,1] range [data/plants.csv]
   • configuration_warning: Multiple slack buses defined (2) [data/nodes.csv]
```

## Detailed Validations

### Plants Data Validation
- ✅ Required columns: `index`, `plant_type`, `node`, `g_max`, `eta`
- ✅ Positive values: `g_max` > 0, `storage_capacity` > 0, `storage_power` > 0
- ✅ Efficiency range: `eta` ∈ [0, 1] (warns if outside)
- ✅ No duplicate plant indices
- ✅ Proper data types in numeric columns

### Nodes Data Validation
- ✅ Required columns: `index`, `zone`, `slack`
- ✅ Slack bus configuration: exactly one node with `slack = 1` (warns if multiple)
- ✅ Binary values: `slack` ∈ {0, 1}
- ✅ No duplicate node indices
- ✅ Coordinate validation (if provided)

### Zones Data Validation
- ✅ Required columns: `index`
- ✅ No duplicate zone indices

### Types Data Validation
- ✅ Required columns: `index`, `dispatchable`
- ✅ Binary values: `dispatchable`, `prosumer`, `storage` ∈ {0, 1}
- ✅ Positive values: `fuel_price` > 0, `co2content` > 0

## Integration with Existing Workflows

The reporting system is designed to be minimally disruptive:

1. **Existing code continues to work** - The original `load_data()` function still exists
2. **Enhanced validation** - New function `load_data_with_report()` provides detailed feedback
3. **Configurable reporting** - Control what types of messages are shown
4. **Location tracking** - Easily identify which files and columns have issues

## Benefits

1. **Early Problem Detection**: Catch data issues before they cause model failures
2. **Clear Error Messages**: Understand exactly what's wrong and where
3. **Data Quality Assurance**: Ensure your input data meets model requirements
4. **Debugging Support**: Detailed validation helps trace problems to their source
5. **Professional Workflows**: Better error handling for production environments

## Migration Guide

To update existing code:

```julia
# Before
params = load_data(data_files)

# After (recommended)
params, report = load_data_with_report(data_files)
if report.has_errors
    error("Please fix data issues before proceeding")
end
```