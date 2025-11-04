# POMATWO.jl
[![Main](https://img.shields.io/badge/docs-main-green)](https://ennowbrw.github.io/POMATWO/dev/)
[![Build Status](https://github.com/EnnoWbrw/POMATWO/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/EnnoWbrw/POMATWO/actions?query=workflow%3ACI+branch%3Amain)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)


This README provides an overview of the Model POMATWO.

It is handled by the Workgroup for Economic and Infrastructure Policy (WIP) at 
TU Berlin 
  
## Purpose of the model  

POMATWO is an electricity market model designed to determine the optimal electricity
supply by minimize system costs on an hourly basis. It incorporates market clearing conditions, market zone-specific merit order curves, 
grid topology, and network constraints. Using a multi-step approach, POMATWO can 
simulate both the electricity generation of the day-ahead market and final dispatch decisions.

## Model design philosophy  
The design of POMATWO adopts a multistep approach, emphasizing the structured and 
systematic representation of electricity markets. The workflow consists of distinct 
yet interconnected stages. It begins with the simulation of a perfectly competitive market,
where electricity generation is allocated cost-efficiently based on the merit-order principle.
This step ensures market clearing conditions are met while minimizing production costs.

POMATWO also cantains a feature for performing a DCOPF redispatch to adress grid constraints. 
Using DC optimal power flow calculations, POMATWO determines redispatch actions
necessary to manage congestion, aiming to minimize the extent of these adjustments 
and maintain system stability.

## Core assumption  
POMATWO operates under the assumption of perfect foresight, minimizing system costs 
while accounting for the market clearing of zonal markets and adhering to the
merit-order principle. This approach implies an underlying assumption of perfect 
competition in the electricity generation market, where producers are presumed 
to bid at their marginal costs to maximize profits. 

The model is able to determine redispatch actions required to address congestion,
by minimizing the scale of these adjustments to maintain grid stability. 

## Licencing
The POMATWO model and all additional files in the git repository are licensed under the MIT license.That means you can use and change the code of POMATWO. Furthermore, you can change the license in your redistribution but must mention the original author. We appreciate if you inform us about changes and send a merge request via git. For further information please read the LICENSE file, which contains the license text, or go to https://opensource.org/licenses/MIT

## Building the documentation
The docs are built with Documenter.jl in an isolated environment under `docs/`. To avoid stale dependency pins, we do not commit `docs/Manifest.toml`.

- Locally, build the docs with a fresh resolve:

	PowerShell:

	```powershell
	# Recommended (two-step, avoids quoting pitfalls)
	julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()"
	julia --project=docs docs/make.jl

	# Or a one-liner (PowerShell escaping uses backticks, not backslashes)
	julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate(); include(\"docs/make.jl\")'
	```

- In CI, the workflow removes any pinned `docs/Manifest.toml` and instantiates against current compat bounds.

