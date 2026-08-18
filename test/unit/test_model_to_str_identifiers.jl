"""
Unit coverage for `Model_to_str` identifier sanitizing (#317).

`inspectdb` and the Django importer build a model from names read out of a live database or a
Python class, so a field key can be anything the database allows: a Julia keyword (`end`), a
PormG model option (`db_table`), a leading underscore (`_id`), the lookup separator (`a__b`), a
leading digit, punctuation, a quote character.

Before #317 the generator handled exactly one of those — it re-prefixed an underscore for a
"reserved word", which is the very spelling `Model(...)` no longer accepts — and *threw* on the
rest, aborting the entire import on one bad column.

Now every column is renderable: the field gets a legal, collision-free Julia identity and the
real column is pinned with `db_column` (#50). The load-bearing property is the **round trip** —
evaluating the generated file must produce a model addressing the same physical columns.

No live database required.
"""

using Test
using PormG
using PormG.Models: Model, Model_to_str, CharField, IDField, IntegerField, ForeignKey,
                    ManyToManyField, UniqueConstraint, field_db_column, _julia_field_identifier
using PormG: PormGField

const MTS_SETTINGS = PormG.Configuration.Settings()

# One module reused by every round-trip below; `Models` must be bound because the generated text
# says `Models.Model(...)`.
const MTS_MOD = Module(:ModelToStrIdentScratch)
Base.eval(MTS_MOD, :(using PormG))
Base.eval(MTS_MOD, :(const Models = PormG.Models))

_reload(generated::AbstractString) = Base.eval(MTS_MOD, Meta.parse(generated))
_columns(m) = Set(field_db_column(f, k) for (k, f) in m.fields)

