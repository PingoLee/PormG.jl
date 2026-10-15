"""
Unit coverage for the multi-connection self-heal inference guard
(`Models._infer_self_heal_key`).

When a model loses its `connect_key` (e.g. after precompilation), `ensure_model_initialized`
may infer the key from `config`. The dangerous case is a **multi-connection** app: an earlier
version scanned `config` and bound to the *first* entry, silently routing a model's queries to
the wrong database. The fix refuses to guess unless the choice is unambiguous.

`_infer_self_heal_key(model, models_in_mod, config)` is the pure decision extracted from that
branch — no globals, no `set_models` side effects — so the invariant is pinned deterministically
here: it returns a key only when there is exactly ONE connection and the model belongs to the
module; otherwise `nothing`.
"""

using Test
using PormG
import PormG: Configuration
using PormG.Models: Model, IDField

@testset "Self-heal key inference (_infer_self_heal_key)" begin
  m     = Model("heal_tbl",  id = IDField())
  other = Model("other_tbl", id = IDField())
  s1 = Configuration.Settings(db_def_folder = "db")
  s2 = Configuration.Settings(db_def_folder = "db2")

  # Single connection + model present in the module → infer that one key.
  @test PormG.Models._infer_self_heal_key(m, [m], Dict("db" => s1)) == "db"

  # TWO connections → refuse to guess (the exact regression: never silently pick one).
  @test PormG.Models._infer_self_heal_key(m, [m], Dict("db" => s1, "db2" => s2)) === nothing

  # Single connection but the model is NOT defined in this module → nothing.
  @test PormG.Models._infer_self_heal_key(other, [m], Dict("db" => s1)) === nothing

  # No connections configured → nothing (length != 1).
  @test PormG.Models._infer_self_heal_key(m, [m], Dict{String,PormG.PormGSettings}()) === nothing

  # A lone `register_connection` entry → nothing (#683). The caller re-registers through the
  # entry's `db_def_folder`, which for a dynamic entry is only the label "dynamic_connection";
  # following it would load `./dynamic_connection/connection.yml` from the working directory.
  dyn = Configuration.Settings(db_def_folder = "dynamic_connection", dynamic = true)
  @test PormG.Models._infer_self_heal_key(m, [m], Dict("tenant7" => dyn)) === nothing
  # The flag decides, not the label: a static folder of that name is still inferred (#623).
  static = Configuration.Settings(db_def_folder = "dynamic_connection")
  @test PormG.Models._infer_self_heal_key(m, [m], Dict("dynamic_connection" => static)) == "dynamic_connection"
end

# ─────────────────────────────────────────────────────────────────────────────
# A never-registered model does not repeat the self-heal scan on every .objects (#1250)
# What it tests: a model built with a bare `Model(...)` (no `_module`, no `connect_key`) is not
#   found by `ensure_model_initialized`, and the "not found" is recorded against the signature of
#   what the scan reads (`_unbound_scan_signature`). The next call does not scan: a registered module
#   that DOES hold the model, swapped in for a placeholder without changing `REGISTERED_MODULES`'s
#   size, is not found — the scan would have bound the model to it. Registering one more module
#   changes the signature, so the call after that scans and binds. `.objects.db(key)` works on the
#   cached model, and a model WITH a `_module` or a `connect_key` is never cached. No SQL: an
#   offline key.
# Why it matters: `.objects` calls `ensure_model_initialized` on every access, before `.db(key)` is
#   seen, so a library's infrastructure model routed only through `.db(key)` paid a scan of every
#   registered and marked module on every query (about a millisecond a query with fifty models in
#   one marked module) for an answer that cannot change while nothing it reads changes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a never-registered model is not re-scanned on every .objects (#1250)" begin
  Models = PormG.Models
  key = "heal1250_db"
  registered = copy(Models.REGISTERED_MODULES)
  try
    Configuration.register_offline(key)
    bare = Model("heal1250_tbl", id = IDField())
    placeholder = Module(:Heal1250Placeholder)
    Models.REGISTERED_MODULES[placeholder] = key

    @test Models.ensure_model_initialized(bare) === false
    @test get(Models._UNBOUND_SCAN, bare, nothing) == Models._unbound_scan_signature()

    # Swap the placeholder for a module that holds `bare`: same size, so the scan is skipped. Both
    # calls below go through `invokelatest`: the `Core.eval` binding is invisible to this running
    # closure's world (Julia 1.12), so a direct call would not find `holder` even if it scanned,
    # and the "skipped" assertion would pass for the wrong reason.
    holder = Module(:Heal1250Holder)
    Core.eval(holder, :(Heal1250_tbl = $bare))
    delete!(Models.REGISTERED_MODULES, placeholder)
    Models.REGISTERED_MODULES[holder] = key
    @test Base.invokelatest(Models.ensure_model_initialized, bare) === false
    @test Models.connection_key(bare) === nothing

    # One more registered module changes the signature: the scan runs and finds `holder`.
    Models.REGISTERED_MODULES[placeholder] = key
    @test Base.invokelatest(Models.ensure_model_initialized, bare) === true
    @test Models.connection_key(bare) == key

    # Through `.objects`, routed by `.db(key)`: the first access records the miss, and the query is
    # routed by `.db(key)` either way. (That the second access skips the scan is what the holder
    # swap above proves; an equal entry afterwards would also follow from a second scan.)
    routed = Model("heal1250_routed", id = IDField())
    @test occursin("heal1250_routed", PormG.inspect_query(routed.objects.db(key))[:sql_text])
    recorded = get(Models._UNBOUND_SCAN, routed, nothing)
    @test recorded == Models._unbound_scan_signature()
    @test occursin("heal1250_routed", PormG.inspect_query(routed.objects.db(key))[:sql_text])
    @test get(Models._UNBOUND_SCAN, routed, nothing) === recorded

    # A model with a module goes through #1226/#1227's paths, and one with a key through case 1,
    # which reads `config`: neither is cached.
    owned = Model("heal1250_owned", id = IDField())
    owned._module = Module(:Heal1250Owner)
    Models.ensure_model_initialized(owned)
    @test !haskey(Models._UNBOUND_SCAN, owned)
    keyed = Model("heal1250_keyed", id = IDField())
    keyed.connect_key = "heal1250_unloaded"
    @test Models.ensure_model_initialized(keyed) === false
    @test !haskey(Models._UNBOUND_SCAN, keyed)
  finally
    empty!(Models.REGISTERED_MODULES)
    merge!(Models.REGISTERED_MODULES, registered)
    Configuration.unregister_connection(key)
  end
end
