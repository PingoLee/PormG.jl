module Utils

import ..Models
import ..get_settings

"""
    reload_module_contents!(existing_mod::Module, filepath::String) -> Bool

Re-evaluate the body of a module-defining file into an existing module object.

This is the body of the Revise reload for a models file (#1487). Revise alone does not reload a
model. In a file loaded with `includet` it re-evaluates only method definitions, and where it does
re-evaluate an assignment (a package's own files), the new `Model` is unbound until `set_models`
runs again.

This helper parses the file, finds the `module` named like `existing_mod`, and evaluates every
expression of its body inside the *original* module object, so that existing references
(e.g. `import .models as M`) remain valid.

JIT-only (#1608): its one caller is the Revise callback `PormGReviseExt` registers, and a running
application never reaches it — `set_models`, `ensure_model_initialized` and the query path neither
parse nor evaluate code. A trimmed binary cannot load new code by definition, so it has no reload. It returns `false`, and evaluates nothing, when the file
does not parse or defines no such module. An expression that fails to evaluate (a typo in a field)
is logged with its line and leaves that binding at its previous value.
"""
function reload_module_contents!(existing_mod::Module, filepath::String)::Bool
    content = read(filepath, String)
    top = Meta.parseall(content)
    # A parse error anywhere is an `:error` node at the top level and no `module` at all.
    any(e -> e isa Expr && e.head in (:error, :incomplete), top.args) && return false
    for expr in top.args
        # The module the file defines for `existing_mod`, by name: evaluating another module's body
        # into it (a wrong `source =`) would overwrite its bindings with unrelated ones.
        if expr isa Expr && expr.head === :module && expr.args[2] === nameof(existing_mod)
            # #1602: the same model-set declaration `@import_models` adds, so a model added by the
            # edit is in the set the `set_models` after the reload reads.
            body_block = Models._with_model_set(expr).args[3]
            line = 0
            for sub in body_block.args
                if sub isa LineNumberNode
                    line = sub.line
                    continue
                end
                try
                    Base.invokelatest(Core.eval, existing_mod, sub)
                catch e
                    # import / using of already-loaded packages may error; ignore those. Anything
                    # else is the edit itself failing (a typo in a field), which leaves that binding
                    # at its previous value, so say so rather than reload half a file in silence (#1487).
                    sub isa Expr && sub.head in (:import, :using) && continue
                    @warn "PormG: an expression in the reloaded models file failed; its binding keeps the previous value" file = filepath line = line exception = e
                end
            end
            return true
        end
    end
    return false
end

# `PormGReviseExt` installs the reload hook from its `__init__`. The hook lives in `Models` (#1487),
# because `set_models(…; source)` calls it and `Models` is included before this file.
#
# #1608: there was a second hook, `includet`, through which `@import_models` included the models file
# with `Revise.includet` in a session (and a duck-typed `Main.Revise` fallback). #1602 made the macro
# include with `Base.include(Models._with_model_set, …)` — `includet` cannot apply a `mapexpr` — so
# the hook had no caller left and is deleted: PormG's own `source =` reload is the one reload path.
function set_revise_hooks!(; add_revise_callback=nothing)
    Models._add_revise_callback_hook[] =
        add_revise_callback === nothing ? Models._noop_add_revise_callback : add_revise_callback
    return nothing
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
        # swallows pkgdir's failure: a module outside a package has no package root to search.
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

"""
    _do_import_models(calling_module, source_file, import_path, alias)

Runtime workhorse for the post-include phase of `@import_models`.
Resolves the file path, injects `__init__`, and calls `Models.set_models`
with `source`, which registers the Revise reload.

The actual `include` is issued as a separate top-level statement by the
macro so that the submodule binding lands in the correct world age.
"""
function _post_import_setup(calling_module::Module, source_file::String,
                            import_path::String, alias::Symbol)
    resolved_path = resolve_import_models_path(source_file, import_path, calling_module)
    # Obtain the freshly-created submodule
    mod = getfield(calling_module, alias)
    _setup_imported_models!(mod, resolved_path)
    return nothing
end

# What `@import_models` and `import_models` do once the models module exists: the Revise callback and
# the registration (#1232 shares it between the macro and the function).
#
# #1607: no `__init__` is injected into the models module any more. `ensure_models_init!` used to
# `Core.eval` one in after the module had closed; #552 measured that it never ran in a restored image,
# and a trimmed binary cannot `Core.eval` at all. A restored image rebinds on the first `.objects`
# from the record registration keeps in the module's own `ModelSet` (`ensure_model_initialized`).
function _setup_imported_models!(mod::Module, resolved_path::String)::Nothing
    dir_path = dirname(resolved_path)

    # Register models with PormG, and the Revise reload for their file (#1487: `set_models` skips the
    # reload while precompiling, and registers it once the key is decided, so a `ModelDefinitionError`
    # still leaves the file watched)
    Models.set_models(mod, dir_path; source = resolved_path)

    return nothing
