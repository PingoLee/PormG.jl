module Utils

import PormG.Models

"""
    reload_module_contents!(existing_mod::Module, filepath::String)

Re-evaluate the body of a module-defining file into an existing module object.

Revise.jl can only hot-reload *function* definitions — it cannot re-evaluate
global assignments or module-level expressions (which is how PormG models are
defined: `Driver = Models.Model(...)`).

This helper parses the file, extracts the `module … end` body, and evaluates
every expression inside the *original* module object so that existing references
(e.g. `import .models as M`) remain valid.
"""
function reload_module_contents!(existing_mod::Module, filepath::String)
    content = read(filepath, String)
    top = Meta.parseall(content)
    for expr in top.args
        # Look for `module SomeName ... end`
        if expr isa Expr && expr.head === :module
            body_block = expr.args[3]           # the body block Expr
            for sub in body_block.args
                # Skip bare LineNumberNodes
                sub isa LineNumberNode && continue
                try
                    Base.invokelatest(Core.eval, existing_mod, sub)
                catch e
                    # import / using of already-loaded packages may error; ignore
                end
            end
            return true
        end
    end
    return false
end

"""
    @import_models(path, alias)

Includes a model file and automatically registers the defined module with PormG.

The file at `path` must define its own `module` (e.g., `module my_models ... end`).
The `alias` must match the module name defined in the file.

The macro automatically:
- Resolves the path relative to the calling file
- Registers models for the current session
- Injects an `__init__()` function for post-precompilation re-registration
- Handles World Age issues in Julia 1.12+

Users do NOT need to manually add an `__init__()` function to their model files.

# Example
```julia
# In your package's main module:
PormG.@import_models "db/models.jl" models
import .models as M

# Now use M.Driver, M.Result, etc.
# Models are automatically available here and after precompilation
```
"""
macro import_models(path_expr, alias)
    source_file = string(__source__.file)
    if !(path_expr isa String)
        error("@import_models requires a string literal path, got: $(typeof(path_expr))")
    end
    # Resolve absolute path at macro expansion time (path_expr is a string literal)
    abs_path = isabspath(path_expr) ? path_expr : joinpath(dirname(source_file), path_expr) |> normpath
    dir_path = dirname(abs_path)

    # Capture references at macro expansion time to avoid hygiene issues
    calling_module = __module__
    set_models_fn = Models.set_models
    reload_module_contents! = Utils.reload_module_contents!
    alias_sym = alias isa Expr ? alias.args[1] : alias

    return Expr(:toplevel,
        # 1. Include the file — the file itself defines `module alias ... end`
        #    which becomes a submodule of the calling module.
        :(if isdefined(Main, :Revise)
            try
                Main.Revise.includet($calling_module, $abs_path)
            catch
                Base.include($calling_module, $abs_path)
            end
        else
            Base.include($calling_module, $abs_path)
        end),
        # 2. Inject __init__() if not already present
        :(let mod = $(esc(alias))
            if !isdefined(mod, :__init__)
                try
                    Core.eval(mod, quote
                        function __init__()
                            try
                                # Use fully qualified name to avoid dependency on macro scope
                                Base.invokelatest(PormG.Models.set_models, @__MODULE__, @__DIR__)
                            catch
                            end
                        end
                    end)
                catch e
                    @warn "PormG: Failed to inject __init__() for module $(string($(QuoteNode(alias))))" exception=e
                end
            end
        end),
        :(if isdefined(Main, :Revise)
            try
                # Register a callback triggered when Revise detects changes in this file.
                # Revise cannot re-evaluate module definitions or global assignments,
                # so we do it ourselves via reload_module_contents!.
                let _abs = $abs_path, _dir = $dir_path,
                    _set = $set_models_fn, _reload = $reload_module_contents!
                    Main.Revise.add_callback([_abs]) do
                        try
                            existing = $(esc(alias))
                            Base.invokelatest(_reload, existing, _abs)
                            Base.invokelatest(_set, existing, _dir)
                        catch e
                            @warn "PormG: hot-reload failed" exception=e
                        end
                    end
                end
            catch
            end
        end),
        # 3. Register the module with PormG (invokelatest for World Age safety)
        :(Base.invokelatest($set_models_fn, $(esc(alias)), $dir_path))
    )
end

"""
    @models_module(name, path, block)

Defines a new module with inline model definitions and registers it with PormG.

Use this when you want to define models directly in code rather than in a separate file.

# Example
```julia
@models_module MyDB "db" begin
    Driver = Models.Model("drivers",
        id = Models.IDField(),
        name = Models.CharField()
    )
end
```
"""
macro models_module(name, path, block)
    source_file = string(__source__.file)
    return Expr(:toplevel,
        :(module $(esc(name))
            using PormG
            import PormG.Models

            const __pormg_init_path__ = let
                p = $(esc(path))
                isabspath(p) ? p : joinpath(dirname($source_file), p) |> normpath
            end

            $(esc(block))

            Base.invokelatest(Models.set_models, @__MODULE__, __pormg_init_path__)

            function __init__()
                try
                    Base.invokelatest(Models.set_models, @__MODULE__, __pormg_init_path__)
                catch
                end
            end
        end)
    )
end

export @import_models, @models_module

end

