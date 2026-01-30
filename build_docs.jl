using Pkg
push!(LOAD_PATH, dirname(dirname(@__FILE__)))

# Instantiate the main project to ensure PormG's dependencies are available
root_dir = dirname(dirname(@__FILE__))
main_env = joinpath(root_dir)
cd(main_env)
Pkg.instantiate()
cd(dirname(@__FILE__))

# Instantiate docs environment
Pkg.instantiate()

# Build the documentation
include(joinpath(dirname(@__FILE__), "docs", "make.jl"))
