using Documenter
using POMATWO

makedocs(
sitename="POMATWO.jl", 
format = Documenter.HTML(;
        canonical="https://ennowbrw.github.io/POMATWO/",
        edit_link="main",
        assets=String[],),
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
            "AC Power Flow" => "power_flow_ac.md"],
    "visualization" => Any[
        "Visualizing inputs" => "Visualizing_inputs.md",
        "Visualizing outputs" => "Visualizing_outputs.md" ]
        ])

deploydocs(repo = "ennowbrw.github.io/POMATWO/")