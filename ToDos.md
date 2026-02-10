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
