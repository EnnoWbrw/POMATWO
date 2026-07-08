# POMATWO.jl — Repo Notes

## Project
- Julia electricity market model (WIP, TU Berlin), v0.4.2
- Branch: `merged_main__zonal_ptdf`
- License: MIT

## Purpose
Multi-step electricity market optimizer:
1. Day-ahead zonal/nodal market clearing (merit-order, minimize system cost)
2. DCOPF redispatch for congestion management
3. FBMC (Flow-Based Market Coupling) support

## Key Source Files
- `src/POMATWO.jl` — module entry, includes, exports
- `src/technologies.jl` — currently open in editor
- `src/solving.jl` — `run`, `_run`, `_run_states`, `record_carry!`
- `src/model_structs.jl` — `ModelSetup`, `ModelRun`, `TimeHorizon`, etc.
- `src/data_load.jl` — `load_data`, `DataFiles`
- `src/market_definitions.jl` — `MarketType`, `ZonalMarket`, `NodalMarket`, etc.
- `src/energy_balances.jl`
- `src/prosumer.jl`
- `src/read_output.jl`
- `src/utils/` — GSK_strategies, fbmc_utils, data_load_utils, df_utils, time_utils, get_vals_utils, model_utils

## Key Types / Exports
MarketType, ZonalMarket, NodalMarket, ProsumerSetup, NoProsumer, ProsumerOptimization,
RedispatchSetup, NoRedispatch, DCLF, StorageBoundary, CarryOverStorage, CyclicStorage,
PhaseAngle, ExchangeFormulation, NTC, FlowBased, DataReport, DataFiles, TimeHorizon

## Dependencies
JuMP, Plasmo, DataFrames, DataFramesMeta, CSV, Arrow, JLD2, TimerOutputs, ProgressMeter,
MathOptInterface, LinearAlgebra, Statistics, Dates, CategoricalArrays, Random, UnPack

## Compatibility Fix
`JuMP.variable_ref_type(::Type{Plasmo.OptiNode}) = JuMP.VariableRef` (Plasmo 0.5.4 + JuMP 1.27+)

## Test Cases
`test/test_cases/`: cases.jl, test_model_config, test_storage_boundary, test_zonal_ptdf,
test_ptdf_omission, test_network_validation, test_data_load, test_read_output, test_utils

## Example Data
`examples/`: 3-node, 3-node FBMC, 3-node prosumer, 15-node CS_15_01
`examples/test_data_3_nodes_v2/`, `test_data_3_nodes_v2_fbmc/`, `test_data_4_nodes_fbmc/`, `test_data_7_nodes_fbmc/`

## Known ToDos (from ToDos.md)
- Replace UnPack (unmaintained)
- Add lookahead/overlap horizon for CarryOverStorage (detailed design in ToDos.md)
- Add PTDF model formulation, FBMC, seasonal storages, prosumer intraday balance
- Add slack zone for grid calc stability
- Expand tests, fix various data/plot issues

## Build Docs
```powershell
julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()"
julia --project=docs docs/make.jl
```
