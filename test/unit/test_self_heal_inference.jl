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
end
