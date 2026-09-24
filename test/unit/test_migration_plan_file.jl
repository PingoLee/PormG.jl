# =============================================================================
# The migration plan file: escaped on write, parsed and never run on read (#710)
#
# `makemigrations` writes `pending_migrations.jl` as Julia source. Its SQL, labels and table names
# carry LIVE CATALOG identifiers (an undeclared table or index, an FK or composite-constraint name),
# and before #710 they were written unescaped and the file was loaded with `include`. So an index
# named `ix$(run(`…`))` executed on the operator's machine at the next `dry_run()` / `migrate()`,
# and a plain `default = "R$ 0,00"` produced a file that could not be parsed at all.
#
# The fix has two halves, and this file pins both separately, because either one alone closes only
# part of it:
#   - the WRITER (`Generator._plan_str_literal`, `dict_to_jl_str`, the `# table:` comment) escapes
#     every string, so what is planned is what is read back, byte for byte;
#   - the READER (`Migrations._read_migration_plan`) parses the file and accepts only literal
#     shapes, so a file poisoned by an older writer, or edited by hand, is refused instead of run.
#
# Hermetic: no database. The planner case renders DDL against a mock PostgreSQL connection.
# =============================================================================

using Test
using DataFrames
using PormG
using PormG.Models
using PormG.Migrations
import PormG: PormGPostgres
import PormG.ConnectionPool: fetch
import OrderedCollections: OrderedDict

# The payload every hostile string carries. It lives in `Main` because a plan file loaded with
# `include` evaluated in a module of its own, and `Main.` is the one name every module resolves.
# A counter rather than a flag, so a test sees HOW MANY times a payload ran (the issue's repro ran
# it three times: once from the label, once from the SQL, once from the table-key comment).
isdefined(Main, :PLAN_PAYLOAD_710) || Core.eval(Main, :(const PLAN_PAYLOAD_710 = Ref(0)))
const _PAYLOAD_710 = raw"$(Main.PLAN_PAYLOAD_710[] += 1)"

# Suffixed names: `runtests.jl` includes every unit file into ONE module.
struct PlanFileMockPg710 <: PormGPostgres end
const PFPG710 = PlanFileMockPg710()
PormG.get_constraints_pk(::PlanFileMockPg710, t::String, f::String) = nothing
PormG.get_constraints_unique(::PlanFileMockPg710, t::String, f::String) = nothing
PormG.get_constraints_check(::PlanFileMockPg710, t::String, f::String) = nothing
PormG.get_constraints_byte_length_check(::PlanFileMockPg710, t::String, f::String) = nothing
fetch(::PlanFileMockPg710, sql::String; conn = nothing, params = nothing, ignore_tx::Bool = false) = DataFrame()

const PlanOf710 = OrderedDict{Symbol, OrderedDict{String, String}}

# Write `plan` the way `makemigrations` does and read it back the way `dry_run`/`migrate` do.
function _plan_roundtrip_710(plan::PlanOf710)
  mktempdir() do dir
    PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, dir)
    path = joinpath(dir, "pending_migrations.jl")
    return read(path, String), Migrations._read_migration_plan(path)
  end
end

# Read a hand-written plan file and return what it raised (or `nothing`).
function _read_text_710(text::String)
  mktempdir() do dir
    path = joinpath(dir, "pending_migrations.jl")
    write(path, text)
    return try
      Migrations._read_migration_plan(path)
      nothing
    catch e
      e
    end
  end
end

# The strings that broke the old writer. Each is a real spelling: `$` and `\` come from defaults and
# check constraints, the quote runs from quoted identifiers, CR from a value pasted on Windows, and
# the last two exercise the triple-quoted literal's own rewrites (dedent and a dropped leading
# newline), which the writer must detect and route to the `repr` fallback.
const HOSTILE_STRINGS_710 = [
  "DROP INDEX IF EXISTS \"ix" * _PAYLOAD_710 * "\";",
  "ALTER TABLE price ADD \"label\" VARCHAR(20) DEFAULT 'R\$ 0,00' NOT NULL;",
  "SELECT 'ix\$foo';",
  "CHECK (path LIKE 'C:\\temp\\%')",
  "SELECT '\"\"\"';",
  "CREATE TABLE \"\" (x INT)",
  "ends with a quote\"",
  "x\r\ny",
  "\n  leading newline",
  "  a\n  b",
  "tab\there",
  "",
]

