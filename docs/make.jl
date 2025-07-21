using Documenter
using POMATWO

makedocs(
sitename="POMATWO.jl", 
format = Documenter.HTML(),
modules = [POMATWO],
authors = "Enno Wiebrow, Kristin Dietrich, Mario Kendziorski", 
pages = [
    "Home" => "index.md",
    "Model Data" => Any["Input Data" => "input_data.md",
                        "Output Data" => "output_data.md"
    ],
    "Model Configuration" => Any["Market Definition" => "market_definitions.md",
                                 "Model Creation" => "Model_config.md" ],
    "Mathematical Model" => Any[
            "Nomenclature" => "nomenclature.md",
            "Market Model" => "market_model.md",
            "AC Power Flow" => "power_flow_ac.md"]
        ])

deploydocs(repo = "github.com/EnnoWbrw/POMATWO.jl.git",)