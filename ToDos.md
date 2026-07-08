# To Do's

## Updating Existing code
- Replace UnPack to ensure no issues in the feature becasue package is not maintained
- Check if Slack variables in model equations are necessary or redundant and should be removed
- expand test_dataload
- check if .arrow files can be used for crewating plots directly without using "DataFiles"
- check DE dataset if line coordinates match node coordinates
- replace fixed efficiency values for prosumer storages with eta
- replace fixed "netzentgelte" values for prosumer optimization with more accurate depiction
- check id availability = 1 from plant file is overwritten is availibility is given otherwise as well
- add prosumer demand to plots
- update redispatch energy balance to account for fixed exchange

## New Features
- add slack zone functionality to ensure code stability for grid alculations
- add "intraday" balance that includes prosumer behavior (PRS_NETINPUT must be taken into consideration)!!!
- add plot for nodal markets
- add ptdf model formulation
- add FBMC
- add seasonal storages
- add dynamic selling price for prosumers
- add plot for prosumer behaviour
- add (optional) prosumer demand response
- add dispatchable power plant ramping behavior (linear percentage of generation in previous period)

## Design notes: lookahead/overlap horizon for storage (not yet implemented)

Goal: mitigate end-of-split dumping under `CarryOverStorage` without inventing a terminal
water value. Each split is solved on an extended window (`split + lookahead` hours) but only
the first `split` hours are kept; the storage sees part of the future and stops dumping at
the split edge.

Design sketch (fits the current state pipeline):

- `TimeHorizon` gets a new field `lookahead::Int = 0` (hours).
- `split(th)` (utils/time_utils.jl) yields pairs `(T_keep, T_solve)` where
  `T_solve = first(T_keep):min(last(T_keep) + th.lookahead, th.stop)`. Last split has no
  (or a clamped) lookahead — dumping can still occur there; document it.
- `_run`/`_run_states` (solving.jl): build and solve every state of the sequence on
  `T_solve`; all stages of one split (DA, prosumer, redispatch, FBMC basecase) must use the
  same window so `prev_results_for_redispatch`/`calc_fbmc_params` indexing stays consistent.
- Result truncation: do it centrally, not per builder — in `write_results`, filter every
  result DataFrame with a `Time` column to `Time ∈ T_keep` before writing. Subrun directory
  naming should use `T_keep`.
- `record_carry!` (solving.jl): carried storage level must be read at `T_keep[end]`, NOT
  `T_solve[end]` — the lookahead hours are discarded, carrying their level would
  double-count.
- Prices/duals for the keep window are taken at the keep hours of the extended solve.
- Validation: warn/error when `lookahead > 0` is combined with `CyclicStorage`
  (meaningless) and when demand/availability profiles do not cover `stop` (profiles only
  need to reach `stop`; the clamp handles the tail).
- Cost: solve time scales with `(split + lookahead) / split` per split (e.g. 24+12 → +50%).
- Test idea: extend `test/test_cases/test_storage_boundary.jl` — scenario where cheap wind
  arrives just after a split boundary; without lookahead the storage discharges fully before
  the boundary, with lookahead it holds level. Assert result files contain only `T_keep`
  hours and that the split-1 end level differs between `lookahead = 0` and `> 0`.
- Orthogonal to `StorageBoundary`: lookahead is a `TimeHorizon`/pipeline feature; the
  boundary types (`CarryOverStorage`/`CyclicStorage`) stay unchanged. A
  `TerminalValueStorage(value_per_mwh)` subtype (one `initial_level` method + one objective
  term in `add_storage`) remains the cheap alternative when a defensible value source
  exists.
