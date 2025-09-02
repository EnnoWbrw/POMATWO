#!/usr/bin/env julia

# Demonstration of the Data Reporting System with simulated data
# This shows how the reporting system would detect data quality issues

# Include the reporting system (copying just the essentials for this demo)
@enum DataReportLevel begin
    NOTE = 1
    WARNING = 2
    ERROR = 3
end

struct DataReportItem
    level::DataReportLevel
    category::String
    message::String
    location::String
end

mutable struct DataReport
    items::Vector{DataReportItem}
    has_errors::Bool
    
    DataReport() = new(Vector{DataReportItem}(), false)
end

function add_note!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(NOTE, category, message, location))
end

function add_warning!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(WARNING, category, message, location))
end

function add_error!(report::DataReport, category::String, message::String, location::String="")
    push!(report.items, DataReportItem(ERROR, category, message, location))
    report.has_errors = true
end

function print_report(report::DataReport; show_notes::Bool=true, show_warnings::Bool=true, show_errors::Bool=true)
    if isempty(report.items)
        println("✓ Data validation completed without issues")
        return
    end
    
    println("Data Validation Report:")
    println("=" ^ 50)
    
    if show_errors
        errors = filter(item -> item.level == ERROR, report.items)
        if !isempty(errors)
            println("\n❌ ERRORS ($(length(errors))):")
            for item in errors
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_warnings
        warnings = filter(item -> item.level == WARNING, report.items)
        if !isempty(warnings)
            println("\n⚠️  WARNINGS ($(length(warnings))):")
            for item in warnings
                location_str = isempty(item.location) ? "" : " [$(item.location)]"
                println("   • $(item.category): $(item.message)$location_str")
            end
        end
    end
    
    if show_notes
        notes = filter(item -> item.level == NOTE, report.items)
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

# Demo simulated validation scenarios
function demo_data_validation()
    println("=== Data Quality Reporting System Demo ===\n")
    
    # Scenario 1: Good quality data
    println("1. SCENARIO: High-quality data loading")
    println("=" ^ 50)
    
    good_report = DataReport()
    
    # Simulate successful data loading
    add_note!(good_report, "file_access", "Successfully found plants file", "data/plants.csv")
    add_note!(good_report, "structure_validation", "All required columns present", "data/plants.csv")
    add_note!(good_report, "data_validation", "Column 'g_max' validation passed", "data/plants.csv")
    add_note!(good_report, "data_validation", "Column 'eta' validation passed", "data/plants.csv")
    add_note!(good_report, "data_summary", "Loaded 15 plants successfully", "data/plants.csv")
    
    add_note!(good_report, "file_access", "Successfully found nodes file", "data/nodes.csv")
    add_note!(good_report, "configuration_validation", "Slack bus configuration is valid", "data/nodes.csv")
    add_note!(good_report, "data_summary", "Loaded 10 nodes successfully", "data/nodes.csv")
    
    print_report(good_report)
    
    # Scenario 2: Data with quality issues
    println("2. SCENARIO: Data with quality issues")
    println("=" ^ 50)
    
    problem_report = DataReport()
    
    # File access issues
    add_error!(problem_report, "file_access", "Required demand file does not exist", "data/demand.csv")
    add_warning!(problem_report, "file_access", "Optional availability file not found", "data/availability.csv")
    
    # Structure issues  
    add_error!(problem_report, "missing_columns", "Missing required columns: node, g_max", "data/plants.csv")
    add_warning!(problem_report, "missing_column", "Optional column 'storage_capacity' not found", "data/plants.csv")
    
    # Data type issues
    add_error!(problem_report, "data_type", "Column 'g_max' has 3 non-numeric values", "data/plants.csv")
    add_error!(problem_report, "missing_values", "Column 'eta' has 2 missing values", "data/plants.csv")
    
    # Range validation issues
    add_error!(problem_report, "range_validation", "Column 'g_max' has 1 non-positive values (must be > 0)", "data/plants.csv")
    add_warning!(problem_report, "range_validation", "Found 2 efficiency values outside [0,1] range", "data/plants.csv")
    
    # Configuration issues
    add_error!(problem_report, "duplicate_values", "Found 2 duplicate plant indices", "data/plants.csv")
    add_error!(problem_report, "configuration_error", "No slack bus defined (need at least one node with slack=1)", "data/nodes.csv")
    
    # Processing issues
    add_warning!(problem_report, "incomplete_data", "Skipping 3 rows with missing critical data", "data/plants.csv")
    
    print_report(problem_report)
    
    # Scenario 3: Mixed results
    println("3. SCENARIO: Mixed data quality (warnings but no critical errors)")
    println("=" ^ 50)
    
    mixed_report = DataReport()
    
    add_note!(mixed_report, "file_access", "Successfully found all required files", "data loading")
    add_note!(mixed_report, "structure_validation", "All required columns present", "data validation")
    
    add_warning!(mixed_report, "range_validation", "Found 3 plants with efficiency > 0.95 (unusually high)", "data/plants.csv")
    add_warning!(mixed_report, "data_validation", "Plant 'wind_offshore_01' has very high capacity (2000 MW)", "data/plants.csv")
    add_warning!(mixed_report, "configuration_warning", "Multiple slack buses defined (2)", "data/nodes.csv")
    
    add_note!(mixed_report, "data_summary", "Loaded 25 plants, 15 nodes, 3 zones", "data loading")
    add_note!(mixed_report, "processing_complete", "Data processing completed successfully", "post-processing")
    
    print_report(mixed_report)
    
    # Summary
    println("SUMMARY:")
    println("=" ^ 50)
    println("Scenario 1 (Good data):    $(good_report.has_errors ? "❌" : "✅") $(length(good_report.items)) items")
    println("Scenario 2 (Problems):     $(problem_report.has_errors ? "❌" : "✅") $(length(problem_report.items)) items")  
    println("Scenario 3 (Warnings):     $(mixed_report.has_errors ? "❌" : "✅") $(length(mixed_report.items)) items")
    
    println("\nKey Benefits of the Reporting System:")
    println("• Detailed categorization of issues (file, structure, data, configuration)")
    println("• Clear severity levels (Notes, Warnings, Errors)")
    println("• Location tracking for easy problem identification")
    println("• Backward compatibility with existing code")
    println("• Comprehensive validation beyond basic type checking")
end

# Run the demonstration
demo_data_validation()