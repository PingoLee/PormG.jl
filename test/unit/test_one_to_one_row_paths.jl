"""
Unit coverage for the five `isa Models.sForeignKey` gates in `src/querybuilder/` that a
`OneToOneField` did not reach (#418).

`sOneToOneField` is NOT a subtype of `sForeignKey` — `PormGField` is the only abstract type above
either — so every `isa sForeignKey` gate silently skips a one-to-one and every `::sForeignKey`
assertion throws on one. The same single defect has now been found once per subsystem: #408 in the
DDL renderer and the planner guard, #409 in the schema readers, #418 here. All five sites are fixed
by the shared `Models.sRelationalColumn` alias.

The five all had FOREIGN-KEY coverage already — `test/integration/test_row_mutation.jl` for `save()`
and `setproperty!`, `test/integration/test_row_and_get.jl` and `test/integration/test_docs_error_types.jl`
for the lazy-access refusal. What none of them had was the ONE-TO-ONE path through the same gate,
which is the whole of #418 and the whole of this file.

The five, and what each did to a one-to-one before the fix:

  1. `_row_related_model(model, ::sForeignKey)`  — dispatch signature      → `MethodError`
  2. the `touched_fk_fields` guard in `save()`   — `isa` guard             → SILENT: the FK/`__`
     conflict check never ran, so PormG issued both UPDATEs and the projected one filtered on the
     STALE key value
  3. `model.fields[…]::sForeignKey` in `save()`  — type assertion          → raw `TypeError`
  4. the lazy-access refusal in `getproperty`    — `isa` guard             → `UnknownFieldError`
     ("has no field or accessor"), which is a lie: the field exists
  5. the `__` check in `setproperty!`            — `isa` guard             → refused a valid
     assignment with "'solo' is not a ForeignKey field"

Why unit and not integration: the F1 integration schema declares no `OneToOneField` at all, so an
integration regression would mean adding a model and a table to `test_migration_bootstrap.jl` —
a ~170-statement DDL bootstrap and the full-suite gate — for paths that are fully deterministic
without a database. #418's own acceptance asks for unit coverage.

DB-free: a bare `MockO2ORow` marker answers nothing, and every assertion runs through
`save(show_query = :dict)`, which returns the PLANNED statements instead of executing them (the
same dual contract `test_create_returns_pormgrow.jl` relies on). The relation targets are real
`PormGModel` objects rather than string names, so `_row_related_model` takes its
`fk_meta.to isa PormGModel` branch and no `set_models` — and therefore no world-age hazard — is
involved.

Every testset carries a plain-`ForeignKey` control, so a change that fixes the one-to-one by
breaking the foreign key fails here. Sites 1 and 5 additionally carry a `ManyToManyField` control:
the tempting "simplification" of `sRelationalColumn` is `hasfield(typeof(f), :to)`, which an M2M
also satisfies — and an M2M has no `pk_field`, no `on_delete` and no column on this table, so that
version would trade a `MethodError` for a crash one field access later.
"""

using Test
using DataFrames
using PormG
using PormG.Models: Model, CharField, IDField, ForeignKey, OneToOneField, ManyToManyField
import PormG.ConnectionPool: fetch
import PormG.QueryBuilder: PormGRow, save, _row_related_model

