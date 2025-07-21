# Defining the Setup
### Model Setup
```@docs
ModelSetup
```
```@docs
TimeHorizon
```
### Model Run
```@docs
ModelRun
```
### Calling the optimizer
```@docs
POMATWO.run(mr::ModelRun)
``` 
#### Optimizer Attributes
Optimizer attributes can be set by using the [`JuMP.optimizer_with_attributes`](https://jump.dev/JuMP.jl/stable/api/JuMP/#JuMP.optimizer_with_attributes) function from the `JuMP.jl`package. This function is **re-exported** from [JuMP.jl](https://jump.dev/JuMP.jl/stable/)
!!! note
    You can use `optimizer_with_attributes` directly after importing this package, as it is re-exported for your convenience.

Additionally [`MathOptInterface`](https://jump.dev/MathOptInterface.jl/stable/) is imported as `MOI`