end

"""
    @import_models(path, alias)

Includes a model file and automatically registers the defined module with PormG.

The file at `path` must define its own `module` (e.g., `module my_models ... end`).
The `alias` must match the module name defined in the file.

The macro automatically:
- Resolves the path relative to the calling file
- Declares the model set (`Models.@models …`, #1602) from the file's top-level
  `X = Models.Model(…)` assignments (documented, typed, `const` or `global`), when the file does
  not end with its own `Models.@models` line. A file that builds a model any other way (in a loop,
  a function, an `@eval`) and writes no line is refused with `ModelDefinitionError`, since the
  generated line would leave that model out; a model reached through `using` is registered only
  when the file declares it
- Registers models for the current session, recording the key in the module's model set, from
  which a restored package image rebinds on the first query (`Models.ensure_model_initialized`)
- Handles World Age issues in Julia 1.12+: the registration is its own top-level statement

Users do NOT need to add an `__init__()` function to their model files, and none is added for them
(#1607).

With Revise loaded, it also registers a reload of the file (`Models.set_models(…; source)`, #1487).
It is the REPL / script form: in a package's module body it runs at precompile time, where no
reload is registered, so a package binds its models from `__init__` with `Models.set_models`.

# Example
```julia
PormG.Configuration.load("db"; env = "dev")   # the configuration first
PormG.@import_models "db/models.jl" models
import .models as M

# Now use M.Driver, M.Result, etc.
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
    with_set_ref = GlobalRef(Models, :_with_model_set)
    setup_ref    = GlobalRef(Utils, :_post_import_setup)

    sf = QuoteNode(source_file)
    ip = QuoteNode(path_expr)
    as = QuoteNode(alias_sym)

    return Expr(:toplevel,
        # Statement 1 — resolve the path and include the file, appending the model-set declaration
        # (`Models.@models …`, #1602) to its module when the file does not write one. Its own
        # top-level statement, so the submodule binding is established in the current world age
        # before the next statement (and before any subsequent `import .alias` in the caller).
        :(Base.include($with_set_ref, $calling_module, $resolve_ref($sf, $ip, $calling_module))),

        # Statement 2 — register the Revise callback and the models (set_models).
        # Runs as a separate top-level statement so it can see the binding.
        :($setup_ref($calling_module, $sf, $ip, $as))
    )
end

"""
    @models_module(name, path, block)

Defines a new module with inline model definitions and registers it with PormG.

Use this when you want to define models directly in code rather than in a separate file. The
model set (`Models.@models`, #1602) is declared for you from the block's top-level
`X = Models.Model(…)` assignments, unless the block declares its own. A block that builds a model
any other way (in a loop, a function) and declares none is refused with `ModelDefinitionError`:
write its `Models.@models` line.

# Example
```julia
@models_module MyDB "db" begin
    Driver::Models.ModelType = Models.Model("drivers",
        id = Models.IDField(),
        name = Models.CharField()
    )
end
```
"""
macro models_module(name, path, block)
    source_file = string(__source__.file)
    body = block isa Expr && block.head === :block ? block : Expr(:block, block)
    declaration = Models._declares_model_set(body) ? nothing :
        Models._model_set_declaration(Models._generated_model_bindings(name, body), __source__)
    return Expr(:toplevel,
        :(module $(esc(name))
            using PormG
            import PormG.Models

            $(esc(block))

            $(declaration === nothing ? nothing : esc(declaration))

            # #1607: the folder goes into the module's own `ModelSet`, from its body, so the
            # `__init__` below can read it even if the registration under it has not happened yet.
            Models._record_folder!(@__MODULE__, let
                p = $(esc(path))
                isabspath(p) ? p : joinpath(dirname($source_file), p) |> normpath
            end)

            # Direct calls (#1607): this body runs at top level, in the newest world, so the models
            # above are visible to `set_models` without `invokelatest`.
            Models.set_models(@__MODULE__, Models._model_set(@__MODULE__).folder)

            # Runs when a package image is restored, before the parent's `__init__` has loaded
            # the configuration: bind only if it is already loaded (#1226). Written in the module
            # body, not evaluated into the closed module.
            function __init__()
                try
                    Models._bind_if_loaded(@__MODULE__)
                catch e
                    # swallows a refusal or a bug in the bind: an `__init__` that throws fails
                    # `using`; the first `.objects` binds or refuses (`ensure_model_initialized`).
                    @debug "PormG: @models_module __init__ did not bind" exception = e
                end
            end
        end)
    )
end

export @import_models, @models_module

end

