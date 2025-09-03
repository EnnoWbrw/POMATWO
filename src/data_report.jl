"""
    DataReportLevel

Enumeration for different levels of data validation reports.
"""
@enum DataReportLevel begin
    NOTE = 1
    WARNING = 2
    ERROR = 3
end

"""
    DataReportItem

Structure representing a single data validation report item.

# Fields
- `level::DataReportLevel`: The severity level (NOTE, WARNING, ERROR)
- `category::String`: Category of the validation issue (e.g., "file_access", "data_type", "range")
- `message::String`: Descriptive message about the validation issue
- `location::String`: Location where the issue was found (e.g., file path, column name)
"""
struct DataReportItem
    level::DataReportLevel
    category::String
    message::String
    location::String
end

"""
    DataReport

Container for collecting data validation reports during data loading.

# Fields
- `items::Vector{DataReportItem}`: Collection of all report items
- `has_errors::Bool`: Quick check if any errors were reported
"""
mutable struct DataReport
    items::Vector{DataReportItem}
    has_errors::Bool
    
    DataReport() = new(Vector{DataReportItem}(), false)
end

"""
    add_note!(report::DataReport, category::String, message::String, location::String="")

Add a note-level report item to the data report.
"""
function add_note!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(NOTE, category, message, location))
end

"""
    add_warning!(report::DataReport, category::String, message::String, location::String="")

Add a warning-level report item to the data report.
"""
function add_warning!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(WARNING, category, message, location))
end

"""
    add_error!(report::DataReport, category::String, message::String, location::String="")

Add an error-level report item to the data report.
"""
function add_error!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(ERROR, category, message, location))
    report.has_errors = true
end

"""
    get_errors(report::DataReport)

Return all error-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `ERROR`.
"""
get_errors(report::DataReport) = filter(item -> item.level == ERROR, report.items)

"""
    get_warnings(report::DataReport)

Return all warning-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `WARNING`.
"""
get_warnings(report::DataReport) = filter(item -> item.level == WARNING, report.items)

"""
    get_notes(report::DataReport)

Return all note-level items from the data report.

# Arguments
- `report::DataReport`: The data report to filter.

# Returns
- `Vector{DataReportItem}`: All items with level `NOTE`.
"""
get_notes(report::DataReport) = filter(item -> item.level == NOTE, report.items)

"""
    has_issues(report::DataReport)

Check if the report contains any items (notes, warnings, or errors).
"""
has_issues(report::DataReport) = !isempty(report.items)

"""
    print_report(report::DataReport; show_notes::Bool=true, show_warnings::Bool=true, show_errors::Bool=true)

Print a formatted summary of the data report.
"""
function print_report(report::DataReport; show_notes::Bool=true, show_warnings::Bool=true, show_errors::Bool=true)
    if !has_issues(report)
        println("✓ Data loading completed without issues")
        return
    end
    
    println("Data Loading Report:")
    println("=" ^ 50)
    
    if show_errors
        errors = get_errors(report)
        if !isempty(errors)
            println("\n❌ ERRORS ($(length(errors))):")
            for item in errors
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_warnings
        warnings = get_warnings(report)
        if !isempty(warnings)
            println("\n⚠️  WARNINGS ($(length(warnings))):")
            for item in warnings
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_notes
        notes = get_notes(report)
        if !isempty(notes)
            println("\n📝 NOTES ($(length(notes))):")
            for item in notes
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    println()
end

"""
    validate_file_exists(report::DataReport, path::String, description::String="file")

Validate that a file exists and is readable, adding appropriate reports.
"""
function validate_file_exists(report::DataReport, path::String, description::String="file")
    if !isfile(path)
        add_error!(report, "file_access", "Required $description does not exist", path)
        return false
    end
    return true
end

"""
    validate_numeric_column(report::DataReport, df::AbstractDataFrame, column::Symbol, 
                           location::String; required::Bool=true, positive::Bool=false)

Validate that a column contains numeric values with optional constraints.
"""
function validate_numeric_column(report::DataReport, df::AbstractDataFrame, column::Symbol, 
                                location::String; required::Bool=true, positive::Bool=false)
    if !hasproperty(df, column)
        if required
            add_error!(report, "missing_column", "Required column '$column' not found", location)
        else
            add_note!(report, "missing_column", "Optional column '$column' not found", location)
        end
        return false
    end
    
    col_data = df[!, column]
    
    # Check for missing values in required columns
    if required && any(ismissing, col_data)
        missing_count = count(ismissing, col_data)
        add_error!(report, "missing_values", 
                  "Column '$column' has $missing_count missing values", location)
    end
    
    # Check data types
    non_missing_data = skipmissing(col_data)
    if !all(x -> isa(x, Number), non_missing_data)
        non_numeric_count = count(x -> !isa(x, Number), non_missing_data)
        add_error!(report, "data_type", 
                  "Column '$column' has $non_numeric_count non-numeric values", location)
        return false
    end
    
    # Check positive constraint
    if positive && any(x -> x < 0, non_missing_data)
        negative_count = count(x -> x < 0, non_missing_data)
        add_error!(report, "range_validation", 
                  "Column '$column' has $negative_count negative values (must be >= 0)", location)
    end
    
    return true
end

"""
    validate_required_columns(report::DataReport, df::AbstractDataFrame, 
                             required_columns::Vector{Symbol}, location::String)

Validate that all required columns are present in a DataFrame.
"""
function validate_required_columns(report::DataReport, df::AbstractDataFrame, 
                                 required_columns::Vector{Symbol}, location::String)
    missing_columns = Symbol[]
    for col in required_columns
        if !hasproperty(df, col)
            push!(missing_columns, col)
        end
    end
    
    if !isempty(missing_columns)
        add_error!(report, "missing_columns", 
                  "Missing required columns: $(join(missing_columns, ", "))", location)
        return false
    end
    
    return true
end