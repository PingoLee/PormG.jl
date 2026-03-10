module PormGReviseExt

using PormG
import Revise

function __init__()
    # Use @eval to override the fallback functions in PormG.Utils
    # with versions that use the Revise package directly.
    @eval PormG.Utils begin
        function _includet(mod, path)
            try
                return Revise.includet(mod, path)
            catch
                return Base.include(mod, path)
            end
        end

        function _add_revise_callback(path, mod_obj, dir)
            try
                Revise.add_callback() do
                    try
                        Base.invokelatest(PormG.Utils.reload_module_contents!, mod_obj, path)
                        Base.invokelatest(PormG.Models.set_models, mod_obj, dir)
                    catch e
                        # Don't spam warnings on every Revise cycle unless it's real
                    end
                end
            catch
            end
        end
    end
end

end # module
