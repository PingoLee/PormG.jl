"""
#388: an unresolved `ForeignKey.to` is never lowercased into a physical table name.

`.to` holds a Julia **binding**, not a table. Three call sites recovered the table by LOWERCASING it,
which is only the right inverse while the binding is exactly `uppercasefirst(<table>)`. #360/#386
made `.to` the model's real binding, which the lowercase cannot invert — so the guess started
fabricating names that no table answers to:

  | live table       | `.to` after #386 | old render                      |
  |------------------|------------------|---------------------------------|
  | `2fast`          | `Col_2fast`      | `REFERENCES "col_2fast"`      ✗ |
  | `driver profile` | `Driver_profile` | `REFERENCES "driver_profile"` ✗ |

Two layers, one defect. `Models.fk_target_table` feeds the DDL (`Dialect.create_table`,
`planner.add_foreign_key`); `_build_row_join`'s forward-FK arms feed the `JOIN`. Both now resolve the
binding, or refuse.

Why the join assertions are `!occursin` on the FABRICATION and not only `occursin` on the truth: a
parent whose name needs sanitizing is the only shape that separates the two answers. On an
already-legal lowercase name (`driver`) the old lowercase and the new resolution agree, so an
assertion built on one would stay green through a full revert. Every join assertion below therefore
uses a parent the lowercase gets WRONG — a spaced name, or a `db_table`-pinned one.

DB-free: mock connections render SQL through `inspect_query` / `Dialect`, no socket.
"""
# julia --project=. test/unit/test_fk_unresolved_target.jl

using Test
using PormG
using PormG.Models: Model, IDField, CharField, IntegerField, ForeignKey, fk_target_table
using PormG.QueryBuilder: inspect_query

struct MockPgFkUnres <: PormG.PormGPostgres end
struct MockSlFkUnres <: PormG.PormGSQLite end
PormG.config["fk_unres_mock"] = PormG.Configuration.Settings(
  connections = MockPgFkUnres(),
  change_data = true,
)

# One models module for the whole file. `_module`/`connect_key` are wired by hand rather than through
# `set_models`, which would try to LOAD a connection folder off disk — and, more to the point, would
# RESOLVE every `.to` and so hide the very branch under test.
const FKU_MOD = Module(:FkUnresScratch)
Base.eval(FKU_MOD, :(using PormG))

function fku_register!(binding::Symbol, model)
  model._module = FKU_MOD
  model.connect_key = "fk_unres_mock"
  Base.eval(FKU_MOD, :(const $binding = $model))
  return model
end

