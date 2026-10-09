"""
Unit coverage for generated columns in the migration engine (#1032): a `SearchVectorField` declared
with `generated_from` is `GENERATED ALWAYS AS (…) STORED`, and PostgreSQL computes it.

PostgreSQL keeps a generation expression where it keeps a default (`pg_attrdef`), so the column IR
carries it in the `:default` slot as a `GeneratedExpression`. Pinned here, with mock connections and
synthetic catalog rows, no database:

  1. **The diff.** A declared generated column equals its live one by text or by its
     `pormg:generated:` marker. A plain declaration differs only from a generated column PormG
     created (owned); a hand-made one is left alone, the #496 rule.
  2. **The reader.** `attgenerated` decides: the expression is carried whole, with its owner, and
     never through the default cleaner.
  3. **The plan.** A generated column is re-created (DROP + ADD, destructive) when it becomes
     generated, when its expression changes, or when a source column is retyped — dropped before the
     source changes and added after, with its indexes planned again. Generated → plain is
     `DROP EXPRESSION`, which keeps the data. A rename that also regenerates is refused.
  4. **`check`, `inspectdb`, the fingerprint and the version gate.**

The live round trip — the deparsed text, the marker, EXPLAIN on a GIN index — is in
`test/integration/test_full_text_search.jl`.

julia --project=test/integration test/unit/test_generated_columns.jl
"""

using Test
using PormG
using PormG: Migrations, Dialect
using PormG.Models
using PormG: NoDefault, LiteralDefault, ExpressionDefault, GeneratedExpression, ColumnSpec, ColumnDelta,
             column_delta, canonical_db_default, db_default_hash, live_default_hash
import PormG.ConnectionPool: fetch
import PormG.Migrations: LiveTable, live_table, get_migration_plan, is_destructive
using DataFrames
using JSON
using Logging

# PostgreSQL stand-in: no catalog, so every planner lookup answers "nothing there".
struct GenMockPg1032 <: PormG.PormGPostgres end
const GEN_PG = GenMockPg1032()
fetch(::GenMockPg1032, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

# A server older than the schema-management floor: it answers only the version probe.
struct GenMockPg11 <: PormG.PormGPostgres end
fetch(::GenMockPg11, sql::String, args...; kwargs...) =
  occursin("server_version_num", sql) ? DataFrame(v = [110022]) : error("the schema query must not run on PostgreSQL 11")

_gen_err(f) = try f(); nothing catch e; e end
_gen_plain(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# The model the cases below change, one aspect at a time: a document generated from a title and a body,
# GIN-indexed. `gen = false` is the same column filled by `update`.
function _gen_doc(; gen::Bool = true, title = Models.CharField(max_length = 100), from = ("title", "body"),
                  weights = nothing, extra = (;))
  sv = gen ? Models.SearchVectorField(generated_from = from, config = "simple", weights = weights) :
             Models.SearchVectorField(null = true)
  return Models.Model("doc"; id = Models.IDField(), title = title, body = Models.TextField(null = true), extra...,
                      sv = sv, indexes = [Models.Index(fields = ("sv",), method = "gin", name = "doc_sv_gin")])
end

function _gen_plan(live::Vector{LiveTable}, declared; kwargs...)
  settings = PormG.Configuration.Settings(connections = GEN_PG, change_data = true)
  schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
    :doc => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => declared, :exist => false))
  return get_migration_plan(live, schema, GEN_PG, settings; interactive = false, kwargs...)
end

# The live table PormG would read back for `model`, with the generated column's marker vouching for
# its declaration — the state right after a migration PormG ran.
function _gen_owned_live(model)
  live = live_table(model, GEN_PG)
  cols = copy(live.columns)
  for (name, c) in cols
    c.default isa GeneratedExpression || continue
    owned = GeneratedExpression(c.default.sql, true, db_default_hash(c.default.sql))
    cols[name] = ColumnSpec(c.name, c.type, c.nullable, c.primary_key, c.unique, owned, c.reference,
                            c.checks, c.identity, c.raw)
  end
  return LiveTable(live.name, cols, live.indexes, live.composites, live.checks)
