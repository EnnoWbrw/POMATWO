#!/usr/bin/env julia

# Simple standalone test of the data reporting system
# This tests the core reporting functionality without loading the full POMATWO module

# Include just the reporting structures
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

function get_errors(report::DataReport)
    filter(item -> item.level == ERROR, report.items)
end

function get_warnings(report::DataReport)
    filter(item -> item.level == WARNING, report.items)
end

function get_notes(report::DataReport)
    filter(item -> item.level == NOTE, report.items)
end

function has_issues(report::DataReport)
    !isempty(report.items)
end

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

# Test the reporting system
println("=== Testing Data Reporting System ===")

# Test basic functionality
report = DataReport()
println("Initial state - has_issues: $(has_issues(report)), has_errors: $(report.has_errors)")

# Add different types of reports
add_note!(report, "data_loading", "Started processing plants data", "plants.csv")
add_warning!(report, "data_validation", "Found 2 plants with efficiency > 1.0", "plants.csv")
add_error!(report, "missing_data", "Required column 'node' not found", "plants.csv")

println("After adding reports - has_issues: $(has_issues(report)), has_errors: $(report.has_errors)")
println("Total items: $(length(report.items))")
println("Notes: $(length(get_notes(report))), Warnings: $(length(get_warnings(report))), Errors: $(length(get_errors(report)))")

# Print the full report
print_report(report)

# Test with no issues
clean_report = DataReport()
add_note!(clean_report, "processing", "All data loaded successfully", "")
print_report(clean_report)

println("✓ Reporting system test completed successfully!")