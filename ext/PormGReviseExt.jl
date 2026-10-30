module PormGReviseExt

using PormG
import Revise

function _revise_includet(mod, path)
    try
        return Revise.includet(mod, path)
    catch
        return Base.include(mod, path)
    end
end

# Reached through `Models.set_models(…; source = path)` (#1487). Revise alone does not reload a model:
# in an `includet` file it re-evaluates only methods, and where it re-evaluates an assignment (a
# package's own files) the new `Model` stays unbound. So the callback re-evaluates the module body into
# the same module and binds it again. Before #1487 this called `Revise.add_callback()` with no files:
# a `MethodError` (the files are required), swallowed by a bare `catch`, so no reload was ever
# registered. Every failure now warns, naming the file.
function _revise_add_revise_callback(path::String, mod_obj::Module, dir::String)
    if !isfile(path)
        @warn "PormG: no Revise reload for the models: the file is not there" file = path
        return nothing
    end
    try
        # Keyed by the file and the module's full name, so binding it again (an `__init__` that
        # re-runs, `@import_models` evaluated again in `Main`) replaces the callback, while the same
        # file bound into two modules (`import_models(…; into)`) keeps one for each.
        Revise.add_callback([path]; key = (:pormg_models, path, fullname(mod_obj))) do
            try
                if !Base.invokelatest(PormG.Utils.reload_module_contents!, mod_obj, path)
                    @warn "PormG: the edited models file was not reloaded: it does not parse, or it defines no module of this name" file = path module_name = nameof(mod_obj)
                    return nothing
                end
                # A reload is not a direct registration: it never loads a folder, even in a REPL (#1248).
                Base.invokelatest(PormG.Models.set_models, mod_obj, dir; implicit = false)
            catch e
                @warn "PormG: reloading the edited models file failed" file = path exception = e
            end
        end
    catch e
        @warn "PormG: could not register a Revise reload for the models file" file = path exception = e
    end
    return nothing
end

function __init__()
    PormG.Utils.set_revise_hooks!(;
        includet=_revise_includet,
        add_revise_callback=_revise_add_revise_callback,
    )
end

end # module