@testset "Model_to_str identifier sanitizing (#317)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # The sanitizer in isolation. `raw_keys` is the model's FULL key set (so a rename cannot
  # steal a column that appears later in the sorted iteration) and `taken` accumulates what
  # has already been emitted.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "_julia_field_identifier" begin
    R = PormG.reserved_words
    none = Set{String}()

    # Already legal → kept verbatim, so the common case emits no db_column at all.
    @test _julia_field_identifier("surname",  R, Set{String}(), none) == "surname"
    @test _julia_field_identifier("driverId", R, Set{String}(), none) == "driverId"
    @test _julia_field_identifier("posição",  R, Set{String}(), none) == "posição"
    @test _julia_field_identifier("end_",     R, Set{String}(), none) == "end_"

    # Julia keyword / PormG model option → suffixed.
    @test _julia_field_identifier("end",         R, Set{String}(), none) == "end_"
    @test _julia_field_identifier("function",    R, Set{String}(), none) == "function_"
    @test _julia_field_identifier("db_table",    R, Set{String}(), none) == "db_table_"
    @test _julia_field_identifier("constraints", R, Set{String}(), none) == "constraints_"

    # `id` is NOT a Julia reserved word — it only ever was in PormG's own over-broad list,
    # which is why every generated file used to say `_id`.
    @test _julia_field_identifier("id", R, Set{String}(), none) == "id"

    # Leading underscore stripped; `__` squeezed (it is the lookup separator, illegal in a
    # declared name even though Julia would accept it); punctuation runs collapsed to one `_`.
    @test _julia_field_identifier("_id",   R, Set{String}(), none) == "id"
    @test _julia_field_identifier("a__b",  R, Set{String}(), none) == "a_b"
    @test _julia_field_identifier("a@@b",  R, Set{String}(), none) == "a_b"
    @test _julia_field_identifier("a b c", R, Set{String}(), none) == "a_b_c"

    # A Julia identifier cannot START with a digit — prefix, not suffix.
    @test _julia_field_identifier("2fast", R, Set{String}(), none) == "col_2fast"
    # An all-underscore / all-punctuation name has nothing left to build on.
    @test _julia_field_identifier("___", R, Set{String}(), none) == "col"
    @test _julia_field_identifier("@@",  R, Set{String}(), none) == "col"

    # Collisions resolve with a DIGIT, never another `_` (`end_` + `_` would be `end__`).
    @test _julia_field_identifier("_id", R, Set{String}(), Set(["id", "_id"])) == "id2"
    @test _julia_field_identifier("end", R, Set{String}(), Set(["end", "end_"])) == "end2"
    @test _julia_field_identifier("x",   R, Set(["x"]), none) == "x2"
    @test _julia_field_identifier("x",   R, Set(["x", "x2"]), none) == "x3"
    # Every produced identifier must actually parse as one.
    for c in ["end", "_id", "a__b", "2fast", "___", "@@", "db_table", "a b c"]
      @test Base.isidentifier(_julia_field_identifier(c, R, Set{String}(), none))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # THE load-bearing assertion: generate, evaluate, and compare physical columns. String
  # matching alone cannot establish that the generated file addresses the same table.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "hostile column names round-trip through the generated file" begin
    hostile = Model("mts_hostile_scratch", Dict{String, PormGField}(
      "_id"       => IDField(),
      "id"        => CharField(),
      "end"       => CharField(),
      "end_"      => CharField(),
      "function"  => CharField(),
      "db_table"  => CharField(),
      "a__b"      => CharField(),
      "2fast"     => CharField(),
      "posição"   => CharField(),
      "say \"hi\"" => CharField(),
    ))
    generated = Model_to_str(hostile)
    reloaded  = _reload(generated)

    @test _columns(reloaded) == _columns(hostile)
    @test length(reloaded.fields) == length(hostile.fields)
    # Every generated key is a legal declaration in its own right.
    for k in keys(reloaded.fields)
      @test Base.isidentifier(k)
      @test !startswith(k, "_")
      @test !occursin("__", k)
      @test !(k in PormG.reserved_words)
      @test !(k in PormG.MODEL_OPTION_KWARGS)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `id` is no longer prefixed. This is the change every generated file and nearly every
  # doc example carried: `reserved_words` used to include `id`, which is an ordinary Julia
  # identifier.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an `id` column emits `id`, not `_id`" begin
    m = Model("mts_id_scratch", Dict{String, PormGField}("id" => IDField(), "surname" => CharField()))
    generated = Model_to_str(m)
    @test occursin("\n  id = Models.IDField(", generated)
    @test !occursin("_id = Models.", generated)
    @test !occursin("db_column", generated)   # nothing was renamed, so nothing is pinned
    @test _columns(_reload(generated)) == Set(["id", "surname"])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Anti-clobber: a field that ALREADY carries a db_column has its column stated by the
  # struct. Renaming its Julia identity must not overwrite that — and must not emit a second
  # `db_column=` either, which is a Julia PARSE error (repeated keyword argument), i.e. a
  # generated file that would not load at all.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an existing db_column is not clobbered" begin
    m = Model("mts_clobber_scratch", Dict{String, PormGField}(
      "id"   => IDField(),
      "_foo" => CharField(db_column="bar"),
      "end"  => CharField(db_column=""),      # empty == unset to field_db_column, but != the default
    ))
    generated = Model_to_str(m)
    @test occursin("foo = Models.CharField(db_column=\"bar\")", generated)
    @test !occursin("db_column=\"_foo\"", generated)
    # At most one db_column per rendered field — a repeated keyword argument is a parse error.
    for line in split(generated, "\n")
      @test length(collect(eachmatch(r"db_column=", line))) <= 1
    end
    reloaded = _reload(generated)
    @test field_db_column(reloaded.fields["foo"], "foo") == "bar"
    @test _columns(reloaded) == _columns(m)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A column named after a model option used to emit `db_table = Models.CharField()`, which
  # `Model(...)` peels as the OPTION and then rejects (a field is not a String) — a generated
  # file that threw on reload.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a column named after a model option reloads" begin
    m = Model("mts_option_scratch", Dict{String, PormGField}(
      "id" => IDField(), "db_table" => CharField(), "constraints" => CharField(),
    ))
    generated = Model_to_str(m)
    @test occursin("db_table_ = Models.CharField(db_column=\"db_table\")", generated)
    @test occursin("constraints_ = Models.CharField(db_column=\"constraints\")", generated)
    reloaded = _reload(generated)
    @test reloaded.db_table === nothing          # the OPTION stayed unset
    @test _columns(reloaded) == _columns(m)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # `format_string` escapes, so a quote or a `$` in a live column name cannot break the
  # generated source. `db_table` (#59) shares the same helper.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "quotes and dollars in a column name survive generation" begin
    m = Model("mts_escape_scratch", Dict{String, PormGField}(
      "id" => IDField(), "say \"hi\"" => CharField(), "cost\$usd" => CharField(),
    ))
    generated = Model_to_str(m)
    reloaded  = _reload(generated)
    @test _columns(reloaded) == Set(["id", "say \"hi\"", "cost\$usd"])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A `UniqueConstraint` names its fields by KEY, so renaming a key must carry the constraint with
  # it. Missing this produced a generated file that parsed and then threw on reload —
  # "UniqueConstraint references unknown field 'end'" — which is exactly the class of breakage
  # #317 exists to remove. Reachable from `inspectdb` and the Django importer (`unique_together`).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a UniqueConstraint follows a renamed field" begin
    m = Model("mts_uc_scratch", Dict{String, PormGField}(
      "id" => IDField(), "end" => IntegerField(), "year" => IntegerField(), "_x" => IntegerField(),
    ))
    m.cache["unique_constraints"] = Dict("constraints" => [
      UniqueConstraint(fields = ("end", "year")),
      UniqueConstraint(fields = ("_x",), name = "uq_mts_x"),
    ])
    generated = Model_to_str(m)
    @test occursin("fields = (\"end_\", \"year\",)", generated)
    @test occursin("fields = (\"x\",), name = \"uq_mts_x\"", generated)
    reloaded = _reload(generated)      # threw before the rename map existed
    @test _columns(reloaded) == _columns(m)
    ucs = reloaded.cache["unique_constraints"]["constraints"]
    @test Set(Set(c.fields) for c in ucs) == Set([Set(["end_", "year"]), Set(["x"])])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The MODEL name has the same hostile-input surface as a field name: `inspectdb` reads it from a
  # live table, and both the generated binding and the positional string literal are built from it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset for name in ["we\"ird", "2fast", "driver profile", "cost\$usd", "_", "___", "end", "db_table"]
    m = Model(name, Dict{String, PormGField}("id" => IDField()))
    generated = Model_to_str(m; name_is_physical_table = true)
    reloaded  = _reload(generated)
    # The physical table is preserved verbatim, pinned as db_table where the positional slot
    # could not carry it. (`_`/`___` used to emit a positional `_`, which the #306 guard rejects.)
    @test PormG.model_table_name(reloaded) == name
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The generated BINDING and a child's `ForeignKey` `.to` must be the SAME expression:
  # `_resolve_target_model` resolves a String `.to` by binding lookup alone, with no name or table
  # fallback. Sanitizing the binding unconditionally broke that for every table name
  # `uppercasefirst` already made legal — `end` → `End_` while `.to` stayed `"End"`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the generated binding matches a child's ForeignKey target" begin
    for parent in ["driver", "_order", "end", "db_table", "constraints", "Driver_Profile"]
      m = Model(parent, Dict{String, PormGField}("id" => IDField()))
      binding = first(split(Model_to_str(m; name_is_physical_table = true), " = "))
      # What `inspectdb` writes into a child's `.to` for this parent table.
      @test binding == uppercasefirst(parent)
    end
    # And it is still a legal, READABLE binding for names `uppercasefirst` alone cannot rescue.
    #
    # Readability is a separate requirement from legality: `Base.isidentifier("_")` is `true`, but an
    # all-underscore identifier is write-only in Julia — assigning it works and reading it raises
    # `UndefVarError`, so the model would be permanently invisible to every binding-based lookup with
    # no error anywhere. Asserted on the emitted string rather than by evaluating and reading it
    # back, because a binding created by `eval` is not visible to a read in the same world age
    # (Julia 1.12), which would make the check pass for the wrong reason.
    for parent in ["2fast", "driver profile", "we\"ird", "_", "__", "___"]
      m = Model(parent, Dict{String, PormGField}("id" => IDField()))
      binding = first(split(Model_to_str(m; name_is_physical_table = true), " = "))
      @test Base.isidentifier(binding)
      @test !isempty(lstrip(binding, '_'))
    end
    # #360 strengthens the above from "legal" to a NAMED string, so a child's `.to` can be checked
    # against something other than the expression that produced it. Written out literally on
    # purpose: asserting `binding == _model_binding_name(parent)` would be `f(x) == f(x)` — it is
    # the very call `Model_to_str` makes, so it cannot fail and proves nothing.
    for (parent, expected) in ["2fast" => "Col_2fast", "driver profile" => "Driver_profile",
                               "we\"ird" => "We_ird", "_" => "Col", "__" => "Col", "___" => "Col"]
      m = Model(parent, Dict{String, PormGField}("id" => IDField()))
      @test first(split(Model_to_str(m; name_is_physical_table = true), " = ")) == expected
    end
  end

  # The language rule the assertion above encodes, pinned directly so it is not folklore.
  @testset "an all-underscore identifier is write-only in Julia" begin
    m = Module(:MtsUnderscoreBindingScratch)
    Base.eval(m, :(_ = 5))
    Base.eval(m, :(_ok = 5))
    @test_throws UndefVarError getfield(m, :_)
    @test getfield(m, :_ok) == 5     # a NON-all-underscore name is readable
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A ForeignKey's `.to` is a live parent TABLE name on the inspectdb path, so it needs the same
  # escaping as any other string in the generated source.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a hostile ForeignKey target survives generation" begin
    child = Model("mts_fk_child_scratch", Dict{String, PormGField}(
      "id" => IDField(), "parent_id" => ForeignKey("We\"ird", pk_field = "id"),
    ))
    generated = Model_to_str(child)
    reloaded  = _reload(generated)           # ParseError before the .to site was escaped
    @test reloaded.fields["parent_id"].to == "We\"ird"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A constraint over a field that never reached the output cannot be declared — on reload
  # `_apply_unique_constraints!` rejects it and the whole file fails. Same unloadable-file class as
  # the rename case above, reached through the #70 render-failure path instead.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "a UniqueConstraint over an unrendered field is dropped with a marker" begin
    m = Model("mts_ucdrop_scratch", Dict{String, PormGField}(
      "id" => IDField(), "year" => IntegerField(), "_teams" => ManyToManyField("Team"),
    ))
    # `_teams` needs renaming, and an M2M cannot be renamed (no db_column, and its name feeds the
    # join-table name), so it takes the `continue` path and never reaches the output.
    m.cache["unique_constraints"] = Dict("constraints" => [
      UniqueConstraint(fields = ("_teams", "year")),
      UniqueConstraint(fields = ("year",), name = "uq_mts_year"),
    ])
    generated = @test_logs (:warn,) (:warn,) match_mode=:any Model_to_str(m)
    @test occursin("# PormG: UniqueConstraint over (_teams, year) could not be rendered", generated)
    @test !occursin("fields = (\"_teams\"", generated)
    @test occursin("name = \"uq_mts_year\"", generated)   # the healthy one still ships
    reloaded = _reload(generated)
    ucs = reloaded.cache["unique_constraints"]["constraints"]
    @test length(ucs) == 1
    @test Set(ucs[1].fields) == Set(["year"])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # A ManyToManyField carries no db_column, and its field name feeds the derived join-table
  # name — so a rename would be lossy and unrecorded. It takes the #70 render-failure path
  # instead: marker comment + @warn, never a silent rename.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "an unrenderable ManyToManyField is reported, not silently renamed" begin
    m = Model("mts_m2m_scratch", Dict{String, PormGField}(
      "id" => IDField(), "_teams" => ManyToManyField("Team"),
    ))
    generated = @test_logs (:warn,) match_mode=:any Model_to_str(m)
    @test occursin("# PormG: field '_teams' (ManyToManyField) could not be rendered", generated)
    @test !occursin("teams = Models.ManyToManyField", generated)
    # A legal M2M name still renders normally.
    ok = Model("mts_m2m_ok_scratch", Dict{String, PormGField}(
      "id" => IDField(), "teams" => ManyToManyField("Team"),
    ))
    @test occursin("teams = Models.ManyToManyField(\"Team\")", Model_to_str(ok))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # #338: every test above calls `Model_to_str` ONCE, so its default fresh `taken`/`taken_names`
  # sets never see a collision. A real importer call site shares ONE pair of sets across every
  # model it renders into the same generated file — that is what these tests do. Without the fix,
  # the SECOND `Binding = Models.Model(...)` line silently overwrites the first Julia global when
  # the generated file is `include`d: no error, no warning, one model just vanishes.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "cross-model binding/name collisions are disambiguated, not silently shadowed (#338)" begin

    # "driver profile" sanitizes to `Driver_profile`; "driver_profile" is already legal and
    # `uppercasefirst`s to the SAME string.
    @testset "driver profile / driver_profile" begin
      taken_bindings = Set{String}()
      taken_names = Set{String}()
      m1 = Model("driver profile", Dict{String, PormGField}("id" => IDField()))
      m2 = Model("driver_profile", Dict{String, PormGField}("id" => IDField()))
      g1 = Model_to_str(m1; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
      g2 = Model_to_str(m2; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
      b1 = first(split(g1, " = "))
      b2 = first(split(g2, " = "))
      @test b1 == "Driver_profile"
      @test b2 != b1 && Base.isidentifier(b2)   # the whole point — no shared binding
      r1 = _reload(g1)
      r2 = _reload(g2)
      @test PormG.model_table_name(r1) == "driver profile"
      @test PormG.model_table_name(r2) == "driver_profile"
      # Neither shadowed the other — both bindings independently resolve to their own model.
      @test getfield(MTS_MOD, Symbol(b1)).name == "driver profile"
      @test getfield(MTS_MOD, Symbol(b2)).name == "driver_profile"
    end

    # A live table literally named "models" collides with the generated file's OWN
    # `import PormG.Models` line, not with a sibling model — the seed, not another call, catches it.
    @testset "a table named models collides with the generated import" begin
      taken_bindings = Set{String}(PormG.GENERATED_MODULE_RESERVED_BINDINGS)
      taken_names = Set{String}()
      m = Model("models", Dict{String, PormGField}("id" => IDField()))
      generated = Model_to_str(m; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
      binding = first(split(generated, " = "))
      @test binding == "Models2"          # not "Models" — would shadow `import PormG.Models`
      @test PormG.model_table_name(_reload(generated)) == "models"
    end

    # All-underscore tables all sanitize to the same positional name "col" — three of them must not
    # all collapse to one.
    @testset "an all-underscore trio gets three distinct positional names" begin
      taken_bindings = Set{String}()
      taken_names = Set{String}()
      positions = String[]
      for tbl in ["_", "__", "___"]
        m = Model(tbl, Dict{String, PormGField}("id" => IDField()))
        generated = Model_to_str(m; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
        @test PormG.model_table_name(_reload(generated)) == tbl   # db_table is always pinned on this branch
        push!(positions, something(match(r"Models\.Model\(\"([^\"]*)\"", generated)).captures[1])
      end
      @test length(positions) == length(Set(positions))
    end

    # THE TRAP: dedup on the positional name must not just invent "driver2" and walk away — that
    # string can BE the physical table (`model_table_name` falls back to it whenever `db_table` is
    # unset). A naive unconditional dedup would leave this model loading cleanly while querying a
    # table that does not exist — worse than the shadowing bug #338 reports. "Driver" is processed
    # FIRST (mixed-case ⇒ `db_table` already pinned to "Driver", positional slot "driver"); "driver"
    # is processed SECOND and collides on both the binding ("Driver") and the positional name
    # ("driver") — it must come out re-pinned, not silently wrong.
    @testset "positional-name dedup re-pins db_table instead of inventing a nonexistent table" begin
      taken_bindings = Set{String}()
      taken_names = Set{String}()
      m1 = Model("Driver", Dict{String, PormGField}("id" => IDField()))
      m2 = Model("driver", Dict{String, PormGField}("id" => IDField()))
      g1 = Model_to_str(m1; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
      g2 = Model_to_str(m2; name_is_physical_table=true, taken_bindings=taken_bindings, taken_names=taken_names)
      @test occursin("Driver = Models.Model(\"driver\"", g1)
      @test occursin("db_table = \"Driver\"", g1)
      @test occursin("Driver2 = Models.Model(\"driver2\"", g2)    # binding ALSO collided — suffixed too
      @test occursin("db_table = \"driver\"", g2)                 # re-pinned to the pre-dedup name
      @test PormG.model_table_name(_reload(g2)) == "driver"       # NOT "driver2"
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # #360: the two mechanics that let an importer decide bindings BEFORE rendering, so a child's
  # `.to` can name the target's FINAL (possibly digit-suffixed) binding rather than a guess.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "Model_to_str accepts a precomputed binding and never emits to_table (#360)" begin

    # The importers resolve every binding in a pass 1, then hand each one back here. Passing it is
    # what keeps the derivation SINGLE — the alternative (a second loop re-deriving the same string)
    # is exactly the drift `_model_binding_name`'s docstring warns about, and here that drift would
    # mean a foreign key silently addressing a different model.
    @testset "a caller-supplied binding is emitted verbatim" begin
      m = Model("driver_profile", Dict{String, PormGField}("id" => IDField()))
      g = Model_to_str(m; name_is_physical_table = true, binding = "Driver_profile2")
      @test occursin("Driver_profile2 = Models.Model(\"driver_profile\"", g)
      # The POSITIONAL name and `db_table` are untouched by the binding override — only the Julia
      # handle moved, so the model still addresses its own real table.
      @test PormG.model_table_name(_reload(g)) == "driver_profile"
    end

    # Omitting it must reproduce the old behaviour exactly, since every non-importer caller does.
    @testset "omitting it derives the binding as before" begin
      m = Model("driver_profile", Dict{String, PormGField}("id" => IDField()))
      @test Model_to_str(m; name_is_physical_table = true) ==
            Model_to_str(m; name_is_physical_table = true, binding = "Driver_profile")
    end

    # `to_table` is an in-memory breadcrumb only. `ForeignKey` accepts no such kwarg, so emitting it
    # would make `_common_kwargs` warn and discard it on every reload — noise for a value nothing
    # reads. The `!occursin` assertion is what pins the `sfield === :to_table` skip in
    # `_model_to_str_foreign_key`: drop the skip and the field renders `to_table="driver profile"`.
    # (Reloading is NOT a gate — an unexpected kwarg is warned about and ignored, not thrown on — so
    # the reload here only checks that the rest of the rendering survived the skip.)
    @testset "to_table is never rendered" begin
      fk = ForeignKey("Driver_profile", pk_field = "id", null = true)
      fk.to_table = "driver profile"
      m = Model("pit_stop", Dict{String, PormGField}("id" => IDField(), "profile_id" => fk))
      g = Model_to_str(m; name_is_physical_table = true)
      @test !occursin("to_table", g)
      @test occursin("Models.ForeignKey(\"Driver_profile\"", g)
      reloaded = _reload(g)
      @test reloaded.fields["profile_id"].to == "Driver_profile"
      @test reloaded.fields["profile_id"].to_table === nothing
    end

    # The round-trip branch: a `.to` that has already been resolved to a model object (set_models and
    # the migration prelude both write it back) serializes through `_model_binding_name`, not bare
    # `uppercasefirst`. Before #360 a parent whose name needed sanitizing round-tripped to a `.to`
    # naming a binding that cannot exist — `"Driver profile"` for a model bound as `Driver_profile`.
    @testset "a resolved-model .to serializes to the target's real binding" begin
      parent = Model("driver profile", Dict{String, PormGField}("id" => IDField()))
      fk = ForeignKey(parent, pk_field = "id", null = true)
      m = Model("pit_stop", Dict{String, PormGField}("id" => IDField(), "profile_id" => fk))
      g = Model_to_str(m; name_is_physical_table = true)

      parent_binding = first(split(Model_to_str(parent; name_is_physical_table = true), " = "))
      @test occursin("Models.ForeignKey(\"$(parent_binding)\"", g)
      # Stated concretely too, so the assertion above cannot pass by comparing two equally-wrong
      # strings: it is the sanitized binding, not `uppercasefirst("driver profile")`.
      @test occursin("Models.ForeignKey(\"Driver_profile\"", g)
      @test !occursin("Driver profile", g)
    end
  end

end
