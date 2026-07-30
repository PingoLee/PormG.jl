module Utils

import ..Models
import ..get_settings

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

# Revise hooks (optionally overridden by PormGReviseExt if Revise is loaded)
function _default_includet(mod, path)
    if isdefined(Main, :Revise) && isdefined(Main.Revise, :includet)
        try return Main.Revise.includet(mod, path) catch end
    end
    Base.include(mod, path)
end

function _default_add_revise_callback(path, mod_obj, dir)
    if isdefined(Main, :Revise) && isdefined(Main.Revise, :add_callback)
        Main.Revise.add_callback() do
            try
                Base.invokelatest(reload_module_contents!, mod_obj, path)
                Base.invokelatest(PormG.Models.set_models, mod_obj, dir)
            catch
            end
        end
    end
end

const _includet_hook = Ref{Function}(_default_includet)
const _add_revise_callback_hook = Ref{Function}(_default_add_revise_callback)

function set_revise_hooks!(; includet=nothing, add_revise_callback=nothing)
    _includet_hook[] = includet === nothing ? _default_includet : includet
    _add_revise_callback_hook[] = add_revise_callback === nothing ? _default_add_revise_callback : add_revise_callback
    return nothing
end

function _includet(mod, path)
    return _includet_hook[](mod, path)
end

function _add_revise_callback(path, mod_obj, dir)
    return _add_revise_callback_hook[](path, mod_obj, dir)
end

function resolve_import_models_path(source_file::AbstractString, import_path::AbstractString, calling_module::Module)
    if isabspath(import_path)
        return normpath(import_path)
    end

    candidates = String[]

    if !isempty(source_file) && source_file != "none"
        if isabspath(source_file)
            push!(candidates, normpath(joinpath(dirname(source_file), import_path)))
        else
            push!(candidates, normpath(abspath(dirname(source_file), import_path)))
        end
    end

    pkg_dir = try
        Base.pkgdir(calling_module)
    catch
        nothing
    end

    if pkg_dir !== nothing
        push!(candidates, normpath(joinpath(pkg_dir, import_path)))
        push!(candidates, normpath(joinpath(pkg_dir, "src", import_path)))
    end

    seen = Set{String}()
    for candidate in candidates
        candidate in seen && continue
        push!(seen, candidate)
        if isfile(candidate)
            return candidate
        end
    end

    return isempty(candidates) ? normpath(import_path) : first(candidates)
end

function ensure_models_init!(mod::Module, dir_path::AbstractString)
    if isdefined(mod, :__init__)
        return nothing
    end

    init_expr = quote
        function __init__()
            try
                Base.invokelatest(PormG.Models.set_models, @__MODULE__, $dir_path)
            catch
            end
        end
    end

    Core.eval(mod, init_expr)
    return nothing
end

"""
    _do_import_models(calling_module, source_file, import_path, alias)

Runtime workhorse for the post-include phase of `@import_models`.
Resolves the file path, injects `__init__`, registers a Revise callback,
and calls `Models.set_models`.

The actual `include` is issued as a separate top-level statement by the
macro so that the submodule binding lands in the correct world age.
"""
function _post_import_setup(calling_module::Module, source_file::String,
                            import_path::String, alias::Symbol)
    resolved_path = resolve_import_models_path(source_file, import_path, calling_module)
    dir_path = dirname(resolved_path)
    is_precompiling = ccall(:jl_generating_output, Cint, ()) != 0

    # Obtain the freshly-created submodule
    mod = getfield(calling_module, alias)

    # Inject __init__() so model registration survives precompilation
    try
        ensure_models_init!(mod, dir_path)
    catch e
        @warn "PormG: Failed to inject __init__() for module $(string(alias))" exception=e
    end

    # Register a Revise hot-reload callback (skip during precompilation)
    if !is_precompiling
        _add_revise_callback(resolved_path, mod, dir_path)
    end

    # Register models with PormG
    Models.set_models(mod, dir_path)

    return nothing
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
        # ArgumentError, deliberately outside the taxonomy: a non-literal macro argument is
        # Julia-level API misuse (same class as tools.jl's two keeps), not a PormG domain error.
        # Pinned in test_docs_error_type_drift.jl's allowlist.
        throw(ArgumentError("@import_models requires a string literal path, got: $(typeof(path_expr))"))
    end

    calling_module = __module__
    alias_sym = alias isa Expr ? alias.args[1] : alias

    resolve_ref  = GlobalRef(Utils, :resolve_import_models_path)
    includet_ref = GlobalRef(Utils, :_includet)
    setup_ref    = GlobalRef(Utils, :_post_import_setup)

    sf = QuoteNode(source_file)
    ip = QuoteNode(path_expr)
    as = QuoteNode(alias_sym)

    return Expr(:toplevel,
        # Statement 1 — resolve path + include.
        # Executed as its own top-level statement so the submodule binding
        # is established in the current world age before the next statement
        # (and before any subsequent `import .alias` in the caller).
        # During precompilation we skip Revise to avoid file-watcher hangs.
        :(if ccall(:jl_generating_output, Cint, ()) != 0
            Base.include($calling_module, $resolve_ref($sf, $ip, $calling_module))
        else
            let __path = $resolve_ref($sf, $ip, $calling_module)
                $includet_ref($calling_module, __path)
                if !isdefined($calling_module, $as)
                    Base.include($calling_module, __path)
                end
            end
        end),

        # Statement 2 — inject __init__, register Revise callback, set_models.
        # Runs as a separate top-level statement so it can see the binding.
        :($setup_ref($calling_module, $sf, $ip, $as))
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