@testset "#388 · an unresolved ForeignKey target is never guessed into a table" begin

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # 1. DDL — `fk_target_table` refuses instead of fabricating.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "fk_target_table refuses an unresolved String target" begin
    # `Col_2fast` is the binding a table literally named `2fast` receives: `uppercasefirst` cannot
    # make a leading digit legal, so the sanitizer prefixes it. Lowercasing that binding yields
    # `col_2fast` — a table that does not exist, which used to reach the database inside a
    # `REFERENCES` clause with no warning at any layer.
    digit_fk = ForeignKey("Col_2fast", pk_field = "id", on_delete = "CASCADE")
    @test_throws PormG.ModelDefinitionError fk_target_table(digit_fk)

    err = try; fk_target_table(digit_fk); nothing; catch e; e end
    @test occursin("Col_2fast", err.msg)        # names the target it could not resolve …
    @test !occursin("col_2fast", err.msg)       # … and never the name it used to invent
    # The message has to point at the realistic cause. The ordinary way to reach this is a generated
    # file whose parent was filtered out of the import, not a typo.
    @test occursin("include_table", err.msg)
    @test occursin("ignore_table", err.msg)

    # A space is the other shape `uppercasefirst` cannot invert: `driver profile` binds as
    # `Driver_profile`, whose lowercase is `driver_profile` — a DIFFERENT table that may well also
    # exist in the same schema, which is what made this silent rather than merely wrong.
    spaced_fk = ForeignKey("Driver_profile", pk_field = "id")
    @test_throws PormG.ModelDefinitionError fk_target_table(spaced_fk)

    # An EMPTY target is refused by the same seam rather than throwing something incidental — and
    # reports as "is not set" rather than interpolating nothing between two spaces. `ForeignKey("")`
    # sets `.to == ""`, NOT `nothing`, so this is the empty-string arm; the `nothing` arm is the
    # assertion below it, reachable only post-construction since the constructor requires a target.
    @test_throws PormG.ModelDefinitionError fk_target_table(ForeignKey(""))
    empty_err = try; fk_target_table(ForeignKey("")); nothing; catch e; e end
    @test occursin("is not set", empty_err.msg)
    @test !occursin("target  is", empty_err.msg)     # no double space where the name would go

    nil_fk = ForeignKey("Fku_placeholder"); nil_fk.to = nothing
    @test_throws PormG.ModelDefinitionError fk_target_table(nil_fk)
    nil_err = try; fk_target_table(nil_fk); nothing; catch e; e end
    @test occursin("is not set", nil_err.msg)

    # Whitespace-only is as unresolvable as empty and must read the same way, not as a blank gap.
    blank_err = try; fk_target_table(ForeignKey(" ")); nothing; catch e; e end
    @test occursin("is not set", blank_err.msg)

    # The message names WHICH key when the caller can say. A field knows its target but not its own
    # name or owner, so without this the error is "target X is missing" for a parent that a dozen
    # children may reference — and every DDL call site has both in scope, so they all pass them.
    ctx_err = try
      fk_target_table(digit_fk; column = "co_dia_semana", model = "tb_agendado"); nothing
    catch e; e end
    @test occursin("co_dia_semana", ctx_err.msg)
    @test occursin("tb_agendado", ctx_err.msg)
    # …and stays well-formed when the caller cannot: no empty parenthetical, no dangling "in".
    @test !occursin("(foreign key)", err.msg)
    @test !occursin(" in )", err.msg)
  end

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # 2. DDL positive control — a key that CAN name its table still renders, on both backends.
  #    This is the assertion that goes red if the refusal over-corrects into rejecting valid keys.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "a resolvable target still renders REFERENCES" begin
    # Plain parent: no db_table, so the table is the logical name, verbatim.
    plain_parent = Model("fku_driver_scratch", id = IDField(), surname = CharField())
    # Pinned parent: db_table differs from the logical name, and must WIN. Before #388 the String
    # branch ignored db_table entirely, so a pinned parent was referenced by the wrong name even
    # when the lowercase guess would otherwise have inverted cleanly.
    # A space is deliberate: it is the sharpest proof that `db_table` reaches the `REFERENCES`
    # clause verbatim. It used to be a one-sided proof — the DDL rendered it and the query builder
    # then REFUSED it, because `SAFE_IDENTIFIER_PATTERN` rejected a space that `_quote_table_ddl`
    # escaped happily, so PormG would migrate a table it could not join. #394 closed that: a
    # physical name is escaped rather than validated on both layers, and this same spelling is
    # exercised end-to-end in `test/unit/test_identifier_quoting.jl`.
    pinned_parent = Model("fku_pinned_scratch", db_table = "Fku Pinned Table",
                          id = IDField(), surname = CharField())

    child = Model("fku_result_scratch",
      id       = IDField(),
      points   = IntegerField(),
      plainid  = ForeignKey(plain_parent, pk_field = "id", on_delete = "CASCADE"),
      pinnedid = ForeignKey(pinned_parent, pk_field = "id", on_delete = "CASCADE"),
    )

    @test fk_target_table(child.fields["plainid"])  == "fku_driver_scratch"
    @test fk_target_table(child.fields["pinnedid"]) == "Fku Pinned Table"

    # SQLite carries FKs inline in CREATE TABLE, so the created table and both referenced ones are
    # rendered by a single call — this asserts they agree as ONE string.
    # The DDL renderers pass `column`/`model` through, so a refusal raised from inside `create_table`
    # names the offending key rather than just the missing parent.
    ddl_err = try
      PormG.Dialect.create_table(MockSlFkUnres(),
        Model("fku_ddl_ctx_scratch", id = IDField(),
              co_dia_semana = ForeignKey("Fku_Filtered_Parent", pk_field = "id")))
      nothing
    catch e; e end
    @test ddl_err isa PormG.ModelDefinitionError
    @test occursin("co_dia_semana", ddl_err.msg)
    @test occursin("fku_ddl_ctx_scratch", ddl_err.msg)

    ddl = PormG.Dialect.create_table(MockSlFkUnres(), child)
    @test occursin("REFERENCES \"fku_driver_scratch\"(\"id\")", ddl)
    @test occursin("REFERENCES \"Fku Pinned Table\"(\"id\")", ddl)
    @test !occursin("REFERENCES \"fku_pinned_scratch\"", ddl)   # the logical name never reaches DDL

    # PostgreSQL does NOT carry foreign keys in CREATE TABLE — `create_table(::PormGPostgres, …)`
    # renders columns only and never calls `fk_target_table` at all. (Measured: on an unresolved FK
    # it returns DDL without raising, while the SQLite call on the SAME model raises.) So an
    # `occursin("CREATE TABLE", create_table(pg, …))` assertion here would constrain nothing
    # whatsoever — it passes before the fix, after it, and if the refusal over-corrected into
    # rejecting valid keys. It was exactly that, and this replaces it.
    #
    # PG's real `fk_target_table` call sites are the planner's ALTER paths (`_add_constrains`,
    # `_add_fk_constraint_in_alteration`), both of which render through `add_foreign_key`. That is
    # the seam to assert, and it is where a fabricated parent name would have reached a PG database.
    pg_fk = PormG.Dialect.add_foreign_key(MockPgFkUnres(), "fku_result_scratch",
      "\"fku_pinned_fk\"", "\"pinnedid\"",
      "\"$(fk_target_table(child.fields["pinnedid"]))\"", "\"id\"")
    @test occursin("REFERENCES \"Fku Pinned Table\"", pg_fk)
    @test !occursin("fku_pinned_scratch", pg_fk)          # the logical name never reaches PG DDL
  end

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # 3. JOIN — hop 1 of `_build_row_join`. A String `.to` resolves to the model and reads the table
  #    off it, so `db_table` wins and a sanitized binding is not folded into a fictional table.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "first-hop join resolves the binding instead of lowercasing it" begin
    # MIXED CASE rather than a spaced name, and it stays that way after #394 made a spaced table
    # queryable: the property this testset needs is that the lowercase fold is NOT an identity, so
    # the old lowercase and the new resolution give DIFFERENT answers and the assertions can tell
    # them apart. A space has that property too, but it also exercises the escape path, which would
    # make a failure here ambiguous between the binding resolution (#388) and the quoting (#394).
    #
    # Pinned parent: binding `Fku_pinned` -> lowercase `fku_pinned`, but the table is
    # `Fku_Pinned_Physical`. The old branch ignored `db_table` entirely, so it joined a table that
    # does not exist even though the fold itself was clean.
    fku_register!(:Fku_pinned,
      Model("fku_pinned_logical", db_table = "Fku_Pinned_Physical",
            id = IDField(), code = CharField()))
    # Mixed-case LOGICAL name via the Dict arity — the introspection-exempt path (#300/#59), where
    # the name is read from a live database and must survive verbatim. Binding `Fku_Mixed_Parent`
    # folds to `fku_mixed_parent`, which is a different table on PostgreSQL.
    fku_register!(:Fku_Mixed_Parent,
      Model("Fku_Mixed_Parent", Dict{String, PormG.PormGField}(
        "id" => IDField(), "surname" => CharField())))

    # `.to` stays a STRING on purpose — that is the unresolved shape. Both keys are declared by
    # binding name, exactly as a generated models file spells them.
    child = fku_register!(:Fku_lap,
      Model("fku_lap_scratch",
        id       = IDField(),
        millis   = IntegerField(),
        mixedid  = ForeignKey("Fku_Mixed_Parent", pk_field = "id", on_delete = "CASCADE"),
        pinnedid = ForeignKey("Fku_pinned",       pk_field = "id", on_delete = "CASCADE"),
      ))
    @test child.fields["mixedid"].to isa String   # guard: the branch under test is really taken

    sql = inspect_query(child.objects.values("millis", "mixedid__surname"))[:sql_text]
    @test occursin("\"Fku_Mixed_Parent\"", sql)    # the real table …
    @test !occursin("fku_mixed_parent", sql)       # … and never the folded fabrication

    pin_sql = inspect_query(child.objects.values("millis", "pinnedid__code"))[:sql_text]
    @test occursin("\"Fku_Pinned_Physical\"", pin_sql)   # db_table wins on the String branch too
    @test !occursin("fku_pinned", pin_sql)               # neither the folded binding nor the logical name
  end

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # 4. JOIN — hop 2+. `_build_row_join` renders the second and later hops in a separate `while`
  #    loop with its own copy of the branch, which is why #388 counted three sites and not two.
  #    A test that only walked one hop would leave that copy uncovered.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "multi-hop join resolves every hop" begin
    # Same mixed-case shape as above, one hop further out. The grandparent is `db_table`-pinned so
    # hop 2 also proves the pin is honored, which the old branch dropped on the floor.
    fku_register!(:Fku_Team_Deep,
      Model("fku_team_deep_logical", db_table = "Fku_Team_Deep_TBL",
            id = IDField(), team_name = CharField()))
    fku_register!(:Fku_Driver_Deep,
      Model("Fku_Driver_Deep", Dict{String, PormG.PormGField}(
        "id" => IDField(), "surname" => CharField(),
        "teamid" => ForeignKey("Fku_Team_Deep", pk_field = "id", on_delete = "CASCADE"))))
    child = fku_register!(:Fku_deep_lap,
      Model("fku_deep_lap_scratch", id = IDField(), millis = IntegerField(),
            driverid = ForeignKey("Fku_Driver_Deep", pk_field = "id", on_delete = "CASCADE")))

    sql = inspect_query(child.objects.values("millis", "driverid__teamid__team_name"))[:sql_text]
    @test occursin("\"Fku_Driver_Deep\"", sql)    # hop 1
    @test occursin("\"Fku_Team_Deep_TBL\"", sql)  # hop 2 — the second copy of the branch
    @test !occursin("fku_driver_deep", sql)       # the folded binding, hop 1
    @test !occursin("fku_team_deep", sql)         # the folded binding / logical name, hop 2
  end

  # ───────────────────────────────────────────────────────────────────────────────────────────
  # 5. JOIN — an unresolvable binding raises a PormG error rather than leaking `UndefVarError`.
  #
  #    Scope, stated honestly: the old code failed here too. It just failed as a bare
  #    `UndefVarError` out of a `getfield`, naming a Julia symbol instead of the field path the user
  #    wrote. So what these assertions pin is the ERROR TYPE and its message, not the existence of
  #    an error — the type is what a caller can `catch`, and `UndefVarError` is not in the taxonomy.
  #    (An earlier version of this comment claimed a one-segment path used to emit silently wrong
  #    SQL. It does not: the `while` loop's own `getfield` catches the >2-segment case one iteration
  #    later, and a 1-segment path builds no join at all. The genuinely silent case is a binding
  #    that RESOLVES but whose table is not its lowercase — testsets 3 and 4 above.)
  #
  #    Both entry points are covered because they reach the branch differently: `values(...)` walks
  #    the projection, `filter(...)` walks the filter path.
  # ───────────────────────────────────────────────────────────────────────────────────────────
  @testset "an unresolvable binding raises QueryBuildError, not UndefVarError" begin
    orphan = fku_register!(:Fku_orphan,
      Model("fku_orphan_scratch", id = IDField(), value = IntegerField(),
            ghostid = ForeignKey("Fku_Never_Declared", pk_field = "id", on_delete = "CASCADE")))

    @test_throws PormG.QueryBuildError inspect_query(
      orphan.objects.values("value", "ghostid__whatever"))

    err = try
      inspect_query(orphan.objects.values("value", "ghostid__whatever")); nothing
    catch e; e end
    @test occursin("Fku_Never_Declared", err.msg)
    @test !occursin("fku_never_declared", err.msg)   # the fabrication is never offered as a table

    # The same refusal reached through `filter` rather than `values`. Not a different code path in
    # `_build_row_join` — `"ghostid__id"` is still a two-segment path — but a different way in, and
    # the two entry points have diverged before.
    @test_throws PormG.QueryBuildError inspect_query(
      orphan.objects.filter("ghostid__id" => 1).values("value"))
  end
end