@testset "Migration plan file (#710)" begin
  PLAN_PAYLOAD_710[] = 0

  # ─────────────────────────────────────────────────────────────────────────────
  # Writer: every literal re-parses to exactly the string it was written from
  # This is the property the rest depends on, checked at the level of one literal so a failure names
  # the offending string. `Meta.parse` only parses, so a payload cannot run here even on a bad writer.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "each string literal round-trips through the parser" begin
    for s in HOSTILE_STRINGS_710
      @test Meta.parse(PormG.Generator._plan_str_literal(s)) == s
    end
    # Ordinary SQL keeps the readable triple-quoted form, unescaped: a plan still reviews as SQL.
    @test PormG.Generator._plan_str_literal("CREATE TABLE \"a\" (\n  \"id\" BIGINT\n);") ==
          "\"\"\"CREATE TABLE \"a\" (\n  \"id\" BIGINT\n);\"\"\""
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The issue's repro: hostile catalog names through generate_migration_plan and back
  # The label, the SQL and the table key all carry a payload. After the fix the plan read back is
  # byte-identical to the plan written, and the payload ran zero times (it ran three times before).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "hostile identifiers round-trip byte-identically and never run" begin
    evil = "ix" * _PAYLOAD_710
    key_payload = Symbol("pit\nMain.PLAN_PAYLOAD_710[] += 1")
    plan = PlanOf710(
      :result => OrderedDict{String, String}(
        "Remove composite index: $(evil)" => "DROP INDEX IF EXISTS \"$(evil)\";",
        (("Statement $i" => s) for (i, s) in enumerate(HOSTILE_STRINGS_710))...),
      key_payload => OrderedDict{String, String}("Drop table" => "SELECT 1;"),
      # A table name carrying every character the `var"..."` binding has to escape.
      Symbol("we\"ird\\ \$x") => OrderedDict{String, String}("New model" => "SELECT 2;"))

    text, loaded = _plan_roundtrip_710(plan)
    @test PLAN_PAYLOAD_710[] == 0

    # Same dicts, nothing lost or altered, and the same statement ORDER within each: `collect`
    # turns a dict into a vector of pairs, because `==` on two OrderedDicts ignores order, and that
    # order feeds `_order_statements` and the checksum. The reader orders TABLES by binding name,
    # so the outer comparison is a set; table order is pinned in its own testset.
    @test length(loaded) == length(plan)
    @test Set(collect.(loaded)) == Set(collect.(values(plan)))

    # The newline in the table key stays inside its comment, which is now ONE line followed directly
    # by the binding. The old `# table: <key>` line ended at that newline and the rest of the key
    # became a statement. (The `var"..."` binding below it does span two lines, and legitimately:
    # it is a raw string literal, so the payload text inside it is data.)
    @test occursin("# table: pit\\nMain.PLAN_PAYLOAD_710[] += 1\nvar\"pit\n", text)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Reader: a file that is not pure data is refused, and nothing in it runs
  # This is the case the writer cannot fix: a pending file written BEFORE #710 (or edited by hand)
  # that already contains live code. Every shape must raise InvalidMigrationError — the migration
  # taxonomy type, not a ParseError/LoadError — and leave the payload counter at zero.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a non-data plan file is rejected without running it" begin
    head = "module pending_migrations\nimport OrderedCollections: OrderedDict\n"
    entry(v) = "t = OrderedDict{String, String}(\"Drop\" => " * v * ")\n"

    cases = [
      # What the pre-#710 writer produced for a hostile index name: interpolation in the SQL.
      "interpolation"   => head * entry("\"\"\"DROP INDEX \"ix" * _PAYLOAD_710 * "\";\"\"\"") * "end\n",
      # What the pre-#710 `# table:` comment produced for a key with a newline: a bare statement.
      "statement"       => head * "# table: pit\nMain.PLAN_PAYLOAD_710[] += 1\n" * entry("\"SELECT 1;\"") * "end\n",
      "outside module"  => "Main.PLAN_PAYLOAD_710[] += 1\n" * head * entry("\"SELECT 1;\"") * "end\n",
      "call as value"   => head * entry("string(Main.PLAN_PAYLOAD_710[] += 1)") * "end\n",
      "call as dict"    => head * "t = Main.PLAN_PAYLOAD_710[] += 1\nend\n",
      "concatenation"   => head * entry("\"SELECT \" * \"1;\"") * "end\n",
      # A `_` binding assigns to nothing; the include-based reader silently lost the table.
      "discard binding" => head * "_ = OrderedDict(\"Drop\" => \"SELECT 1;\")\nend\n",
      "two modules"     => head * "end\n" * head * "end\n",
      # Under `include` the second binding silently replaced the first: a table's statements lost.
      "bound twice"     => head * entry("\"SELECT 1;\"") * entry("\"SELECT 2;\"") * "end\n",
      # What the pre-#710 writer produced for `default = "R$ 0,00"`: not valid Julia at all.
      "unparseable"     => head * entry("\"\"\"DEFAULT 'R\$ 0,00'\"\"\"") * "end\n",
    ]
    for (what, text) in cases
      err = _read_text_710(text)
      @test err isa PormG.InvalidMigrationError
      err isa PormG.InvalidMigrationError || @info "not rejected as expected" what err
    end
    @test PLAN_PAYLOAD_710[] == 0

    # The interpolation message says what is wrong and names the line, so the user can find it.
    msg = PormG.error_message(_read_text_710(first(cases)[2]))
    @test occursin("interpolation", msg)
    @test occursin("line 3", msg)
    @test occursin("makemigrations", msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Distinct table names that PARSE to one binding each keep their own entry
  # The parser normalizes the name inside `var"..."`: a raw CR becomes LF, a decomposed `é`
  # becomes the composed one, `µ` (micro sign) becomes `μ` (Greek mu). And `_` is written as
  # `pormg_plan__`. The `include`-based reader silently dropped one table of each such pair. The
  # reader now refuses a duplicate binding, so the WRITER has to avoid one. Every table must come
  # back.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "table names that collide as bindings keep every table" begin
    collisions = [("a\rb", "a\nb"),                  # CR normalized to LF
                  ("cafe\u0301", "caf\u00e9"),       # NFD vs NFC é
                  ("\u00b5g_dose", "\u03bcg_dose"),  # micro sign vs Greek mu
                  ("_", "pormg_plan__")]             # the all-underscore prefix
    for (x, y) in collisions
      plan = PlanOf710(
        Symbol(x) => OrderedDict{String, String}("New model" => "SELECT 1;"),
        Symbol(y) => OrderedDict{String, String}("New model" => "SELECT 2;"))
      _, loaded = _plan_roundtrip_710(plan)
      @test Set(collect.(loaded)) == Set(collect.(values(plan)))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The engine's own entry points read the plan through the safe reader
  # The testset above proves `_read_migration_plan` refuses a poisoned file; this one proves the
  # three public paths that load `pending_migrations.jl` actually go through it. `discard` is the
  # sharpest case: it swallows a load error on purpose (discarding a bad draft is its job), so under
  # the old `include` it ran the payload and then reported success.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "dry_run, _load_migration_plan and discard never run a poisoned plan" begin
    poisoned = "module pending_migrations\nimport OrderedCollections: OrderedDict\n" *
               "t = OrderedDict{String, String}(\"Drop\" => \"\"\"DROP INDEX \"ix" * _PAYLOAD_710 *
               "\";\"\"\")\nend\n"
    mktempdir() do dir
      mkpath(joinpath(dir, "migrations"))
      pending = joinpath(dir, "migrations", "pending_migrations.jl")
      write(pending, poisoned)
      st = PormG.Configuration.Settings(change_data = true)
      st.db_def_folder = dir

      @test_throws PormG.InvalidMigrationError Migrations._load_migration_plan(st)
      @test_throws PormG.InvalidMigrationError Migrations.dry_run(PFPG710, st)
      result = Migrations.discard_pending_migration(st; backup = false)
      @test result.discarded
      @test result.statements == 0      # counts are best-effort; the unreadable plan counts nothing
      @test !isfile(pending)
    end
    @test PLAN_PAYLOAD_710[] == 0
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A plain plan is written exactly as before #710
  # The escaping must not touch a plan that needs none: the file stays readable as SQL, and a plan
  # generated by this engine is byte-identical to one from the previous one. The expected text is
  # built by concatenation so the separator line's trailing space survives any editor.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a plain plan file is byte-identical to the pre-#710 writer" begin
    plan = PlanOf710(:drivers => OrderedDict{String, String}(
      "New model" => "CREATE TABLE drivers (\n  \"driverid\" BIGINT PRIMARY KEY\n);",
      "Add field: code" => "ALTER TABLE drivers ADD \"code\" VARCHAR(3);"))
    text, loaded = _plan_roundtrip_710(plan)
    expected = join([
      "module pending_migrations",
      "# pormg-migration-format: $(Migrations.MIGRATION_FORMAT_VERSION)",
      "",
      "import PormG.Migrations",
      "import OrderedCollections: OrderedDict",
      "",
      "# table: drivers",
      "drivers = OrderedDict{String, String}(",
      "\"New model\" =>",
      " \"\"\"CREATE TABLE drivers (",
      "  \"driverid\" BIGINT PRIMARY KEY",
      ");\"\"\",",
      " ",
      "\"Add field: code\" =>",
      " \"\"\"ALTER TABLE drivers ADD \"code\" VARCHAR(3);\"\"\")",
      "",
      "end",
      ""], "\n")
    @test text == expected
    @test collect.(loaded) == [collect(plan[:drivers])]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The reader returns tables in the order the include-based reader did
  # That order was `names(mod, all = true)` — sorted by binding name — and it reaches the statement
  # order inside each `_order_statements` bucket, and so the checksum. The old reader is emulated
  # here on a BENIGN file, the only place this file still `include`s a plan.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "table order matches the include-based reader" begin
    plan = PlanOf710()
    for k in (:zeta, :Alpha, Symbol("odd name"), Symbol("_"), :beta, Symbol("2fast"), Symbol("end"))
      plan[k] = OrderedDict{String, String}("New model" => "CREATE TABLE \"$(k)\" (id INT);")
    end
    mktempdir() do dir
      PormG.Generator.generate_migration_plan("pending_migrations.jl", plan, dir)
      path = joinpath(dir, "pending_migrations.jl")
      mod = Base.include(Module(), path)
      old_order = Base.invokelatest() do
        [getfield(mod, n) for n in names(mod, all = true)
         if isdefined(mod, n) && getfield(mod, n) isa OrderedDict]
      end
      @test length(old_order) == length(plan)
      @test Migrations._read_migration_plan(path) == old_order
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The real planner: a `$` in a CharField default
  # The everyday half of the issue, no attacker needed: the planner renders `DEFAULT 'R$ 0,00'`,
  # and before #710 the written file failed to parse, so `makemigrations` succeeded and then
  # `dry_run()`/`migrate()` could not load their own output.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a \$ in a default survives makemigrations → load" begin
    price = Models.Model("price_710"; id = Models.IDField(),
                         label = Models.CharField(max_length = 20, default = "R\$ 0,00"))
    plan = PlanOf710()
    Migrations._add_new_table(PFPG710, plan, :price_710, price)
    @test any(s -> occursin("'R\$ 0,00'", s), values(plan[:price_710]))

    _, loaded = _plan_roundtrip_710(plan)
    @test collect.(loaded) == [collect(plan[:price_710])]
    ordered, _ = Migrations._order_statements(loaded)
    @test any(s -> occursin("'R\$ 0,00'", s), ordered)
  end
end
