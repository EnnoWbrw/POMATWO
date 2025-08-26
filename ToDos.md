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
- remove creation of nodal_load_no_prosumers

## New Features
- add slack zone functionality to ensure code stability for grid alculations
- add "intraday" balance that includes prosumer behavior (PRS_NETINPUT must be taken into consideration)!!!
- add plot for nodal markets
- add ptdf model formulation
- add test cases
- add FBMC
- add seasonal storages
- add dynamic selling price for prosumers
- maybe export the make_datafiles function from test data load to make it accessable to the user
- add plot for prosumer behaviour
- add (optional) prosumer demand response