end

_gen_steps(plan) = collect(keys(get(plan, :doc, Dict{String, String}())))

@testset "Generated columns in the migration engine (#1032)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # The diff: a generated column is the `:default` slot, compared like an expression default
  # Text or marker between two generated columns; a plain declaration differs only from an OWNED
  # generated column, in the declared → live direction (#496's asymmetry). `ColumnSpec`'s `==` asks
  # both directions, so it stays strict, and its coarse `hash` stays consistent with it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the diff: text or marker, and a plain declaration leaves an unowned column alone" begin
    sql = canonical_db_default(Models.generated_sql(_gen_doc().fields["sv"]))
    declared = GeneratedExpression(sql, true, nothing)
    deparsed = GeneratedExpression("to_tsvector('simple'::regconfig, (COALESCE((title)::text, ''::text) || ' '::text))", true, nothing)
    owned = GeneratedExpression(deparsed.sql, true, db_default_hash(sql))
    eq = PormG.Kernel._defaults_equal
    @test eq(declared, declared)
    @test !eq(declared, deparsed)                 # deparsed text alone does not match…
    @test eq(declared, owned) && eq(owned, declared)  # …the marker does, either way round
    @test !eq(declared, GeneratedExpression(sql, false, nothing))   # VIRTUAL is never the declared STORED
    # A marker for another expression vouches for nothing.
    @test !eq(declared, GeneratedExpression(deparsed.sql, true, db_default_hash("to_tsvector('simple'::regconfig, x)")))
    # Plain declaration: an unowned live generated column agrees, an owned one does not.
    for plain in (NoDefault(), LiteralDefault(1), ExpressionDefault("now()"))
      @test eq(plain, deparsed)
      @test !eq(plain, owned)
      @test !eq(deparsed, plain)                  # the reverse: never lenient
    end
    # A marker on an expression DEFAULT cannot vouch for a generated column, nor the reverse.
    @test !eq(GeneratedExpression(sql, true, nothing), ExpressionDefault(sql, db_default_hash(sql)))
    # ColumnSpec: a delta in one direction is enough for `!=`, and equal specs hash equal.
    base = Migrations.column_spec(Models.SearchVectorField(null = true), GEN_PG; name = "sv")
    with(d) = ColumnSpec((f === :default ? d : getfield(base, f) for f in fieldnames(ColumnSpec))...)
    @test column_delta(with(NoDefault()), with(deparsed)) == Symbol[]
    @test column_delta(with(NoDefault()), with(owned)) == [:default]
    @test with(NoDefault()) != with(deparsed)
    @test with(declared) == with(owned) && hash(with(declared)) == hash(with(owned))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The PostgreSQL reader: `attgenerated` decides what the `default` text is
  # A generated column's expression is carried whole, with the owner its marker vouches for against
  # the RAW text; it never reaches the default cleaner, so nothing warns about it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the reader carries a generated column as GeneratedExpression, with its owner" begin
    decl = Models.generated_sql(Models.SearchVectorField(generated_from = ("title",), config = "simple"))
    raw = "to_tsvector('simple'::regconfig, COALESCE((title)::text, ''::text))"
    marker(h_decl, h_raw) = "pormg:generated:$(db_default_hash(h_decl)):$(live_default_hash(h_raw))"
    col(name, gen, comment; default = raw) = Dict{String, Any}("name" => name, "type" => "tsvector",
      "notnull" => true, "default" => default, "comment" => comment, "identity" => "", "generated" => gen,
      "unique" => false, "non_negative_check" => false, "byte_limit" => nothing)
    id = Dict{String, Any}("name" => "id", "type" => "bigint", "notnull" => true, "default" => nothing,
                           "identity" => "d", "generated" => "", "unique" => false,
                           "non_negative_check" => false, "byte_limit" => nothing)
    row = DataFrame(table_name = ["doc"],
                    columns = [JSON.json([id,
                      col("owned", "s", "Docs " * marker(decl, raw)),
                      col("stale", "s", marker(decl, "to_tsvector('simple'::regconfig, body)")),
                      col("handmade", "s", nothing),
                      col("virtual", "v", marker(decl, raw)),
                      # A default marker on a generated column vouches for nothing.
                      col("wrongkind", "s", "pormg:default:$(db_default_hash(decl)):$(live_default_hash(raw))"),
                      # Not generated: the same text is an expression default, as before.
                      col("plain", "", nothing)])],
                    primary_keys = [JSON.json(["id"])], foreign_keys = [missing], indexes = [missing])[1, :]
    live = @test_logs min_level = Logging.Warn Migrations._pg_live_table(row)
    @test live.columns["owned"].default == GeneratedExpression(canonical_db_default(raw), true, db_default_hash(decl))
    @test live.columns["stale"].default.owned === nothing
    @test live.columns["handmade"].default == GeneratedExpression(canonical_db_default(raw), true, nothing)
    @test live.columns["virtual"].default.stored == false
    @test live.columns["wrongkind"].default.owned === nothing
    @test live.columns["plain"].default isa ExpressionDefault
    # The declaration converges against the owned column, and against the hand-made one only when it
    # does not declare a generated column.
    declared = Migrations.column_spec(Models.SearchVectorField(generated_from = ("title",), config = "simple"), GEN_PG; name = "owned")
    @test column_delta(declared, live.columns["owned"]) == Symbol[]
    @test column_delta(declared, live.columns["handmade"]) == [:default]
    @test column_delta(declared, live.columns["virtual"]) == [:default]
    plain = Migrations.column_spec(Models.SearchVectorField(), GEN_PG; name = "handmade")
    @test column_delta(plain, live.columns["handmade"]) == Symbol[]
    @test column_delta(plain, live.columns["owned"]) == [:default]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The plan: create, converge, and re-create when the column becomes generated
  # PostgreSQL has no ALTER that makes a column generated before 17, so the column is dropped and
  # added again in one plan. DROP COLUMN takes its GIN index with it, so the index is planned again;
  # the plan is destructive, and `migrate` needs `destructive = true` for it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a new, an unchanged and a newly generated column" begin
    created = _gen_plan(LiveTable[], _gen_doc())
    @test occursin("GENERATED ALWAYS AS (", created[:doc]["New model"])
    @test occursin("pormg:generated:", created[:doc]["New model"])
    @test !is_destructive(join(values(created[:doc]), "\n"))
    # Converged: the column as declared, owned.
    @test isempty(_gen_steps(_gen_plan([_gen_owned_live(_gen_doc())], _gen_doc())))
    # plain → generated: dropped first, added back with its marker, its index planned again.
    plan = _gen_plan([live_table(_gen_doc(gen = false), GEN_PG)], _gen_doc())
    @test _gen_steps(plan) == ["Drop generated field: sv", "Re-add generated field: sv", "Create index: doc_sv_gin"]
    @test plan[:doc]["Drop generated field: sv"] == "ALTER TABLE \"doc\" DROP COLUMN \"sv\";"
    readd = plan[:doc]["Re-add generated field: sv"]
    @test startswith(readd, "ALTER TABLE \"doc\" ADD COLUMN \"sv\" tsvector NOT NULL GENERATED ALWAYS AS (")
    @test occursin("pormg:generated:", readd)
    @test is_destructive(join(values(plan[:doc]), "\n"))
    # Ordered as written: the drop runs before the add, both before the index bucket.
    ordered, _ = Migrations._order_statements([plan[k] for k in keys(plan)])
    @test findfirst(contains("DROP COLUMN"), ordered) < findfirst(contains("ADD COLUMN"), ordered) <
          findfirst(contains("CREATE INDEX"), ordered)
    # A changed expression: another column list, or weights.
    for changed in (_gen_doc(from = ("title",)), _gen_doc(weights = ("A", "B")))
      @test _gen_steps(_gen_plan([_gen_owned_live(_gen_doc())], changed))[1:2] ==
            ["Drop generated field: sv", "Re-add generated field: sv"]
    end
    # A db_index on the column is planned again too, and a UNIQUE rides inline on the ADD COLUMN.
    indexed = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                           sv = Models.SearchVectorField(generated_from = ("title",), config = "simple",
                                                         db_index = true, unique = true))
    plain_live = live_table(Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                                         sv = Models.SearchVectorField(null = true, db_index = true, unique = true)), GEN_PG)
    plan = _gen_plan([plain_live], indexed)
    @test "Create index on sv" in _gen_steps(plan)
    @test occursin(" UNIQUE NOT NULL GENERATED ALWAYS", plan[:doc]["Re-add generated field: sv"])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The plan: sources change under a generated column
  # PostgreSQL refuses ALTER COLUMN … TYPE on a column a generated one reads, so a retyped source
  # re-creates the generated column around it: drop, retype, add. A NEW generated column is moved
  # behind the table's other column steps, so a source added in the same plan exists first.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a source retype is ordered between the drop and the re-add; a new column follows its sources" begin
    live = _gen_owned_live(_gen_doc())
    plan = _gen_plan([live], _gen_doc(title = Models.CharField(max_length = 200)))
    @test _gen_steps(plan)[1:3] == ["Drop generated field: sv", "Alter field: title", "Re-add generated field: sv"]
    # A retype of a column the expression does not read leaves the generated column alone.
    other = _gen_doc(extra = (note = Models.CharField(max_length = 20),))
    other_live = _gen_owned_live(other)
    widened = _gen_doc(extra = (note = Models.CharField(max_length = 40),))
    @test _gen_steps(_gen_plan([other_live], widened)) == ["Alter field: note"]
    # A new generated column over a new source, declared BEFORE it.
    before = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100))
    after = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                         sv = Models.SearchVectorField(generated_from = ("title", "summary"), config = "simple"),
                         summary = Models.TextField(null = true))
    steps = _gen_steps(_gen_plan([live_table(before, GEN_PG)], after))
    @test findfirst(==("Add field: summary"), steps) < findfirst(==("Add field: sv"), steps)
    # A source removed: PostgreSQL refuses to drop it under the generated column, so the generated
    # column, whose expression no longer names it, is dropped first and added back after.
    no_body = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                           sv = Models.SearchVectorField(generated_from = ("title",), config = "simple"),
                           indexes = [Models.Index(fields = ("sv",), method = "gin", name = "doc_sv_gin")])
    @test _gen_steps(_gen_plan([live], no_body))[1:3] ==
          ["Drop generated field: sv", "Remove field: body", "Re-add generated field: sv"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The plan: generated → plain, and the rename that cannot be ordered
  # Removing `generated_from` from a column PormG generated is `DROP EXPRESSION` (PostgreSQL 13+): the
  # rows keep their last document, and nothing is dropped, so the plan is not destructive. A
  # hand-made generated column under a plain declaration plans nothing. A rename that also makes the
  # column generated is refused: rename first, then regenerate.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "generated → plain is DROP EXPRESSION; an unowned column is left alone; rename + regenerate is refused" begin
    plan = _gen_plan([_gen_owned_live(_gen_doc())], _gen_doc(gen = false))
    alter = plan[:doc]["Alter field: sv"]
    @test startswith(alter, "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" DROP EXPRESSION;")
    @test !occursin("DROP DEFAULT", alter)
    @test !is_destructive(join(values(plan[:doc]), "\n"))
    # Hand-made (no marker): only the declaration's own nullability differs.
    unowned = _gen_plan([live_table(_gen_doc(), GEN_PG)], _gen_doc(gen = false))
    @test !occursin("EXPRESSION", join(values(unowned[:doc]), "\n"))
    # A rename hint onto a newly generated column.
    old = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                       doc_old = Models.SearchVectorField(null = true))
    new = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                       doc_new = Models.SearchVectorField(generated_from = ("title",), config = "simple"))
    e = _gen_err(() -> _gen_plan([live_table(old, GEN_PG)], new; renames = ["doc.doc_old" => "doc.doc_new"]))
    @test e isa PormG.InvalidMigrationError
    @test occursin("Rename it first", _gen_plain(e))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The plan: a live generated column stops reading its sources before any of them changes
  # PostgreSQL refuses to retype or drop a column a generated one reads, so a plan that drops the
  # expression, or removes the generated column, puts that first — ahead of the source's own step,
  # whatever order the deletion loop and the column loop register them in. A column that stays
  # generated over a changed source cannot be ordered at all, and is refused at plan time.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a generated column is released before its sources change, or the plan is refused" begin
    live = _gen_owned_live(_gen_doc())
    first_two(p) = _gen_steps(p)[1:2]
    # (a) The generated column and one of its sources removed together.
    gone = Models.Model("doc", id = Models.IDField(), body = Models.TextField(null = true))
    steps = _gen_steps(_gen_plan([live], gone))
    @test steps[1] == "Release generated field: sv"
    @test findfirst(==("Remove field: title"), steps) > 1 && "Remove field: sv" in steps
    # Removed alone, it needs no PostgreSQL 13 `DROP EXPRESSION` first.
    alone = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 100),
                         body = Models.TextField(null = true))
    @test !("Release generated field: sv" in _gen_steps(_gen_plan([live], alone)))
    # (b) Made plain, and a source removed: the DROP EXPRESSION runs before the DROP COLUMN.
    plain_no_title = Models.Model("doc", id = Models.IDField(), body = Models.TextField(null = true),
                                  sv = Models.SearchVectorField(null = true))
    plan = _gen_plan([live], plain_no_title)
    @test first(_gen_steps(plan)) == "Alter field: sv"
    @test startswith(plan[:doc]["Alter field: sv"], "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" DROP EXPRESSION;")
    # (c) Made plain, and a source widened: the DROP EXPRESSION runs before the TYPE change.
    @test first_two(_gen_plan([live], _gen_doc(gen = false, title = Models.CharField(max_length = 300)))) ==
          ["Alter field: sv", "Alter field: title"]
    # Still generated, but not re-created — renamed, or hand-made under a plain declaration — over a
    # retyped source: refused.
    renamed = Models.Model("doc", id = Models.IDField(), title = Models.CharField(max_length = 300),
                           body = Models.TextField(null = true),
                           doc_vec = Models.SearchVectorField(generated_from = ("title", "body"), config = "simple"))
    e = _gen_err(() -> _gen_plan([live], renamed; renames = ["doc.sv" => "doc.doc_vec"]))
    @test e isa PormG.InvalidMigrationError && occursin("reads a column this plan", _gen_plain(e))
    handmade = live_table(_gen_doc(), GEN_PG)
    e = _gen_err(() -> _gen_plan([handmade], Models.Model("doc", id = Models.IDField(),
                                 title = Models.CharField(max_length = 300), body = Models.TextField(null = true),
                                 sv = Models.SearchVectorField())))
    @test e isa PormG.InvalidMigrationError && occursin("(title)", _gen_plain(e))
    # The control: a retype of a column the expression does not read is planned as usual.
    other = _gen_doc(extra = (note = Models.CharField(max_length = 20),))
    plan = _gen_plan([live_table(other, GEN_PG)], _gen_doc(gen = false, extra = (note = Models.CharField(max_length = 40),)))
    @test "Alter field: note" in _gen_steps(plan)
    @test !occursin("EXPRESSION", join(values(plan[:doc]), "\n"))     # the hand-made column is left generated
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # alter_field's `:default` branch for a generated column
  # Old side generated: DROP EXPRESSION first — before a TYPE change, which then needs no DROP DEFAULT
  # for its USING — and then the new default, if any. New side generated: a contract error, since the
  # planner re-creates such a column rather than altering it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "alter_field drops the expression, sets the new default, and never makes a column generated" begin
    f_plain = Models.SearchVectorField(null = true)
    gen = Migrations.column_spec(Models.SearchVectorField(generated_from = ("title",), config = "simple"), GEN_PG; name = "sv")
    plain = Migrations.column_spec(f_plain, GEN_PG; name = "sv")
    sql = Dialect.alter_field(GEN_PG, "doc", "sv", f_plain, ColumnDelta(plain, gen, [:default]))
    @test sql == "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" DROP EXPRESSION;"
    # To an expression default: drop, set, stamp — in that order.
    f_expr = Models.SearchVectorField(null = true, db_default = (postgres = "to_tsvector('simple'::regconfig, '')",))
    expr = Migrations.column_spec(f_expr, GEN_PG; name = "sv")
    parts = Migrations._split_pg_statements(Dialect.alter_field(GEN_PG, "doc", "sv", f_expr, ColumnDelta(expr, gen, [:default])))
    @test parts[1] == "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" DROP EXPRESSION"   # the splitter drops the `;`
    @test startswith(parts[2], "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" SET DEFAULT ")
    @test occursin("pormg:default:", parts[3])
    # A retype with a USING out of a generated column: the expression goes, and no DROP DEFAULT.
    f_text = Models.TextField(null = true)
    text = Migrations.column_spec(f_text, GEN_PG; name = "sv")
    retyped = Dialect.alter_field(GEN_PG, "doc", "sv", f_text, ColumnDelta(text, gen, [:type, :default]))
    @test startswith(retyped, "ALTER TABLE \"doc\" ALTER COLUMN \"sv\" DROP EXPRESSION;")
    @test occursin("TYPE text", retyped) && !occursin("DROP DEFAULT", retyped)
    # Into a generated column: refused, whatever the old side.
    e = _gen_err(() -> Dialect.alter_field(GEN_PG, "doc", "sv", f_plain, ColumnDelta(gen, plain, [:default])))
    @test e isa PormG.InvalidMigrationError
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The schema fingerprint writes a generated column out explicitly
  # Stored-ness and owner are part of it; a table with no generated column digests as before (the
  # pinned digests in test_plan_schema_fingerprint.jl stay untouched).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the fingerprint serializes GeneratedExpression" begin
    term(d) = sprint(Migrations._fp_term, d)
    @test term(GeneratedExpression("x", true, nothing)) == "GeneratedExpression(sql=\"x\",stored)"
    @test term(GeneratedExpression("x", false, "abcd")) == "GeneratedExpression(sql=\"x\",virtual,owned=\"abcd\")"
    @test term(GeneratedExpression("x", true, nothing)) != term(ExpressionDefault("x"))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `check` does not tell a generated column to declare a db_default
  # Its `default` text is the generation expression; the expression-default advice would be wrong.
  # The control: the same text on an ordinary column is still reported.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "check skips a generated column's expression" begin
    col(name, gen) = Dict{String, Any}("name" => name, "type" => "text", "notnull" => false,
                                       "default" => "lower('A'::text)", "generated" => gen)
    frame = DataFrame(table_name = ["doc"], columns = [JSON.json([col("gen", "s"), col("plain", "")])],
                      primary_keys = [JSON.json(String[])], foreign_keys = [missing])
    found = Migrations._pg_expression_default_findings(frame; ignore_table = String[])
    @test [only(f.columns) for f in found] == ["plain"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # inspectdb: an owned generated tsvector column is written back with its keywords
  # The deparsed text is read LOOSELY for the config, the columns and the weights, and accepted only
  # when re-rendering them hashes to what the marker vouches for. Anything else is the plain field,
  # with a warning, never silently.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "inspectdb recovers an owned generated column and warns for the rest" begin
    weighted = Models.SearchVectorField(generated_from = ("title", "body"), config = "simple", weights = ("A", "B"))
    owner = db_default_hash(Models.generated_sql(weighted))
    # How PostgreSQL prints that expression back: casts added, identifiers unquoted.
    deparsed = "(setweight(to_tsvector('simple'::regconfig, COALESCE((title)::text, ''::text)), 'A'::\"char\") || " *
               "setweight(to_tsvector('simple'::regconfig, COALESCE(body, ''::text)), 'B'::\"char\"))"
    spec(d) = ColumnSpec("sv", PormG.CTsVector(), false, false, false, d, nothing, PormG.CheckKind[], nothing, "tsvector")
    table = LiveTable("doc", PormG.OrderedCollections.OrderedDict{String, ColumnSpec}(), Dict{String, Union{String, Nothing}}())
    back = Migrations.field_from_spec(spec(GeneratedExpression(canonical_db_default(deparsed), true, owner)), table, GEN_PG)
    @test back.generated_from == ("title", "body") && back.config == "simple" && back.weights == ("A", "B")
    @test Models.generated_sql(back) == Models.generated_sql(weighted)
    # Unweighted, one column.
    one = Models.SearchVectorField(generated_from = ("title",), config = "english")
    back = Migrations.field_from_spec(spec(GeneratedExpression("to_tsvector('english'::regconfig, COALESCE((title)::text, ''::text))",
                                                               true, db_default_hash(Models.generated_sql(one)))), table, GEN_PG)
    @test back.generated_from == ("title",) && back.weights === nothing
    # A schema-qualified config is printed without its schema; the hash picks the declared spelling.
    # (A config is lower-cased at the constructor, the way regconfig folds it.)
    @test Models.SearchVectorField(generated_from = ("title",), config = "English").config == "english"
    qualified = Models.SearchVectorField(generated_from = ("title",), config = "pg_catalog.english")
    back = Migrations.field_from_spec(spec(GeneratedExpression("to_tsvector('english'::regconfig, COALESCE((title)::text, ''::text))",
                                                               true, db_default_hash(Models.generated_sql(qualified)))), table, GEN_PG)
    @test back.config == "pg_catalog.english"
    @test Models.generated_sql(back) == Models.generated_sql(qualified)
    # Unowned, a marker for another expression, VIRTUAL: the plain field, and a warning.
    for d in (GeneratedExpression(canonical_db_default(deparsed), true, nothing),
              GeneratedExpression(canonical_db_default(deparsed), true, db_default_hash("to_tsvector('simple'::regconfig, x)")),
              GeneratedExpression(canonical_db_default(deparsed), false, owner))
      # An owned one is the case the plain declaration is NOT safe for, and the warning says so.
      says = d.owned === nothing ? r"leaves the column as it is" : r"plans ALTER COLUMN … DROP EXPRESSION"
      plain = @test_logs (:warn, says) Migrations.field_from_spec(spec(d), table, GEN_PG)
      @test !Models.is_generated_field(plain)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The schema-management floor is PostgreSQL 12, asked before the schema query
  # The schema query reads `attgenerated`, which PostgreSQL 11 lacks; an older server gets the
  # requirement by name, as BackendCapabilityError, and the query never runs.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an older server is refused by name, before the schema query" begin
    e = _gen_err(() -> Migrations.get_database_schema(GenMockPg11()))
    @test e isa PormG.BackendCapabilityError
    msg = _gen_plain(e)
    @test occursin("needs PostgreSQL 12 or newer", msg) && occursin("server_version_num 110022", msg)
    @test occursin("Queries and writes are not affected", msg)
  end
end
