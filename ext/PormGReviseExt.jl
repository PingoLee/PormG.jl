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

function _revise_add_revise_callback(path, mod_obj, dir)
    try
        Revise.add_callback() do
            try
                Base.invokelatest(PormG.Utils.reload_module_contents!, mod_obj, path)
                # A reload is not a direct registration: it never loads a folder, even in a REPL (#1248).
                Base.invokelatest(PormG.Models.set_models, mod_obj, dir; implicit = false)
            catch
            end
        end
    catch
    end
end

function __init__()
    PormG.Utils.set_revise_hooks!(;
        includet=_revise_includet,
        add_revise_callback=_revise_add_revise_callback,
    )
end

end # module