# The mock backend. `save(show_query = :dict)` never executes, so this only has to exist — the
# `:execute` path is deliberately not taken anywhere in this file, and an empty DataFrame is what a
# stray call would get.
struct MockO2ORow <: PormG.PormGPostgres end
fetch(connection::MockO2ORow, sql::String;
      conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

PormG.config["o2o_row_paths"] =
  PormG.Configuration.Settings(connections = MockO2ORow(), change_data = true)

# The relation target. Both relational fields on the owner point here, so the FK control and the
# one-to-one under test differ in EXACTLY one thing: the declared field type.
O2ORowTarget = Model("o2o_row_target", id = IDField(), forename = CharField())
O2ORowTarget.connect_key = "o2o_row_paths"

# The row-bearing model. Field names are deliberately unlike the model and table names ("solo",
# "many", "tags", "label") so an `occursin` on an error message cannot pass by accidentally matching
# a table name — the exact green-theater trap this repo has been bitten by before.
O2ORowOwner = Model("o2o_row_owner",
  id    = IDField(),
  label = CharField(),
  solo  = OneToOneField(O2ORowTarget, pk_field = "id"),   # the field under test
  many  = ForeignKey(O2ORowTarget, pk_field = "id"),      # the control
  tags  = ManyToManyField(O2ORowTarget))                  # the over-widening control
O2ORowOwner.connect_key = "o2o_row_paths"

_owner_row(data...) = PormGRow(Dict{Symbol, Any}(data...), O2ORowOwner)

# ─────────────────────────────────────────────────────────────────────────────
# Site 1: `_row_related_model`'s dispatch signature accepts a one-to-one (#418)
# The signature was `fk_meta::Models.sForeignKey`, so resolving the related model for a
# `OneToOneField` raised a MethodError naming an internal helper the caller never wrote. The
# `hasmethod` assertions are the literal claim #418 opened with (`hasmethod(..., Tuple{PormGModel,
# sOneToOneField})` was `false`), and the M2M one pins that the widening stopped where it should.
# ─────────────────────────────────────────────────────────────────────────────
@testset "_row_related_model dispatches on a OneToOneField (#418)" begin
  @test hasmethod(_row_related_model, Tuple{PormG.PormGModel, PormG.Models.sOneToOneField})
  @test hasmethod(_row_related_model, Tuple{PormG.PormGModel, PormG.Models.sForeignKey})

  # The over-widening guard. `sManyToManyField` HAS a `.to` field, so a `hasfield(typeof(f), :to)`
  # predicate would admit it here and then die on `fk_meta.pk_field`, which an M2M does not have.
  @test !hasmethod(_row_related_model, Tuple{PormG.PormGModel, PormG.Models.sManyToManyField})

  # And it resolves, not merely dispatches: `.to` already holds the PormGModel, so this is the
  # fast path both relational types share.
  @test _row_related_model(O2ORowOwner, O2ORowOwner.fields["solo"]) === O2ORowTarget
  @test _row_related_model(O2ORowOwner, O2ORowOwner.fields["many"]) === O2ORowTarget
end

# ─────────────────────────────────────────────────────────────────────────────
# Sites 1 + 3: save() plans the related UPDATE for a projected one-to-one column (#418)
# `fk_meta = model.fields[...]::Models.sForeignKey` threw a raw TypeError — not a PormG error type —
# out of save() before `_row_related_model` was ever reached. The assertion is on the rendered
# statement, not merely on "it did not throw": a fix that swallowed the projection and planned
# nothing would pass a throw-free test and silently drop the user's write.
# ─────────────────────────────────────────────────────────────────────────────
@testset "save() updates the related table through a OneToOneField (#418)" begin
  row = _owner_row(:id => 1, :label => "owner", :solo => 7)
  row.solo__forename = "Ayrton"

  plans = save(row; show_query = :dict)
  @test length(plans) == 1
  sql = plans[1][:sql_text]
  @test occursin("UPDATE", sql)
  @test occursin("o2o_row_target", sql)      # the RELATED table, reached via the one-to-one
  @test occursin("forename", sql)
  @test !occursin("o2o_row_owner", sql)      # nothing was written to the owner's own table

  # Control: the plain ForeignKey sibling plans the identical shape, so this testset fails if the
  # one-to-one were "fixed" by regressing the foreign key.
  fk_row = _owner_row(:id => 1, :label => "owner", :many => 9)
  fk_row.many__forename = "Alain"
  fk_plans = save(fk_row; show_query = :dict)
  @test length(fk_plans) == 1
  @test occursin("o2o_row_target", fk_plans[1][:sql_text])

  # A one-to-one whose target primary key was never resolved must raise the SAME typed guidance a
  # foreign key does — not a TypeError, and not a MethodError.
  unresolved = Model("o2o_row_unresolved",
    id = IDField(), solo = OneToOneField(O2ORowTarget))   # no pk_field
  unresolved.connect_key = "o2o_row_paths"
  bad = PormGRow(Dict{Symbol, Any}(:id => 1, :solo => 7), unresolved)
  bad.solo__forename = "x"
  err = try; save(bad; show_query = :dict); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError
  @test occursin("set_models()", err.msg)
end

# ─────────────────────────────────────────────────────────────────────────────
# Site 2: the FK/`__` conflict guard fires for a one-to-one (#418)
# This is the SILENT one, and the only site whose old behaviour was a wrong write rather than an
# error. Mutating both `solo` (the key itself) and `solo__forename` (a column on the related row)
# in one save() is refused, because the projected UPDATE filters on the key value already ON the
# row — i.e. the STALE one — so honouring both would write to the wrong related record.
#
# The assertion names the field and quotes the guidance, not just the type: `save()` throws
# QueryBuildError from four other places in the same function, so a bare
# `@test err isa QueryBuildError` would pass on any of them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "save() refuses a one-to-one key change alongside its projected columns (#418)" begin
  row = _owner_row(:id => 1, :label => "owner", :solo => 7)
  row.solo = 8                     # the key itself
  row.solo__forename = "Ayrton"    # a column on the related row, keyed by the OLD value

  err = try; save(row; show_query = :dict); nothing; catch e; e; end
  @test err isa PormG.QueryBuildError
  @test occursin("solo", err.msg)
  @test occursin("Save the FK change separately first", err.msg)

  # Control: identical shape through the plain ForeignKey.
  fk_row = _owner_row(:id => 1, :label => "owner", :many => 7)
  fk_row.many = 8
  fk_row.many__forename = "Alain"
  fk_err = try; save(fk_row; show_query = :dict); nothing; catch e; e; end
  @test fk_err isa PormG.QueryBuildError
  @test occursin("many", fk_err.msg)

  # No over-firing: touching the key alone, or the projection alone, is legal for both types.
  key_only = _owner_row(:id => 1, :solo => 7)
  key_only.solo = 8
  @test length(save(key_only; show_query = :dict)) == 1

  proj_only = _owner_row(:id => 1, :solo => 7)
  proj_only.solo__forename = "Ayrton"
  @test length(save(proj_only; show_query = :dict)) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Site 4: an unprojected one-to-one raises LazyTraversalError, not UnknownFieldError (#418)
# Falling through to `UnknownFieldError("... has no field or accessor 'solo'")` was a lie — the
# field is declared, it just was not projected — and it withheld the one message that names the fix.
# The message now names the DECLARED type, so a reader of "is a OneToOneField that this row didn't
# project" goes looking for the declaration that actually exists.
# ─────────────────────────────────────────────────────────────────────────────
@testset "unprojected OneToOneField raises LazyTraversalError (#418)" begin
  row = _owner_row(:id => 1, :label => "owner")

  err = try; row.solo; nothing; catch e; e; end
  @test err isa PormG.LazyTraversalError
  @test err isa PormG.FieldAccessError            # the family, as test_row_and_get.jl pins it
  @test !(err isa PormG.UnknownFieldError)        # the sibling type it used to fall through to
  @test occursin("is a OneToOneField", err.msg)   # names the declared type, not a hardcoded "ForeignKey"
  @test occursin("values(", err.msg)              # steers to up-front projection
  @test occursin("__", err.msg)                   # …via the __ lookup
  @test !occursin(".on(", err.msg)                # never re-suggests the on() dead end (#204)

  # Control: the foreign key still names ITS own type — the parameterization must not have
  # relabelled every relation as a one-to-one.
  fk_err = try; row.many; nothing; catch e; e; end
  @test fk_err isa PormG.LazyTraversalError
  @test occursin("is a ForeignKey", fk_err.msg)
  @test !occursin("is a OneToOneField", fk_err.msg)

  # A genuinely undeclared name must still be UnknownFieldError — the widening must not have
  # swallowed the honest case.
  @test (try; row.no_such_column; nothing; catch e; e; end) isa PormG.UnknownFieldError

  # A projected one-to-one returns its value and never reaches the refusal at all.
  @test _owner_row(:id => 1, :solo => 7).solo == 7
end

# ─────────────────────────────────────────────────────────────────────────────
# Site 5: `row.solo__forename = value` is accepted for a one-to-one (#418)
# The inverted failure: assignment was refused with "'solo' is not a ForeignKey field on
# o2o_row_owner" — true as written, and useless, because a one-to-one IS a foreign key carrying a
# UNIQUE constraint and the hop is perfectly valid.
# ─────────────────────────────────────────────────────────────────────────────
@testset "setproperty! accepts a projected OneToOneField column (#418)" begin
  row = _owner_row(:id => 1, :solo => 7)
  row.solo__forename = "Ayrton"
  @test :solo__forename in getfield(row, :_dirty)
  @test getfield(row, :_data)[:solo__forename] == "Ayrton"

  # Control: the foreign key behaves identically.
  row.many__forename = "Alain"
  @test :many__forename in getfield(row, :_dirty)

  # Over-widening guard. `sManyToManyField` has a `.to`, so `hasfield(typeof(f), :to)` would ACCEPT
  # this assignment — and an M2M owns no column on this table, so the write would have nowhere to
  # go. It stays refused, and the message names both types it does accept.
  m2m_err = try; row.tags__forename = "z"; nothing; catch e; e; end
  @test m2m_err isa PormG.QueryBuildError
  @test occursin("not a ForeignKey or OneToOneField", m2m_err.msg)
  @test occursin("tags", m2m_err.msg)

  # A non-relational scalar is still refused, for the same reason and with the same message.
  scalar_err = try; row.label__forename = "z"; nothing; catch e; e; end
  @test scalar_err isa PormG.QueryBuildError
  @test occursin("label", scalar_err.msg)

  # An undeclared prefix is refused too — the gate is "declares a relational column", not
  # "contains a __".
  @test (try; row.nope__forename = "z"; nothing; catch e; e; end) isa PormG.QueryBuildError
end
