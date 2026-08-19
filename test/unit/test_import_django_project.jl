using Test
using Logging
using PormG
using PormG.Migrations

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): multi-app projects
#
# `import_models_from_django` used to take ONE models.py. A real Django project splits its models
# across apps, and two things broke at the seam:
#
#   1. cross-app targets (`ForeignKey("core.Pessoa")`, `settings.AUTH_USER_MODEL`) reached the
#      generated file verbatim and threw at `set_models` — `_resolve_target_model` is a BINDING
#      lookup in one module and nothing else;
#   2. one connection-level `django_prefix` could not express three app labels, which is what #345
#      moved into per-model `db_table`.
#
# The whole project is emitted into ONE module, because PormG is structurally one models file per
# DATABASE: `makemigrations`/`migrate` resolve a single `joinpath(db, settings.model_file)` and load
# it into a single module. One module per app would not merely be unsupported — it would be
# invisible to the migration engine.
# ─────────────────────────────────────────────────────────────────────────────

const DJANGO_PROJECT_ROOT = joinpath(@__DIR__, "fixtures", "django_project")

django_project_app(label) = joinpath(DJANGO_PROJECT_ROOT, label, "models.py")

"""
    project_config!(; django_prefix = nothing) -> (config_key, db_dir_existed)

A throwaway config keyed on a fresh temp directory. Mirrors `temp_import_config!` in
`test_import_django_models.jl`; kept local so this file runs standalone.
"""
function project_config!(; django_prefix::Union{Nothing, String} = nothing)
    config_key = mktempdir()
    db_dir_existed = isdir(PormG.MODEL_PATH)
    PormG.config[config_key] = PormG.Configuration.Settings(
        db_def_folder = config_key,
        django_prefix = django_prefix,
    )
    return config_key, db_dir_existed
end

function cleanup_project_test!(config_key, db_dir_existed)
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
    if !db_dir_existed && isdir(PormG.MODEL_PATH) && isempty(readdir(PormG.MODEL_PATH))
        rm(PormG.MODEL_PATH)
    end
end

"""
    import_project(pairs; kwargs...) -> (generated_text, config_key, db_dir_existed)

Import `pairs` under a throwaway config and return the generated source. Callers must
`cleanup_project_test!(config_key, db_dir_existed)` in a `finally`.
"""
function import_project(pairs; output_file::String = "django_project_unit.jl",
                        django_prefix::Union{Nothing, String} = nothing, kwargs...)
    config_key, db_dir_existed = project_config!(django_prefix = django_prefix)
    import_models_from_django(pairs; db = config_key, file = output_file, force_replace = true,
                              kwargs...)
    return read(joinpath(config_key, output_file), String), config_key, db_dir_existed
end

# The three-app fixture project, in the order a maintainer would list it.
const DJANGO_PROJECT_PAIRS = ["racing"  => django_project_app("racing"),
                              "access"  => django_project_app("access"),
                              "imports" => django_project_app("imports")]

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the generated project module is loadable Julia whose
# cross-app relations actually resolve.
#
# This is the highest-value test in the file and everything else is downstream of it: rendering the
# right strings proves nothing if the module does not evaluate, and evaluating proves nothing about
# #346 unless the FK targets resolve by BINDING lookup the way `set_models` resolves them. That
# lookup — `getfield(mod, Symbol(field.to))` — is exactly what a cross-app reference used to fail.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits a loadable multi-app module whose cross-app FKs resolve (#346)" begin
    generated, config_key, db_dir_existed = import_project(DJANGO_PROJECT_PAIRS;
                                                           output_file = "django_project_load.jl")
    try
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        # Bindings defined during this call are newer than this frame's world age, so they are read
        # back through `Core.eval` rather than `getfield` (same reason as the single-app eval tests).
        models_module = Core.eval(sandbox, :(django_project_load))
        modelof(sym) = Core.eval(sandbox, :(django_project_load.$sym))

        # Every app's models are in the one module.
        for binding in (:Circuit, :Racing_driver, :Race, :Lap, :User, :Access_driver,
                        :ImportBatch, :ImportRow)
            @test Core.eval(sandbox, :(isdefined(django_project_load, $(QuoteNode(binding)))))
        end

        # THE assertion: every FK/O2O target in the whole project resolves to a real model by the
        # binding lookup `set_models` performs. A single unresolved one is a file that throws on
        # load in the consuming app.
        unresolved = String[]
        for binding in (:Circuit, :Racing_driver, :Race, :Lap, :User, :Access_driver,
                        :ImportBatch, :ImportRow)
            model = modelof(binding)
            for (field_name, field) in model.fields
                hasproperty(field, :to) || continue
                target = Base.invokelatest(PormG.Models._resolve_target_model, field.to, models_module)
                target === nothing && push!(unresolved, "$(binding).$(field_name) -> $(field.to)")
            end
        end
        @test isempty(unresolved)

        # Cross-app, spelled Django's way: `racing.Race.steward` -> `access.User`.
        @test modelof(:Race).fields["steward_id"].to == "User"
        # `settings.AUTH_USER_MODEL`, auto-detected as the single AbstractUser subclass.
        @test modelof(:Race).fields["reported_by_id"].to == "User"
        # Self-referential FK: `"self"` used to reach the file verbatim and throw at set_models.
        @test modelof(:Racing_driver).fields["mentor_id"].to == "Racing_driver"
        # A bare name that two apps define resolves in the DECLARING app, as Django does.
        @test modelof(:Lap).fields["driver_id"].to == "Racing_driver"
        # A bare name unique across the project resolves globally.
        @test modelof(:ImportBatch).fields["steward_id"].to == "User"

        # Models appear in the order the apps were listed, and in class order within each app.
        # Rendering is DEFERRED — models are built first so the ManyToMany join-column pass can read
        # both ends of a relation — and it is the reserved slot, not the render loop, that keeps
        # source order. Asserted because that is the property a future refactor would quietly lose.
        positions = [findfirst(binding * " = Models.Model(", generated)
                     for binding in ("Circuit", "Racing_driver", "Race", "Lap",
                                     "User", "Access_driver", "ImportBatch", "ImportRow")]
        @test all(!isnothing, positions)
        @test issorted([first(p) for p in positions])

        # Physical tables carry each model's own app label, so one file holds every app's tables.
        @test PormG.model_table_name(modelof(:Circuit)) == "racing_circuit"
        @test PormG.model_table_name(modelof(:User)) == "access_user"
        @test PormG.model_table_name(modelof(:ImportBatch)) == "imports_importbatch"
        # ...and `Meta.db_table` still overrides the app label, exactly as in Django.
        @test PormG.model_table_name(modelof(:Race)) == "f1_race_legacy"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a class name claimed by two apps qualifies BOTH
#
# `racing.Driver` and `access.Driver` cannot both be `Driver`. Renaming only the second would make
# the output depend on the order the apps were listed, and `set_models` keys a reverse accessor on
# `lowercase(model.name)` — so one model would answer to `driver` and the other to `driver2`,
# decided by list order. Qualifying both says which is which.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer app-qualifies every side of a cross-app class-name collision (#346)" begin
    generated, config_key, db_dir_existed = import_project(DJANGO_PROJECT_PAIRS;
                                                           output_file = "django_project_clash.jl")
    try
        # Both bindings, both logical names, both tables — app-qualified on both sides.
        @test occursin("Racing_driver = Models.Model(\"racing_driver\", db_table = \"racing_driver\"", generated)
        @test occursin("Access_driver = Models.Model(\"access_driver\", db_table = \"access_driver\"", generated)
        # Neither survives as the bare name, and #338's digit backstop never runs.
        @test !occursin("\nDriver = Models.Model(", generated)
        @test !occursin("Driver2", generated)
        @test !occursin("driver2", generated)

        # A class name only ONE app declares is untouched — qualification is for collisions, not a
        # blanket rename. `Circuit`, `Race` and `ImportBatch` keep their Python spelling.
        @test occursin("Circuit = Models.Model(\"circuit\"", generated)
        @test !occursin("Racing_circuit", generated)
        @test occursin("ImportBatch = Models.Model(\"importbatch\"", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): ManyToMany join columns follow the CLASS, not our handle
#
# Django names a join-table column `<model_name>_id` — the lowercased CLASS name. PormG's
# `_many_to_many_column_name` derives it from `model.name`, so the two agree for free while the
# emitted name IS the class name, and stop agreeing the moment a collision rename moves it. Pinned
# exactly then, and never speculatively.
#
# The self-referential case is the one where Django does not use `<model>_id` at all: one table
# cannot carry the same column twice, so it names the ends `from_<model>_id` / `to_<model>_id`.
# Before #346 this was unreachable — `ManyToManyField("self")` died at `set_models` — and would
# otherwise now become a join table with one column doing two jobs.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer pins ManyToMany join columns only where they would drift (#346)" begin
    generated, config_key, db_dir_existed = import_project(DJANGO_PROJECT_PAIRS;
                                                           output_file = "django_project_m2m.jl")
    try
        # Owner and target both keep their class names -> PormG's derivation already agrees with
        # Django's (`importbatch_id` / `circuit_id`), so nothing is pinned.
        @test occursin("circuits = Models.ManyToManyField(\"Circuit\", related_name=\"import_batches\", db_table=\"imports_importbatch_circuits\")", generated)

        # The TARGET was renamed by the collision, so its column would have become `racing_driver_id`
        # while Django created `driver_id`. Pinned — and the source side, whose owner was not
        # renamed, deliberately is not.
        @test occursin("drivers = Models.ManyToManyField(\"Racing_driver\", db_table=\"imports_importbatch_drivers\", target_field=\"driver_id\")", generated)
        @test !occursin("source_field=\"importbatch_id\"", generated)

        # Self-referential M2M: Django's from_/to_ spelling, derived from the CLASS name even though
        # this model was renamed to `racing_driver`.
        @test occursin("teammates = Models.ManyToManyField(\"Racing_driver\", db_table=\"racing_driver_teammates\", source_field=\"from_driver_id\", target_field=\"to_driver_id\")", generated)
        @test !occursin("from_racing_driver_id", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a target outside the imported app set degrades, it does not vanish
#
# Any project that touches `django.contrib` has targets this import cannot name. Hard-erroring on
# them would make the importer unusable there, so the COLUMN survives — it is real, Django created
# it — and only the relation metadata is lost, said out loud in the artifact. `strict_relations`
# is the opt-in for the other policy.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer degrades an unresolvable relation and says so (#346)" begin
    generated, config_key, db_dir_existed = import_project(DJANGO_PROJECT_PAIRS;
                                                           output_file = "django_project_degrade.jl")
    try
        # The column, as a plain integer, under its real name — and keeping the shape Django gave
        # it. `db_index` is not decoration: Django indexes every FK column, so dropping the flag
        # would leave the model claiming an index the database has and the next `makemigrations`
        # proposing to drop it.
        degraded = first(filter(l -> occursin("created_by_id =", l), split(generated, '\n')))
        @test occursin("Models.BigIntegerField(", degraded)
        @test occursin("null=true", degraded)
        @test occursin("blank=true", degraded)
        @test occursin("db_index=true", degraded)
        @test !occursin("ForeignKey", degraded)
        @test !occursin("ForeignKey(\"contenttypes.ContentType\"", generated)
        # The marker names the field, the class, the target and the consequence.
        @test occursin("# PormG: field 'created_by_id' on 'imports.ImportBatch' — ForeignKey target " *
                       "'contenttypes.ContentType' is not in the imported app set; imported as a " *
                       "plain column, the relation is lost.", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a degraded column keeps its SHAPE, not just its nullability
#
# `OneToOneField` is a unique column — PormG's constructor defaults `unique = true, db_index = true`.
# Degrading it to a bare nullable bigint would emit a column the database has a UNIQUE constraint on
# and the model says nothing about, so the next `makemigrations` would propose DROPPING that
# constraint. Silent, destructive, and two steps removed from the import that caused it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a degraded relation keeps unique/db_index/default, and a PK relation is refused (#346)" begin
    source = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)
    # OneToOne to a model outside the import: unique + indexed, and nullable.
    profile = models.OneToOneField('extras.CircuitProfile', on_delete=models.SET_NULL, null=True,
                                   blank=True)
    # A plain FK carrying a db_index and a default.
    owner = models.ForeignKey('extras.Owner', on_delete=models.SET_DEFAULT, default=1,
                              db_column='owner_ref')
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "degrade_shape.jl")
    try
        # The O2O keeps its uniqueness. Without this the schema and the model disagree.
        @test occursin("profile_id = Models.BigIntegerField(", generated)
        profile_line = first(filter(l -> occursin("profile_id =", l), split(generated, '\n')))
        @test occursin("unique=true", profile_line)
        @test occursin("null=true", profile_line)
        @test occursin("blank=true", profile_line)

        owner_line = first(filter(l -> occursin("owner_id =", l), split(generated, '\n')))
        @test occursin("default=1", owner_line)
        @test occursin("db_column=\"owner_ref\"", owner_line)

        # The file still loads, and the degraded columns really are unique/indexed on the model.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        circuit = Core.eval(sandbox, :(degrade_shape.Circuit))
        @test circuit.fields["profile_id"].unique
        @test !circuit.fields["owner_id"].unique
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # Django's shared-primary-key pattern pointed outside the import. There is nowhere to degrade to:
    # the fallback column type cannot be a primary key, and the implicit `id` was already decided —
    # this field still counted as the key then — so none is synthesized to replace it. The model
    # would come out with NO primary key, which
    # breaks `save()`, every M2M touching it, and the planner. A hard error even when
    # `strict_relations` is off.
    pk_relation = """
from django.db import models

class CircuitDetail(models.Model):
    circuit = models.OneToOneField('extras.Circuit', on_delete=models.CASCADE, primary_key=True)
    notes = models.TextField()
"""
    config_key2, existed2 = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["racing" => pk_relation]; db = config_key2,
                                      file = "pk_degrade.jl", force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("primary key", msg)
        @test occursin("circuit_id", msg)
        @test !isfile(joinpath(config_key2, "pk_degrade.jl"))
    finally
        cleanup_project_test!(config_key2, existed2)
    end
end

# An unlabelled single-app import cannot match an app-qualified reference against anything — it does
# not know its own app label, so `"racing.Circuit"` is as foreign as `"auth.Permission"` even when
# `Circuit` is declared three lines up. The marker has to name the keyword that fixes it, or the
# reader is left staring at a class the file plainly defines.
@testset "an app-qualified target in an unlabelled import points at django_prefix (#346)" begin
    source = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)

class Race(models.Model):
    circuit = models.ForeignKey('racing.Circuit', on_delete=models.CASCADE)
"""
    config_key, db_dir_existed = project_config!(django_prefix = nothing)
    try
        import_models_from_django(source; db = config_key, file = "no_label.jl",
                                  force_replace = true)
        generated = read(joinpath(config_key, "no_label.jl"), String)
        @test occursin("circuit_id = Models.BigIntegerField(", generated)
        @test occursin("sets no Django app label", generated)
        @test occursin("django_prefix = \"racing\"", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # ...and with the label configured, the same file resolves instead of degrading.
    config_key2, existed2 = project_config!(django_prefix = "racing")
    try
        import_models_from_django(source; db = config_key2, file = "with_label.jl",
                                  force_replace = true)
        generated = read(joinpath(config_key2, "with_label.jl"), String)
        @test occursin("circuit_id = Models.ForeignKey(\"Circuit\"", generated)
        @test !occursin("BigIntegerField", generated)
    finally
        cleanup_project_test!(config_key2, existed2)
    end
end

# A ManyToManyField has no column of its own, so there is nothing to degrade TO: an unresolvable
# target leaves the relation with no table, no columns and no meaning. It is dropped and marked —
# the one place this importer removes something rather than keeping a diminished version of it.
@testset "an unresolvable ManyToMany target is dropped, not kept (#346)" begin
    source = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)
    tags = models.ManyToManyField('taxonomy.Tag')
    permissions = models.ManyToManyField('auth.Permission', related_name='circuits')
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "m2m_target_missing.jl")
    try
        # Neither relation survives in any form — keeping one would emit a `ManyToManyField` whose
        # target is a string no binding in the file matches, which throws at `set_models`.
        @test !occursin("tags = Models.ManyToManyField", generated)
        @test !occursin("permissions = Models.ManyToManyField", generated)
        # The target name survives only inside the marker, never as a live declaration. (The earlier
        # spelling of this — `!occursin("taxonomy.Tag") || occursin("# PormG:")` — could not fail:
        # the name DOES appear in the marker, so the first half was always false and the second is
        # true for essentially any output of this importer.)
        @test !occursin("ManyToManyField(\"taxonomy.Tag\"", generated)
        # ...and each one is reported on its own, naming its own target.
        @test occursin("ManyToManyField target 'taxonomy.Tag' is not in the imported app set", generated)
        @test occursin("ManyToManyField target 'auth.Permission' is not in the imported app set", generated)
        @test occursin("the relation is DROPPED", generated)

        # The model, and every column it really has, is untouched.
        @test occursin("Circuit = Models.Model(\"circuit\", db_table = \"racing_circuit\"", generated)
        @test occursin("name = Models.CharField(max_length=120)", generated)

        # And the file still loads — a dropped relation must not leave a dangling reference.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Core.eval(sandbox, :(isdefined(m2m_target_missing, :Circuit)))
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

@testset "strict_relations turns every degrade into an error (#346)" begin
    config_key, db_dir_existed = project_config!()
    try
        err = nothing
        try
            import_models_from_django(DJANGO_PROJECT_PAIRS; db = config_key,
                                      file = "django_project_strict.jl", force_replace = true,
                                      strict_relations = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("contenttypes.ContentType", msg)
        @test occursin("strict_relations", msg)
        # It fails BEFORE writing anything: a half-written module is worse than none.
        @test !isfile(joinpath(config_key, "django_project_strict.jl"))
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): settings.AUTH_USER_MODEL
#
# The ONE hard relation error. Everything else degrades, because a project can legitimately
# reference apps it did not import — but `AUTH_USER_MODEL` is referenced by nearly every model in a
# real project, so one omitted keyword would quietly turn the whole user graph into integer columns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "settings.AUTH_USER_MODEL auto-detects the single AbstractUser subclass (#346)" begin
    generated, config_key, db_dir_existed = import_project(DJANGO_PROJECT_PAIRS;
                                                           output_file = "django_project_auth.jl")
    try
        @test occursin("reported_by_id = Models.ForeignKey(\"User\"", generated)
        @test !occursin("settings.AUTH_USER_MODEL", generated)
        @test !occursin("AUTH_USER_MODEL", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

@testset "an ambiguous or absent AUTH_USER_MODEL is a hard error naming the candidates (#346)" begin
    # TWO AbstractUser subclasses and a reference to the alias: the importer cannot choose.
    two_users = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    matricula = models.CharField(max_length=20)

class Operator(AbstractUser):
    crachá = models.CharField(max_length=20)
"""
    referencing = """
from django.conf import settings
from django.db import models

class Race(models.Model):
    reported_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
"""

    config_key, db_dir_existed = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["access" => two_users, "racing" => referencing];
                                      db = config_key, file = "auth_ambiguous.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        # Both candidates are NAMED — a count alone leaves the user hunting for them.
        @test occursin("access.User", msg)
        @test occursin("access.Operator", msg)
        @test occursin("auth_user_model", msg)

        # Naming one explicitly resolves it, and it is spelled the way Django spells it in settings.
        import_models_from_django(["access" => two_users, "racing" => referencing];
                                  db = config_key, file = "auth_explicit.jl",
                                  force_replace = true, auth_user_model = "access.Operator")
        explicit = read(joinpath(config_key, "auth_explicit.jl"), String)
        @test occursin("reported_by_id = Models.ForeignKey(\"Operator\"", explicit)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # ZERO candidates and a reference is the same error — a project that swapped in a user model
    # from an app it did not import gets told so, rather than silently losing every user relation.
    config_key2, existed2 = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["racing" => referencing]; db = config_key2,
                                      file = "auth_none.jl", force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("no imported class inherits AbstractUser", sprint(showerror, err))
    finally
        cleanup_project_test!(config_key2, existed2)
    end

    # ...but a project that never mentions the alias is fine with zero or two candidates.
    config_key3, existed3 = project_config!()
    try
        import_models_from_django(["access" => two_users]; db = config_key3,
                                  file = "auth_unused.jl", force_replace = true)
        @test occursin("User = Models.Model(\"user\"", read(joinpath(config_key3, "auth_unused.jl"), String))
    finally
        cleanup_project_test!(config_key3, existed3)
    end

    # An `auth_user_model` naming nothing is EITHER a typo or a stock-Django project pointing at
    # `auth.User`, and the importer cannot tell them apart — both name a model this import does not
    # have. So it is not an error (that would lock stock Django out entirely, see the dedicated
    # testset below) and it is not silent either: a `@warn` up front, and a `# PormG:` marker on
    # every relation it governs, each naming the model that was not found.
    config_key4, existed4 = project_config!()
    try
        generated = @test_logs (:warn, r"auth_user_model names no imported model") match_mode=:any begin
            import_models_from_django(["access" => two_users, "racing" => referencing];
                                      db = config_key4, file = "auth_typo.jl",
                                      force_replace = true, auth_user_model = "access.Usuario")
            read(joinpath(config_key4, "auth_typo.jl"), String)
        end
        @test occursin("'access.Usuario' is not in the imported app set", generated)
        @test occursin("reported_by_id = Models.BigIntegerField(", generated)
    finally
        cleanup_project_test!(config_key4, existed4)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): an unqualified name two apps define is ambiguous
#
# Django's own rule: an unqualified lazy reference resolves in the declaring app, then must be
# unique. Picking one of two arbitrarily would compile and read the wrong table.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an ambiguous bare relation target is rejected, naming both apps (#346)" begin
    left = """
from django.db import models

class Driver(models.Model):
    forename = models.CharField(max_length=60)
"""
    right = """
from django.db import models

class Driver(models.Model):
    badge = models.CharField(max_length=20)
"""
    referencing = """
from django.db import models

class Lap(models.Model):
    driver = models.ForeignKey('Driver', on_delete=models.CASCADE)
"""

    config_key, db_dir_existed = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["racing" => left, "access" => right, "imports" => referencing];
                                      db = config_key, file = "ambiguous.jl", force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("racing.Driver", msg)
        @test occursin("access.Driver", msg)
        @test occursin("ambiguous", msg)
        # The message says WHAT was ambiguous. The same lookup also resolves `auth_user_model` and
        # `binding_overrides` keys, and calling one of those a "relation target" would send the
        # reader looking at their models instead of at the keyword they typed.
        @test occursin("relation target", msg)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # The other two callers of the same lookup, each naming itself.
    config_key2, existed2 = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["racing" => left, "access" => right]; db = config_key2,
                                      file = "ambiguous_override.jl", force_replace = true,
                                      binding_overrides = Dict("Driver" => "TheDriver"))
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("binding_overrides key", sprint(showerror, err))

        auth_pair = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class Driver(AbstractUser):
    badge = models.CharField(max_length=20)
"""
        err = nothing
        try
            import_models_from_django(["racing" => left, "access" => auth_pair]; db = config_key2,
                                      file = "ambiguous_auth.jl", force_replace = true,
                                      auth_user_model = "Driver")
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("auth_user_model", sprint(showerror, err))
    finally
        cleanup_project_test!(config_key2, existed2)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): binding_overrides
#
# The auto-qualified `Racing_driver` / `Access_driver` is correct but not always what you want to
# type. Every rejection below is a hard error rather than a fallback: an override is an explicit
# instruction, and one that silently does something else is worse than none.
# ─────────────────────────────────────────────────────────────────────────────
@testset "binding_overrides renames a model, and every invalid override is rejected (#346)" begin
    generated, config_key, db_dir_existed = import_project(
        DJANGO_PROJECT_PAIRS;
        output_file = "django_project_overrides.jl",
        binding_overrides = Dict("access.Driver" => "DriverLicence",
                                 "racing.Circuit" => "F1Circuit"))
    try
        # The override becomes the model's name, so the binding, the logical name and the reverse
        # accessor all follow it — while `db_table` still carries the real table.
        @test occursin("DriverLicence = Models.Model(\"driverlicence\", db_table = \"access_driver\"", generated)
        @test !occursin("Access_driver", generated)
        # An override on a class that never collided is legitimate: "spell this one differently".
        @test occursin("F1Circuit = Models.Model(\"f1circuit\", db_table = \"racing_circuit\"", generated)
        # ...and every reference to it followed.
        @test occursin("circuit_id = Models.ForeignKey(\"F1Circuit\"", generated)
        @test !occursin("ForeignKey(\"Circuit\"", generated)

        # The renamed side of the collision is still qualified — overriding one does not un-qualify
        # the other, because `racing_driver` is what its table is called.
        @test occursin("Racing_driver = Models.Model(\"racing_driver\"", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # Each rejection, with the message that has to name the offending value.
    for (overrides, needle) in (
            (Dict("access.Motorista" => "DriverLicence"), "access.Motorista"),   # key names nothing
            (Dict("access.Driver" => "Driver Licence"), "not a legal Julia identifier"),
            (Dict("access.Driver" => "___"), "write-only"),
            (Dict("access.Driver" => "driverLicence"), "DriverLicence"),          # not capitalized
            (Dict("access.Driver" => "Circuit"), "derived binding of"),           # collides
            (Dict("access.Driver" => "Models"), "reserves"),                      # reserved binding
            # Two keys, one class — the second used to win in silence. Keyed on `Circuit`, which
            # only `racing` declares: a bare `Driver` is ambiguous across the fixture and would trip
            # the ambiguity check first, testing the wrong guard.
            (Dict("racing.Circuit" => "Alpha", "Circuit" => "Beta"), "twice"))
        config_key2, existed2 = project_config!()
        try
            err = nothing
            try
                import_models_from_django(DJANGO_PROJECT_PAIRS; db = config_key2,
                                          file = "override_reject.jl", force_replace = true,
                                          binding_overrides = overrides)
            catch e
                err = e
            end
            @test err isa PormG.InvalidMigrationError
            @test occursin(needle, sprint(showerror, err))
        finally
            cleanup_project_test!(config_key2, existed2)
        end
    end

    # An override colliding with a DERIVED binding must behave the same whichever order the apps
    # were listed in. It did not: the override won and silently digit-suffixed the other model when
    # that model came later, and raised when it came earlier — so the same inputs gave two different
    # schemas depending on the pair order. Overrides now claim their bindings before anything is
    # derived onto them, so both orders reach the same error.
    let core = """
from django.db import models

class Pessoa(models.Model):
    nome = models.CharField(max_length=40)
""",
        importsapp = """
from django.db import models

class Batch(models.Model):
    note = models.CharField(max_length=40)
"""
        messages = String[]
        for pairs in (["core" => core, "imports" => importsapp],
                      ["imports" => importsapp, "core" => core])
            k, existed = project_config!()
            try
                err = nothing
                try
                    import_models_from_django(pairs; db = k, file = "ovorder.jl",
                                              force_replace = true,
                                              binding_overrides = Dict("imports.Batch" => "Pessoa"))
                catch e
                    err = e
                end
                @test err isa PormG.InvalidMigrationError
                push!(messages, sprint(showerror, err))
            finally
                cleanup_project_test!(k, existed)
            end
        end
        @test length(unique(messages)) == 1          # order-independent, to the character
        @test occursin("derived binding of 'core.Pessoa'", messages[1])
    end

    # A bare key works when the class name is unambiguous, so a single-app project need not qualify.
    config_key3, existed3 = project_config!()
    try
        import_models_from_django(["imports" => django_project_app("imports"),
                                   "racing"  => django_project_app("racing"),
                                   "access"  => django_project_app("access")];
                                  db = config_key3, file = "override_bare.jl", force_replace = true,
                                  binding_overrides = Dict("ImportBatch" => "Batch"))
        @test occursin("Batch = Models.Model(\"batch\", db_table = \"imports_importbatch\"",
                       read(joinpath(config_key3, "override_bare.jl"), String))
    finally
        cleanup_project_test!(config_key3, existed3)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the pre-flight refusals
#
# A connection-level `django_prefix` is not merely redundant in a multi-app import — it is actively
# harmful. `get_model_name` strips that ONE prefix from EVERY logical name, so `core_pessoa` would
# become `pessoa` while `access_pessoa` survived intact, and the reverse lookup would then want
# `Pessoa` while the binding is `Core_pessoa`. Cheap to detect here; near-impossible to diagnose at
# query time.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the multi-app importer refuses a connection-level django_prefix and malformed input (#346)" begin
    config_key, db_dir_existed = project_config!(django_prefix = "dash")
    try
        err = nothing
        try
            import_models_from_django(DJANGO_PROJECT_PAIRS; db = config_key, file = "refused.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("django_prefix", msg)
        @test occursin("dash", msg)
        @test !isfile(joinpath(config_key, "refused.jl"))
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # An EMPTY prefix is the absence of one (#345), so it must NOT trip the refusal — otherwise a
    # `django_prefix: ''` in connection.yml would lock the user out of multi-app import entirely.
    config_key_empty, existed_empty = project_config!(django_prefix = "")
    try
        import_models_from_django(DJANGO_PROJECT_PAIRS; db = config_key_empty,
                                  file = "empty_prefix_ok.jl", force_replace = true)
        @test occursin("db_table = \"racing_circuit\"",
                       read(joinpath(config_key_empty, "empty_prefix_ok.jl"), String))
    finally
        cleanup_project_test!(config_key_empty, existed_empty)
    end

    # Each refusal asserts on the MESSAGE, not just the exception type. `@test_throws
    # InvalidMigrationError` alone is worthless here: this importer raises that type for a dozen
    # reasons, so a guard can be deleted and the test still pass on someone else's error. The first
    # draft of the empty-label case did exactly that — it used the three-app fixture, whose `racing`
    # app references `settings.AUTH_USER_MODEL`, so with the label guard removed it still threw, from
    # the auth check instead. A plain inline source and a message assertion is what actually pins it.
    minimal = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)
"""

    config_key2, existed2 = project_config!()
    try
        # No apps at all.
        err = nothing
        try
            import_models_from_django(Pair{String, String}[]; db = config_key2, file = "empty.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("the app list is empty", sprint(showerror, err))

        # An empty app label — there is no Django app whose tables carry no prefix, and treating one
        # as a label composes `"" * "_" * class` and pins the table `_circuit`.
        err = nothing
        try
            import_models_from_django(["" => minimal]; db = config_key2, file = "blank_label.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("an app label is empty", sprint(showerror, err))
        @test !isfile(joinpath(config_key2, "blank_label.jl"))

        # ...including one that is only whitespace, since the label is stripped before it is used.
        err = nothing
        try
            import_models_from_django(["   " => minimal]; db = config_key2, file = "blank_label2.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("an app label is empty", sprint(showerror, err))

        # The same label twice would collapse two apps' tables onto one set of names.
        err = nothing
        try
            import_models_from_django(["racing" => minimal, "racing" => minimal];
                                      db = config_key2, file = "dup_label.jl", force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("listed more than once", sprint(showerror, err))

        # A label whose SHAPE is not a Django app_label. It is composed straight into every table
        # name, and `_lookup_class_ref` splits `"<app>.<Class>"` on the dot — so a dotted label
        # yields `db_table = "My.app_pessoa"` and makes every qualified reference into that app
        # unresolvable, degrading silently.
        for bad in ("My.app", "2fast", "has space", "has-dash")
            err = nothing
            try
                import_models_from_django([bad => minimal]; db = config_key2,
                                          file = "bad_label.jl", force_replace = true)
            catch e
                err = e
            end
            @test err isa PormG.InvalidMigrationError
            @test occursin("is not a valid Django app_label", sprint(showerror, err))
        end
        # ...and an underscored label, which IS legal, still works.
        import_models_from_django(["my_app" => minimal]; db = config_key2, file = "ok_label.jl",
                                  force_replace = true)
        @test occursin("db_table = \"my_app_circuit\"",
                       read(joinpath(config_key2, "ok_label.jl"), String))

        # Two classes differing only in case name ONE Django model and derive ONE table, so the
        # second used to overwrite the first in the index — orphaning a binding that was still
        # emitted, and leaving two models pointing at the same table. Django refuses this too.
        cased = """
from django.db import models

class Pessoa(models.Model):
    nome = models.CharField(max_length=40)

class pessoa(models.Model):
    outro = models.CharField(max_length=40)
"""
        err = nothing
        try
            import_models_from_django(["core" => cased]; db = config_key2, file = "cased.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("differ only in case", msg)
        @test occursin("core_pessoa", msg)

        # A MISTYPED PATH. This is the silent-loss shape the pairs API invents: "no newline and not
        # a file" is otherwise read as source TEXT, so one wrong path out of three parses to zero
        # classes and every relation into that app degrades — three markers about missing models and
        # not one line saying the file does not exist.
        err = nothing
        try
            import_models_from_django(["racing" => django_project_app("racing"),
                                       "acess"  => joinpath(DJANGO_PROJECT_ROOT, "acess", "models.py")];
                                      db = config_key2, file = "typo_path.jl", force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("which is not a file", msg)
        @test occursin("acess", msg)          # names the app, so the pair is findable
        @test !isfile(joinpath(config_key2, "typo_path.jl"))
    finally
        cleanup_project_test!(config_key2, existed2)
    end

    # An app that legitimately declares no models is NOT an error — but it says so in the artifact,
    # not only in a console warning that scrolls away (#70). Whoever opens the generated file later
    # and wonders where that app went needs to see it there.
    no_models = """
from django.db import models


def helper():
    return 1
"""
    generated, config_key3, existed3 = import_project(["racing" => django_project_app("racing"),
                                                       "access" => django_project_app("access"),
                                                       "empty"  => no_models];
                                                      output_file = "empty_app.jl")
    try
        @test occursin("# PormG: app 'empty' contributed no model to this file", generated)
        # The other apps are unaffected.
        @test occursin("Circuit = Models.Model(\"circuit\"", generated)
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Core.eval(sandbox, :(isdefined(empty_app, :Circuit)))
    finally
        cleanup_project_test!(config_key3, existed3)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a `through=` model outside the import drops the relation
#
# A through model IS the join table, so an unresolvable one leaves nothing to point at. The M2M has
# no column of its own either, so — unlike a ForeignKey — there is nothing to degrade to.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unresolvable through model drops the ManyToMany with a marker (#346)" begin
    source = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)

class Season(models.Model):
    circuits = models.ManyToManyField(Circuit, through='calendar.SeasonCircuit')
    year = models.IntegerField()
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "through_missing.jl")
    try
        @test !occursin("circuits = Models.ManyToManyField", generated)
        @test occursin("through model 'calendar.SeasonCircuit' is not in the imported app set", generated)
        @test occursin("the relation is DROPPED", generated)
        # The rest of the model is untouched — one bad relation never costs a table.
        @test occursin("Season = Models.Model(\"season\", db_table = \"racing_season\"", generated)
        @test occursin("year = Models.IntegerField()", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the precomputed binding IS the rendered binding
#
# Pass 1 decides every binding before pass 2 renders a single model, because a cross-app FK has to
# name a target that may not have been rendered yet. If the two derivations ever disagreed, the
# generated file would carry FKs pointing at bindings it does not define — and it would still LOOK
# right. Asserted on the hostile case: names that force `_dedupe_taken` to run.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a residual binding collision is resolved once, not twice (#346)" begin
    # `racing.Pit` app-qualifies to `racing_pit`; an app literally called `racing_pit` with a class
    # `Pit` would too. Both then derive the binding `Racing_pit`.
    left = """
from django.db import models

class Pit(models.Model):
    lane = models.IntegerField()
"""
    other = """
from django.db import models

class Pit(models.Model):
    bay = models.IntegerField()
"""
    third = """
from django.db import models

class Racing_pit(models.Model):
    slot = models.IntegerField()
"""
    # A FOURTH app whose ForeignKey points at the model the backstop renames. This is what makes the
    # testset test its headline: `entry.binding` — the only thing pass 1 contributes — is consumed
    # ONLY when rewriting a relation target, so a fixture with no ForeignKey can never observe the
    # two derivations disagreeing. The earlier version scraped bindings out of the file it had just
    # evaluated and asserted they were defined, which is true by construction.
    fourth = """
from django.db import models

class Stop(models.Model):
    pit = models.ForeignKey('pitlane.Racing_pit', on_delete=models.CASCADE)
    lap = models.IntegerField()
"""
    generated, config_key, db_dir_existed = import_project(
        ["racing" => left, "access" => other, "pitlane" => third, "timing" => fourth];
        output_file = "residual_clash.jl")
    try
        # Three distinct bindings for the colliders, and the digit backstop landed on exactly one.
        bindings = [m.captures[1] for m in eachmatch(r"^(\w+) = Models\.Model\("m, generated)]
        @test length(unique(bindings)) == length(bindings)
        @test "Racing_pit" in bindings
        @test "Access_pit" in bindings
        @test "Racing_pit2" in bindings

        # A rename nobody asked for is REPORTED, not silent.
        @test occursin("# PormG: 'pitlane.Racing_pit' would be the Julia binding 'Racing_pit'", generated)
        @test occursin("emitted as 'Racing_pit2' instead", generated)

        # THE assertion: the FK was rewritten to the binding pass 1 recorded, and that binding is
        # the one `Model_to_str` actually emitted. If the two derivations ever disagree this is an
        # unresolvable target — checked through the same lookup `set_models` uses, not by scraping
        # the file for names it already contains.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        models_module = Core.eval(sandbox, :(residual_clash))
        stop = Core.eval(sandbox, :(residual_clash.Stop))
        @test stop.fields["pit_id"].to == "Racing_pit2"
        @test Base.invokelatest(PormG.Models._resolve_target_model,
                                stop.fields["pit_id"].to, models_module) !== nothing

        # The suffixed model still addresses its own table, not the one it collided with.
        @test PormG.model_table_name(Core.eval(sandbox, :(residual_clash.Racing_pit2))) == "pitlane_racing_pit"
        @test PormG.model_table_name(Core.eval(sandbox, :(residual_clash.Racing_pit))) == "racing_pit"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): an abstract base in ANOTHER app is merged
#
# A shared `core.models.TimeStampedModel` is one of the commonest shapes in a real Django project,
# and the marker `_inherited_unresolved` has emitted since #341 tells people the fix is to "import
# the app that defines them together with this one". Building the class graph per FILE meant doing
# exactly that changed nothing — the base was still "not defined in this file" and the child still
# lost its columns, silently, from the schema.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an abstract base declared in another app is merged (#346)" begin
    core = """
from django.db import models

class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        abstract = True

class Circuit(models.Model):
    name = models.CharField(max_length=120)
"""
    # The `from core.models import …` line is not decoration: since #370 a base resolves across apps
    # only when this module actually imported it, which is also the only spelling Python would run —
    # without it `TimeStampedModel` is an undefined name and Django raises at import time.
    downstream = """
from django.db import models
from core.models import TimeStampedModel

class ImportBatch(TimeStampedModel):
    note = models.CharField(max_length=40)
"""
    generated, config_key, db_dir_existed = import_project(["core" => core, "imports" => downstream];
                                                           output_file = "crossapp_base.jl")
    try
        # The inherited columns are actually there...
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test occursin("updated_at = Models.DateTimeField(auto_now=true)", generated)
        # ...and the marker that used to send the reader in a circle is gone.
        @test !occursin("not defined in", generated)
        # The abstract base itself still emits no table of its own.
        @test !occursin("TimeStampedModel = Models.Model", generated)
        @test occursin("ImportBatch = Models.Model(\"importbatch\", db_table = \"imports_importbatch\"", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # Importing the child ALONE still degrades, and now says what to do about it in the vocabulary of
    # the arity being used.
    config_key2, existed2 = project_config!()
    try
        import_models_from_django(downstream; db = config_key2, file = "alone.jl",
                                  force_replace = true)
        alone = read(joinpath(config_key2, "alone.jl"), String)
        @test !occursin("created_at", alone)
        @test occursin("not defined in this file", alone)
        @test occursin("\"<app_label>\" => \"<models.py>\" pairs", alone)
    finally
        cleanup_project_test!(config_key2, existed2)
    end

    # A CONCRETE base in another app is still multi-table inheritance, and still refused — merging
    # across apps must not quietly grow new semantics.
    concrete = """
from django.db import models

class Venda(models.Model):
    total = models.IntegerField()
"""
    child = """
from django.db import models
from core.models import Venda

class Pedido(Venda):
    obs = models.CharField(max_length=40)
"""
    generated2, config_key3, existed3 = import_project(["core" => concrete, "imports" => child];
                                                        output_file = "crossapp_mti.jl")
    try
        @test occursin("Django multi-table inheritance", generated2)
        @test !occursin("Pedido = Models.Model", generated2)
    finally
        cleanup_project_test!(config_key3, existed3)
    end

    # A base absent from EVERY app still degrades — and the marker speaks the vocabulary of the
    # arity in use. Saying "not defined in this file" to someone who passed four files, and telling
    # them to "import the app that defines them together with this one" when that is exactly what
    # they did, is the circular advice the cross-app merge exists to stop giving.
    orphan = """
from django.db import models

class Relatorio(ExternalBase):
    titulo = models.CharField(max_length=80)
"""
    generated3, config_key4, existed4 = import_project(["core" => concrete, "imports" => orphan];
                                                        output_file = "crossapp_orphan.jl")
    try
        @test occursin("not defined in any app of this import", generated3)
        @test !occursin("not defined in this file", generated3)
        @test occursin("add the app that defines them to the pair list", generated3)
        # The model is still imported, with its own columns — a missing base never costs a table.
        @test occursin("Relatorio = Models.Model(\"relatorio\", db_table = \"imports_relatorio\"", generated3)
        @test occursin("titulo = Models.CharField(max_length=80)", generated3)
    finally
        cleanup_project_test!(config_key4, existed4)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a class the index knows but emission drops
#
# Pass 1 hands every indexed class a binding, and every ForeignKey to it is rewritten to that
# binding. If pass 2 then emits nothing, the generated file references a binding it does not define
# and `set_models` throws in the consuming app, pointing at the wrong model.
#
# The reachable path was `autofields_ignore`: the primary-key check ran BEFORE the ignore test, so
# ignoring the type of a `primary_key=True` field claimed the PK and then dropped the column, leaving
# `fields_dict` empty and the model unemitted.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a class the index knows is always emitted (#346)" begin
    source = """
from django.db import models

class Thing(models.Model):
    codigo = models.CharField(max_length=10, primary_key=True)

class Ref(models.Model):
    t = models.ForeignKey('Thing', on_delete=models.CASCADE)
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "ignored_pk.jl",
                                                           autofields_ignore = ["Manager", "CharField"])
    try
        # The model survives — with a synthetic primary key, since the declared one was ignored.
        @test occursin("Thing = Models.Model(\"thing\", db_table = \"racing_thing\"", generated)
        @test occursin("ForeignKey(\"Thing\"", generated)
        # The ignored field really is gone, and `id` really did replace it. Without BOTH of these
        # the testset passes even when `autofields_ignore` is not applied at all — the model is
        # emitted either way, just with a different set of columns, so asserting only its existence
        # tests nothing about the ordering this testset is named for.
        @test !occursin("codigo", generated)
        @test occursin("Thing = Models.Model(\"thing\", db_table = \"racing_thing\",\n  id = Models.IDField())", generated)

        # ...and the FK actually resolves, which is the property that was broken.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        models_module = Core.eval(sandbox, :(ignored_pk))
        ref = Core.eval(sandbox, :(ignored_pk.Ref))
        @test Base.invokelatest(PormG.Models._resolve_target_model,
                                ref.fields["t_id"].to, models_module) !== nothing
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a stock-Django project is importable
#
# `AUTH_USER_MODEL = "auth.User"` is Django's default and `django.contrib.auth` is not a models.py
# anyone hands this importer — so there is no candidate to find and no app to add. Erroring left the
# commonest project shape with no way in at all, and the message named a keyword that produced a
# different error when you passed it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a stock-Django auth.User project imports, degrading its user relations (#346)" begin
    source = """
from django.conf import settings
from django.db import models

class Race(models.Model):
    reported_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
    season = models.IntegerField()
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "stock_auth.jl",
                                                           auth_user_model = "auth.User")
    try
        @test occursin("reported_by_id = Models.BigIntegerField(", generated)
        # The marker names the model the USER meant, not the settings alias they wrote.
        @test occursin("'auth.User' is not in the imported app set", generated)
        @test !occursin("AUTH_USER_MODEL", generated)
        @test occursin("season = Models.IntegerField()", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # Saying nothing is still the hard error — the importer cannot guess — and the message now
    # points at the stock-Django answer.
    config_key2, existed2 = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["racing" => source]; db = config_key2, file = "noauth.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("auth_user_model = \"auth.User\"", sprint(showerror, err))
    finally
        cleanup_project_test!(config_key2, existed2)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a ForeignKey to a PROXY resolves
#
# A proxy has no table of its own — it reads and writes its concrete parent's, and Django's FK to a
# proxy addresses that table. Degrading such a relation threw away something fully expressible, and
# the marker claimed the target "is not in the imported app set", which was false.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ForeignKey to a proxy model addresses the concrete parent (#346)" begin
    source = """
from django.db import models

class Base(models.Model):
    nome = models.CharField(max_length=40)

class BaseProxy(Base):
    class Meta:
        proxy = True

class DeepProxy(BaseProxy):
    class Meta:
        proxy = True

class Thing(models.Model):
    p = models.ForeignKey('BaseProxy', on_delete=models.CASCADE)
    d = models.ForeignKey('DeepProxy', on_delete=models.CASCADE, related_name='deep')
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "proxy_fk.jl")
    try
        @test occursin("p_id = Models.ForeignKey(\"Base\"", generated)
        # A proxy OF a proxy lands on the concrete model at the bottom, not on an intermediate that
        # emits nothing either.
        @test occursin("d_id = Models.ForeignKey(\"Base\"", generated)
        @test !occursin("BigIntegerField", generated)
        @test !occursin("'BaseProxy' is not in the imported app set", generated)
        # The proxy itself is still not emitted — it has no table to declare.
        @test occursin("is a Django proxy", generated)
        @test !occursin("BaseProxy = Models.Model", generated)

        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        models_module = Core.eval(sandbox, :(proxy_fk))
        thing = Core.eval(sandbox, :(proxy_fk.Thing))
        for key in ("p_id", "d_id")
            @test Base.invokelatest(PormG.Models._resolve_target_model,
                                    thing.fields[key].to, models_module) !== nothing
        end
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): join columns follow the CLASS, not the primary key's name
#
# Django names a join-table column `<lowercased class>_id` — always, whatever the primary key is
# called. PormG derives `<model.name>_<pk field>`, so a legacy model keyed on `codigo` made PormG
# address `driver_codigo` where Django created `driver_id`. The pin needs BOTH models, and the
# target may be built after its owner, so it runs once every model exists.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ManyToMany join column ignores the target's primary-key name (#346)" begin
    source = """
from django.db import models

class Driver(models.Model):
    codigo = models.CharField(max_length=10, primary_key=True)

class Team(models.Model):
    drivers = models.ManyToManyField(Driver)
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "m2m_pk.jl")
    try
        @test occursin("target_field=\"driver_id\"", generated)
        @test !occursin("driver_codigo", generated)
        # The OWNER's PK is `id`, and its name is unchanged, so its side needs no pin.
        @test !occursin("source_field=", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # Both ends keyed on something other than `id`: both sides pinned.
    both = """
from django.db import models

class Driver(models.Model):
    codigo = models.CharField(max_length=10, primary_key=True)

class Team(models.Model):
    sigla = models.CharField(max_length=5, primary_key=True)
    drivers = models.ManyToManyField(Driver)
"""
    generated2, config_key2, existed2 = import_project(["racing" => both]; output_file = "m2m_pk2.jl")
    try
        @test occursin("source_field=\"team_id\"", generated2)
        @test occursin("target_field=\"driver_id\"", generated2)
    finally
        cleanup_project_test!(config_key2, existed2)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the cross-app scope must not swap enums between apps
#
# Bases and enums share a scope, so they must share a PRECEDENCE. `_collect_enums` is last-wins
# within a file while the class index is deliberately first-wins, so merging a flat "own classes then
# every app" vector let the LAST-listed app's `Status` overwrite everyone's — silently handing a model
# another app's enumeration and then reporting its own member as "not a member of Status". Found by
# the second review pass; it was a regression introduced by the cross-app merge itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "each app keeps its own enum when several declare the same name (#346)" begin
    core = """
from django.db import models

class Status(models.TextChoices):
    CORE_A = "ca", "Core A"
    CORE_B = "cb", "Core B"

class Pessoa(models.Model):
    situacao = models.CharField(max_length=2, choices=Status.choices, default=Status.CORE_A)
"""
    other = """
from django.db import models

class Status(models.TextChoices):
    OTHER_X = "ox", "Other X"

class Batch(models.Model):
    situacao = models.CharField(max_length=2, choices=Status.choices, default=Status.OTHER_X)
"""
    # Asserted in BOTH orders: the defect was that the last-listed app won, so a single order can
    # pass by luck.
    for pairs in (["core" => core, "other" => other], ["other" => other, "core" => core])
        generated, config_key, db_dir_existed = import_project(pairs; output_file = "enum_scope.jl")
        try
            @test occursin("choices=((\"ca\", \"Core A\"), (\"cb\", \"Core B\"))", generated)
            @test occursin("choices=((\"ox\", \"Other X\"),)", generated)
            @test occursin("default=\"ca\"", generated)
            @test occursin("default=\"ox\"", generated)
            # No member was reported missing — the false marker the swap produced.
            @test !occursin("is not a member of", generated)
        finally
            cleanup_project_test!(config_key, db_dir_existed)
        end
    end

    # A `TextChoices` in ANOTHER app is still resolvable — that is what sharing the scope buys, and
    # it must survive the precedence fix.
    shared = """
from django.db import models

class Status(models.TextChoices):
    DRAFT = "d", "Draft"
    SENT = "s", "Sent"
"""
    # As with a cross-app base, the import line is what puts `Status` in this module's namespace —
    # and since #370 that is what the importer resolves on, rather than the bare name.
    consumer = """
from django.db import models
from core.models import Status

class Batch(models.Model):
    situacao = models.CharField(max_length=1, choices=Status.choices, default=Status.DRAFT)
"""
    generated2, key2, existed2 = import_project(["core" => shared, "imports" => consumer];
                                                 output_file = "enum_shared.jl")
    try
        @test occursin("choices=((\"d\", \"Draft\"), (\"s\", \"Sent\"))", generated2)
        @test occursin("default=\"d\"", generated2)
        @test !occursin("which this file does not define", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a model with two primary keys must not take the import down
#
# `get_model_pk_field` THROWS on more than one primary key, and nothing counts primary keys when the
# model is declared — so a class declaring `primary_key=True` on two fields builds a malformed model
# that reaches the throw later (at `set_models` if it owns a ManyToManyField, whose relation wiring
# reads the key; otherwise at the first query or `save()`). Reading the primary key eagerly for every
# entry — to decide ManyToMany join columns — turned that into a raw ModelDefinitionError that
# aborted the WHOLE import, on a project with no ManyToManyField at all, on BOTH arities.
#
# The original fixture for this was an AbstractUser subclass with its own key, which the importer
# handed a second, injected `id`. That is fixed at the root (#369, below), so this now uses a class
# that is two-key on its own terms — otherwise the containment property loses its only coverage.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a two-primary-key model does not abort the import (#346)" begin
    source = """
from django.db import models

class Thing(models.Model):
    a = models.CharField(max_length=5, primary_key=True)
    b = models.CharField(max_length=5, primary_key=True)

class Circuit(models.Model):
    name = models.CharField(max_length=40)
"""
    generated, config_key, db_dir_existed = import_project(["access" => source];
                                                           output_file = "two_pk.jl")
    try
        # Every OTHER model survives — that is the property, and it is ALL this asserts. The two-PK
        # model itself is malformed and blows up at the first thing that reads its key, exactly as it
        # did before this pass existed. Declaring it does not refuse it — nothing counts primary keys
        # there — and for this `Thing`, which owns no relation, `set_models` does not either; the
        # throw waits for a query or a `save()`. (The `with_m2m` variant below is the shape that DOES
        # fail at `set_models`, because relation wiring reads the key.)
        @test occursin("Circuit = Models.Model(\"circuit\", db_table = \"access_circuit\"", generated)
        @test occursin("Thing = Models.Model(\"thing\", db_table = \"access_thing\"", generated)
        # Both declared keys are emitted verbatim: the importer reports what the models.py says, it
        # does not silently pick a winner.
        @test occursin("a = Models.CharField(primary_key=true, max_length=5)", generated)
        @test occursin("b = Models.CharField(primary_key=true, max_length=5)", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # The same on the single-app arity, which is where an existing caller regenerating an unchanged
    # models.py would have hit it.
    config_key2, existed2 = project_config!()
    try
        import_models_from_django(source; db = config_key2, file = "two_pk_single.jl",
                                  force_replace = true)
        @test occursin("Circuit = Models.Model(\"circuit\"",
                       read(joinpath(config_key2, "two_pk_single.jl"), String))
    finally
        cleanup_project_test!(config_key2, existed2)
    end

    # The case above proves the lookup is LAZY — with no ManyToManyField anywhere it is never called.
    # This one proves the CATCH: the same broken model owning an auto-derived M2M does reach it, and
    # must still not take the import down. The join columns are simply left derived, because an
    # unreadable primary key means "do not know", and pinning on a guess would write a column name
    # into the artifact with nothing behind it.
    with_m2m = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=40)

class Thing(models.Model):
    a = models.CharField(max_length=5, primary_key=True)
    b = models.CharField(max_length=5, primary_key=True)
    others = models.ManyToManyField(Circuit)
"""
    config_key3, existed3 = project_config!()
    try
        generated = @test_logs (:warn, r"cannot read the primary key") match_mode=:any begin
            import_models_from_django(["access" => with_m2m]; db = config_key3,
                                      file = "two_pk_m2m.jl", force_replace = true)
            read(joinpath(config_key3, "two_pk_m2m.jl"), String)
        end
        @test occursin("Circuit = Models.Model(\"circuit\"", generated)
        # The join TABLE still pins (it needs no primary key); the columns do not.
        @test occursin("others = Models.ManyToManyField(\"Circuit\", db_table=\"access_thing_others\")", generated)
        @test !occursin("source_field=", generated)
    finally
        cleanup_project_test!(config_key3, existed3)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#369): a declared primary key suppresses Django's implicit `id`
#
# `AbstractUser` INHERITS `id` from `models.Model` rather than owning it, so declaring any
# `primary_key=True` field suppresses it — exactly as on any other model. The importer instead
# injected an `id` for every AbstractUser subclass before reading a single field, so a legacy user
# table keyed on `matricula` came out with TWO primary keys and was unusable: `get_model_pk_field`
# refuses more than one, and `save()`, every ManyToManyField touching the model, the relation wiring
# and the migration planner all go through it. The failure is deferred, not immediate — the model is
# built and registered without complaint, then throws at the first read.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an AbstractUser subclass with its own primary key has exactly one (#369)" begin
    own_pk = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    matricula = models.CharField(max_length=20, primary_key=True)
"""
    generated, config_key, db_dir_existed = import_project(["access" => own_pk];
                                                           output_file = "auth_own_pk.jl")
    try
        @test occursin("matricula = Models.CharField(primary_key=true, max_length=20)", generated)
        # The implicit `id` is GONE, not merely shadowed. `User` is the only model in this file, so
        # a bare search for the field is unambiguous.
        @test !occursin("Models.IDField()", generated)
        # The other ten auth columns are untouched — only `id` was ever wrong.
        @test occursin("date_joined = Models.DateTimeField()", generated)
        @test occursin("username = Models.CharField()", generated)

        # The property the old #346 test deliberately did not assert: the model LOADS. Before this
        # fix `get_model_pk_field` threw ModelDefinitionError here, naming `matricula, id`.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        user = Core.eval(sandbox, :(auth_own_pk.User))
        @test Base.invokelatest(PormG.Models.get_model_pk_field, user) == :matricula
        @test !haskey(user.fields, "id")
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # An AbstractUser subclass that declares NO key still gets Django's implicit `id` — the fix
    # removes the unconditional injection, not the implicit key itself.
    no_pk = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    apelido = models.CharField(max_length=20)
"""
    generated2, key2, existed2 = import_project(["access" => no_pk];
                                                 output_file = "auth_no_pk.jl")
    try
        @test occursin("id = Models.IDField()", generated2)
        sandbox2 = Module()
        Core.eval(sandbox2, Meta.parse(generated2))
        @test Base.invokelatest(PormG.Models.get_model_pk_field,
                                Core.eval(sandbox2, :(auth_no_pk.User))) == :id
    finally
        cleanup_project_test!(key2, existed2)
    end

    # The class declares `id` ITSELF. This was already correct — the declared field overwrote the
    # injected one and there was exactly one key — and it has to stay correct: the declared type
    # must survive, not be replaced by an IDField.
    declared_id = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    id = models.UUIDField(primary_key=True)
"""
    generated3, key3, existed3 = import_project(["access" => declared_id];
                                                 output_file = "auth_declared_id.jl")
    try
        @test occursin("id = Models.UUIDField(primary_key=true)", generated3)
        @test !occursin("Models.IDField()", generated3)
        sandbox3 = Module()
        Core.eval(sandbox3, Meta.parse(generated3))
        @test Base.invokelatest(PormG.Models.get_model_pk_field,
                                Core.eval(sandbox3, :(auth_declared_id.User))) == :id
    finally
        cleanup_project_test!(key3, existed3)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#369): an inherited primary key overridden by a non-key field
#
# Django permits overriding a field inherited from an ABSTRACT base. The importer merges such a base
# by statement concatenation (ancestors first, last write wins), so the base's `primary_key=True`
# statement ran and the child's plain redeclaration replaced the value. A boolean flag recorded the
# base's claim and was never unset, so the model came out with NO key and no implicit `id` either —
# the same flag-versus-dict desync as the AbstractUser injection, in the other direction. The claim
# is now recorded per field and retracted when the field is rewritten, so an override drops it along
# with the value; nothing survives that the final field set does not agree with.
#
# The base here is a plain `models.Model`, deliberately: on an AbstractUser base the unconditional
# `id` injection masked this outcome, so that shape produces identical output before and after the
# fix and would prove nothing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an overridden inherited primary key falls back to the implicit id (#369)" begin
    source = """
from django.db import models

class Base(models.Model):
    codigo = models.CharField(max_length=10, primary_key=True)

    class Meta:
        abstract = True

class Thing(Base):
    codigo = models.CharField(max_length=10)
"""
    generated, config_key, db_dir_existed = import_project(["access" => source];
                                                           output_file = "abstract_pk_override.jl")
    try
        # The child's redeclaration wins, and it is not a key...
        @test occursin("codigo = Models.CharField(max_length=10)", generated)
        @test !occursin("codigo = Models.CharField(primary_key=true", generated)
        # ...so nothing claims the key and Django's implicit `id` is what the model gets. Before the
        # fix this model was emitted with `codigo` as its ONLY field and no primary key anywhere.
        @test occursin("id = Models.IDField()", generated)
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Base.invokelatest(PormG.Models.get_model_pk_field,
                                Core.eval(sandbox, :(abstract_pk_override.Thing))) == :id
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#369): a legacy-keyed user table now pins its ManyToMany join column
#
# `_pin_m2m_join_columns!` exists for exactly this shape — Django hardcodes `<class>_id` for the join
# column while PormG derives it from the primary-key field name, so a model keyed on anything but
# `id` needs the pin. It could never reach that shape for an AbstractUser subclass: the model had two
# keys, `get_model_pk_field` threw, and the pass caught it and left the columns derived. With one key
# the pin fires, which is the visible downstream half of this fix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ManyToMany owned by a legacy-keyed user table pins source_field (#369)" begin
    source = """
from django.contrib.auth.models import AbstractUser
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=40)

class User(AbstractUser):
    matricula = models.CharField(max_length=20, primary_key=True)
    circuits = models.ManyToManyField(Circuit)
"""
    config_key, db_dir_existed = project_config!()
    try
        # No warning at all now — the primary key is readable, so nothing is "left derived". Asserts
        # the ABSENCE of the `cannot read the primary key` warn this fixture used to produce.
        generated = @test_logs min_level=Logging.Warn begin
            import_models_from_django(["access" => source]; db = config_key,
                                      file = "auth_pk_m2m.jl", force_replace = true)
            read(joinpath(config_key, "auth_pk_m2m.jl"), String)
        end
        # Django names the join column from the CLASS (`user_id`), not from the key field
        # (`matricula_id`), which is why the pin is needed at all.
        @test occursin("circuits = Models.ManyToManyField(\"Circuit\", db_table=\"access_user_circuits\", source_field=\"user_id\")",
                       generated)
        # `Circuit` is keyed on `id` and its binding matches its class name, so its end needs no pin.
        @test !occursin("target_field=", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#369): "did anything claim the key" has to be asked TWICE
#
# The built field and the Django declaration each miss a case the other catches, in opposite
# directions, so deciding the implicit `id` from either one alone is wrong:
#
#   - `IntegerField(primary_key=True)` DECLARES the key, but PormG's IntegerField does not accept
#     `primary_key` and constructs with `false`. Reading the built fields alone concludes "no key"
#     and adds an `id` — naming a column the Django table has not got, which breaks every query that
#     expands the field list. This is a legacy-schema shape, not a hypothetical.
#   - `AutoField()` DECLARES nothing, but PormG's AutoField defaults `primary_key = true`. Reading
#     the declarations alone concludes "no key" and adds an `id` beside it — two primary keys, the
#     very defect #369 is about.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a primary key PormG cannot express is reported, never replaced by an id (#369)" begin
    unkeyable = """
from django.db import models

class Municipio(models.Model):
    codigo = models.IntegerField(primary_key=True)
    nome = models.CharField(max_length=40)
"""
    generated, config_key, db_dir_existed = import_project(["access" => unkeyable];
                                                           output_file = "unkeyable_pk.jl")
    try
        @test occursin("codigo = Models.IntegerField()", generated)
        # NO phantom `id`. `access_municipio` is keyed on `codigo` and has no `id` column.
        @test !occursin("Models.IDField()", generated)
        # ...and the artifact states the gap rather than shipping a silently key-less model.
        @test occursin("# PormG: 'Municipio' declares its primary key on 'codigo'", generated)
        @test occursin("This model therefore has NO primary key", generated)

        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Base.invokelatest(PormG.Models.get_model_pk_field,
                                Core.eval(sandbox, :(unkeyable_pk.Municipio))) === nothing
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end

    # A ManyToManyField is never a candidate: it contributes no column, so reporting a "lost" key on
    # one would name a column that never existed — and the model still needs its implicit `id`.
    m2m_pk = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=40)

class Thing(models.Model):
    others = models.ManyToManyField(Circuit, primary_key=True)
"""
    generated3, key3, existed3 = import_project(["access" => m2m_pk]; output_file = "m2m_pk.jl")
    try
        @test occursin("id = Models.IDField()", generated3)
        @test !occursin("declares its primary key", generated3)
    finally
        cleanup_project_test!(key3, existed3)
    end

    # The mirror case. `AutoField()` must NOT also receive an `id`, and must not be reported as
    # unkeyable either — the built field is a perfectly good primary key.
    auto = """
from django.db import models

class Thing(models.Model):
    codigo = models.AutoField()
    nome = models.CharField(max_length=40)
"""
    generated2, key2, existed2 = import_project(["access" => auto]; output_file = "auto_pk.jl")
    try
        @test occursin("codigo = Models.AutoField()", generated2)
        @test !occursin("Models.IDField()", generated2)
        @test !occursin("# PormG:", generated2)
        sandbox2 = Module()
        Core.eval(sandbox2, Meta.parse(generated2))
        @test Base.invokelatest(PormG.Models.get_model_pk_field,
                                Core.eval(sandbox2, :(auto_pk.Thing))) == :codigo
    finally
        cleanup_project_test!(key2, existed2)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a ManyToMany to a proxy names its column from the PROXY
#
# `.to` becomes the concrete parent's binding — that is the table the relation reads — but Django
# names the join column from the model the field NAMES (`to_model._meta.model_name`). Deriving it
# from the concrete class emits a column Django never created, and quietly: before proxies resolved
# at all, this relation was DROPPED with a marker.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ManyToMany to a proxy pins the proxy's join column (#346)" begin
    source = """
from django.db import models

class Base(models.Model):
    nome = models.CharField(max_length=40)

class BaseProxy(Base):
    class Meta:
        proxy = True

class Thing(models.Model):
    items = models.ManyToManyField('BaseProxy')
    plain = models.ManyToManyField(Base, related_name='things')
"""
    generated, config_key, db_dir_existed = import_project(["racing" => source];
                                                           output_file = "m2m_proxy.jl")
    try
        # The relation reads the parent's table, but the column is named for the proxy.
        @test occursin("items = Models.ManyToManyField(\"Base\", db_table=\"racing_thing_items\", target_field=\"baseproxy_id\")", generated)
        # A ManyToMany to the CONCRETE model is unaffected — the pin is for the proxy case only.
        @test occursin("plain = Models.ManyToManyField(\"Base\", related_name=\"things\", db_table=\"racing_thing_plain\")", generated)
        @test !occursin("plain = Models.ManyToManyField(\"Base\", related_name=\"things\", db_table=\"racing_thing_plain\", target_field", generated)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): names differing only in CASE collide too
#
# The Julia binding is `uppercasefirst(name)`; the positional name is `lowercase(name)` — a coarser
# equivalence, and the one `set_models` keys a reverse accessor on. `core.Pessoa` and `legacy.PESSOA`
# derive different bindings, so they slipped past app-qualification and collided downstream, where
# `Model_to_str` renamed one to `pessoa2` with no warning and no marker, decided by list order.
# ─────────────────────────────────────────────────────────────────────────────
@testset "class names differing only in case are app-qualified too (#346)" begin
    upper = """
from django.db import models

class Pessoa(models.Model):
    nome = models.CharField(max_length=40)
"""
    lower = """
from django.db import models

class PESSOA(models.Model):
    outro = models.CharField(max_length=40)
"""
    for pairs in (["core" => upper, "legacy" => lower], ["legacy" => lower, "core" => upper])
        generated, config_key, db_dir_existed = import_project(pairs; output_file = "case_clash.jl")
        try
            # Both qualified, both tables intact, and no digit suffix anywhere.
            @test occursin("Models.Model(\"core_pessoa\", db_table = \"core_pessoa\"", generated)
            @test occursin("Models.Model(\"legacy_pessoa\", db_table = \"legacy_pessoa\"", generated)
            @test !occursin("pessoa2", generated)
            @test !occursin("Pessoa2", generated)
            # ...and the file still loads with two distinct bindings.
            sandbox = Module()
            Core.eval(sandbox, Meta.parse(generated))
            @test Core.eval(sandbox, :(isdefined(case_clash, :Core_pessoa)))
            @test Core.eval(sandbox, :(isdefined(case_clash, :Legacy_pessoa)))
        finally
            cleanup_project_test!(config_key, db_dir_existed)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the single-app method resolves the same three spellings
#
# The multi-app work fixed `"self"`, `"<app>.<Class>"` naming the file's OWN app, and
# `settings.AUTH_USER_MODEL` for every caller, not just the new arity. All three used to reach the
# generated file verbatim and throw `ModelDefinitionError` at `set_models`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the single-app importer resolves self, app-qualified and AUTH_USER_MODEL targets (#346)" begin
    source = """
from django.conf import settings
from django.contrib.auth.models import AbstractUser
from django.db import models

class User(AbstractUser):
    matricula = models.CharField(max_length=20)

class Circuit(models.Model):
    name = models.CharField(max_length=120)

class Driver(models.Model):
    forename = models.CharField(max_length=60)
    mentor = models.ForeignKey('self', on_delete=models.SET_NULL, null=True, related_name='mentees')
    home = models.ForeignKey('racing.Circuit', on_delete=models.PROTECT)
    created_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
"""

    config_key, db_dir_existed = project_config!(django_prefix = "racing")
    try
        import_models_from_django(source; db = config_key, file = "single_app_targets.jl",
                                  force_replace = true)
        generated = read(joinpath(config_key, "single_app_targets.jl"), String)

        @test occursin("mentor_id = Models.ForeignKey(\"Driver\"", generated)
        @test occursin("home_id = Models.ForeignKey(\"Circuit\"", generated)
        @test occursin("created_by_id = Models.ForeignKey(\"User\"", generated)
        @test !occursin("\"self\"", generated)
        @test !occursin("racing.Circuit", generated)
        @test !occursin("AUTH_USER_MODEL", generated)

        # ...and the file loads with every target resolving, which is what used to fail.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        models_module = Core.eval(sandbox, :(single_app_targets))
        driver = Core.eval(sandbox, :(single_app_targets.Driver))
        for key in ("mentor_id", "home_id", "created_by_id")
            @test Base.invokelatest(PormG.Models._resolve_target_model,
                                    driver.fields[key].to, models_module) !== nothing
        end
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

"""
    import_one_app(source; kwargs...) -> (generated_text, config_key, db_dir_existed)

The SINGLE-APP arity under a throwaway config with no `django_prefix` — the default call, and the
one configuration in which nothing pins a table. Callers must `cleanup_project_test!` in a `finally`.
"""
function import_one_app(source::String; output_file::String = "django_one_app_unit.jl", kwargs...)
    config_key, db_dir_existed = project_config!()
    import_models_from_django(source; db = config_key, file = output_file, force_replace = true,
                              kwargs...)
    return read(joinpath(config_key, output_file), String), config_key, db_dir_existed
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a rename NEVER moves the physical table
#
# The positional slot of `Models.Model(...)` IS the table whenever nothing pins `db_table`, and with
# no app label nothing does. Pass 1 rewrites `entry.name` for a `binding_overrides` entry and for the
# digit backstop, so on that path a rename silently re-pointed the model at a table Django never
# created: `class Circuit` overridden to `Pista` emitted `Models.Model("pista")`, and `class CASCADE`
# emitted `Models.Model("cascade2")` where the pre-#346 importer correctly emitted `"cascade"`.
#
# `Model_to_str` has enforced the rule since #338 — a dedup that changes the name pins the PRE-dedup
# one (`src/Models.jl`) — and moving the dedup into pass 1 bypassed it, because the name it now
# receives is already unique so its own dedup never fires. These lock the rule at the new site.
#
# The whole defect class was invisible to the suite before: every `binding_overrides` test uses the
# MULTI-APP arity, where the app label pins a table for every model unconditionally.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unlabelled binding_overrides rename pins the table it renamed away from (#346)" begin
    generated, config_key, db_dir_existed = import_one_app("""
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=50)
""";
        output_file = "django_one_app_override.jl",
        binding_overrides = Dict("Circuit" => "Pista"))
    try
        # The handle is the caller's choice; the TABLE stays Django's. Before the fix this line was
        # `Pista = Models.Model("pista",` with no `db_table` anywhere in the file.
        @test occursin("Pista = Models.Model(\"pista\", db_table = \"circuit\"", generated)

        # Stronger than the string: the model PormG actually builds must ADDRESS Django's table.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        pista = Core.eval(sandbox, :(django_one_app_override.Pista))
        @test Base.invokelatest(PormG.Models.model_table_name, pista) == "circuit"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

@testset "an unlabelled digit-backstop rename pins the pre-rename table (#346)" begin
    # `CASCADE` is reserved by the generated module's own `import PormG.Models: ... CASCADE ...`, so
    # the backstop fires and renames the handle to `CASCADE2`.
    generated, config_key, db_dir_existed = import_one_app("""
from django.db import models

class CASCADE(models.Model):
    name = models.CharField(max_length=50)
""";
        output_file = "django_one_app_backstop.jl")
    try
        # Pre-#346 emitted `Models.Model("cascade")`; the branch regressed it to `"cascade2"` with
        # nothing pinned. Both the handle rename AND the real table, together.
        @test occursin("CASCADE2 = Models.Model(\"cascade2\", db_table = \"cascade\"", generated)

        # The marker says "Its db_table below still names the real table" — assert that claim is
        # TRUE, not merely that a marker exists. `occursin("# PormG:", ...)` was the first thing
        # written here and it is green theater: the marker was ALWAYS emitted, and the defect was
        # that the `db_table` it promised was absent. Pin the promise and the thing promised.
        @test occursin("Its db_table below still names the real table", generated)
        @test occursin("db_table = \"cascade\"", generated)

        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        renamed = Core.eval(sandbox, :(django_one_app_backstop.CASCADE2))
        @test Base.invokelatest(PormG.Models.model_table_name, renamed) == "cascade"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the collision pass counts what `Model_to_str` actually dedups on
#
# Under a pinned table `Model_to_str` dedups the positional name on `lstrip(lowercase(name), '_')`.
# The importer compared on a plain `lowercase`, a FINER relation, so `_Foo` and `Foo` in one app
# looked distinct here and identical there: they slipped past app-qualification and were renamed
# `foo` / `foo2` by declaration order, silently and with no marker — the exact outcome the pass
# exists to prevent.
#
# The mirror defect: both equivalences were counted in ONE dictionary, and for a leading-underscore
# otherwise-lowercase class the binding and the positional key are the same string, so a single entry
# bumped one key twice and read its own contribution back as a 2-way collision.
# ─────────────────────────────────────────────────────────────────────────────
@testset "`_Foo` and `Foo` in one app are a collision, not a silent rename (#346)" begin
    generated, config_key, db_dir_existed = import_project(["racing" => """
from django.db import models

class _Foo(models.Model):
    name = models.CharField(max_length=50)

class Foo(models.Model):
    name = models.CharField(max_length=50)
"""]; output_file = "django_project_strip_clash.jl")
    try
        # Both sides app-qualified, both tables distinct and correct.
        @test occursin("Racing__foo = Models.Model(\"racing__foo\", db_table = \"racing__foo\"", generated)
        @test occursin("Racing_foo = Models.Model(\"racing_foo\", db_table = \"racing_foo\"", generated)
        # The old outcome: one of them silently became the positional name `foo2`.
        @test !occursin("foo2", generated)

        # Distinct bindings AND distinct tables — one table serving two models is the real damage.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        underscored = Core.eval(sandbox, :(django_project_strip_clash.Racing__foo))
        plain = Core.eval(sandbox, :(django_project_strip_clash.Racing_foo))
        @test Base.invokelatest(PormG.Models.model_table_name, underscored) == "racing__foo"
        @test Base.invokelatest(PormG.Models.model_table_name, plain) == "racing_foo"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

@testset "a lone leading-underscore class does not collide with itself (#346)" begin
    generated, config_key, db_dir_existed = import_project(["racing" => """
from django.db import models

class _thing(models.Model):
    name = models.CharField(max_length=50)
"""]; output_file = "django_project_self_clash.jl")
    try
        # The ONLY class in the project has nothing to collide with, so it keeps its derived binding.
        # It used to app-qualify itself to `Racing__thing` for nothing.
        @test occursin("_thing = Models.Model(\"thing\", db_table = \"racing__thing\"", generated)
        @test !occursin("Racing__thing = Models.Model(", generated)

        # The table is Django's either way — this one is about not inventing a rename, so assert the
        # binding survived rather than only that the table is right.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Core.eval(sandbox, :(isdefined(django_project_self_clash, :_thing)))
        thing = Core.eval(sandbox, :(django_project_self_clash._thing))
        @test Base.invokelatest(PormG.Models.model_table_name, thing) == "racing__thing"
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): the collision key is EXACT, not merely conservative
#
# `Model_to_str` strips leading underscores from the positional name only when a `db_table` is
# pinned. So `_Internal` and `Internal` in an UNLABELLED import — no app label, no `Meta.db_table`,
# nothing pinned — are deduped on plain `lowercase` and do not collide at any layer.
#
# Comparing them on the stripped key anyway looked like the safe direction, and is not: step 1
# app-qualification is skipped for unlabelled entries, so the manufactured conflict falls through to
# the digit backstop, which renames whichever class was declared SECOND. That replaces a silent
# order-dependent rename with a loud one instead of removing it — and order-independence is the
# property these passes exist to establish. Both declaration orders must come out clean.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an unlabelled `_Internal`/`Internal` pair is not a collision, in either order (#346)" begin
    for (label, source, outfile) in (
            ("declared _Internal first", """
from django.db import models

class _Internal(models.Model):
    name = models.CharField(max_length=50)

class Internal(models.Model):
    name = models.CharField(max_length=50)
""", "django_one_app_orderA.jl"),
            ("declared Internal first", """
from django.db import models

class Internal(models.Model):
    name = models.CharField(max_length=50)

class _Internal(models.Model):
    name = models.CharField(max_length=50)
""", "django_one_app_orderB.jl"))
        generated, config_key, db_dir_existed = import_one_app(source; output_file = outfile)
        try
            # Neither class is renamed, so neither needs a marker and neither needs a pinned table.
            @test !occursin("internal2", generated)
            @test !occursin("# PormG:", generated)
            @test !occursin("db_table", generated)
            # Both keep the name Django derives, whichever order they were declared in.
            @test occursin("_Internal = Models.Model(\"_internal\"", generated)
            @test occursin("\nInternal = Models.Model(\"internal\"", generated)
        finally
            cleanup_project_test!(config_key, db_dir_existed)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): an override that takes a derived name RAISES, whatever it collided on
#
# The backstop exists for collisions nobody can avoid, explicitly "not to quietly rename a model the
# caller never mentioned because a keyword took its name", and `docs/src/import_django.md` promises
# every violation raises rather than falling back. That guard reads `claimed_by`, which was keyed on
# the BINDING alone while `conflicts` tested two keys — so a POSITIONAL collision found no claimant,
# reported `nothing`, and took the silent path the guard was written to prevent.
#
# `Dict("Circuit" => "PESSOA")` beside `class Pessoa` is the sharp case: no underscores, one app, and
# `PESSOA`/`Pessoa` are different bindings that share the positional name `pessoa`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an override colliding on the POSITIONAL name raises, naming the real claimant (#346)" begin
    config_key, db_dir_existed = project_config!()
    try
        err = nothing
        try
            import_models_from_django(["core" => """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=50)

class Pessoa(models.Model):
    name = models.CharField(max_length=50)
"""]; db = config_key, file = "django_project_pos_clash.jl", force_replace = true,
                 binding_overrides = Dict("Circuit" => "PESSOA"))
        catch e
            err = e
        end
        # It used to renaming `core.Pessoa` to `Pessoa2` and blame "the generated module's own
        # imports" in the marker — a model the caller never mentioned, silently moved.
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        # The message must name the override the caller actually typed, not a reserved binding.
        @test occursin("binding_overrides", msg)
        @test occursin("core.Pessoa", msg)
    finally
        cleanup_project_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#370): a base resolves across apps only when the module imported it.
#
# #346 resolved every app's bases against every app's classes, by NAME. That is what merges a shared
# `core.models.TimeStampedModel` — and it is also how a base an app inherits from a THIRD-PARTY
# library resolved against an unrelated app's class of the same name. When that class was concrete
# the child was refused as multi-table inheritance and its table vanished from the generated file:
# adding an app to the import REMOVED a table belonging to another app, which Python's per-module
# namespaces make impossible.
#
# The rule is now Python's own — an app's own classes win, and anything else must have been imported.
# ─────────────────────────────────────────────────────────────────────────────

@testset "a base from a third-party library does not collide with another app's class (#370)" begin
    # `reports` inherits BaseReport from a library. `billing` happens to declare a CONCRETE class of
    # the same name and knows nothing about `reports`. Before #370 the two were the same name and so
    # the same class, and `Relatorio` was refused as multi-table inheritance and dropped.
    reports = """
from django.db import models
from library.base import BaseReport

class Relatorio(BaseReport):
    titulo = models.CharField(max_length=80)
"""
    billing = """
from django.db import models

class BaseReport(models.Model):
    total = models.IntegerField()
"""
    generated, key, existed = import_project(["reports" => reports, "billing" => billing];
                                             output_file = "crossapp_thirdparty.jl")
    try
        # The table is HERE. This assertion is the issue.
        @test occursin("Relatorio = Models.Model(\"relatorio\", db_table = \"reports_relatorio\"", generated)
        @test occursin("titulo = Models.CharField(max_length=80)", generated)
        # ...and it is not refused for inheritance it never had.
        @test !occursin("Django multi-table inheritance", generated)
        # `billing`'s own class is untouched by any of this.
        @test occursin("BaseReport = Models.Model(\"basereport\", db_table = \"billing_basereport\"", generated)
        # The marker still reports the missing columns, and now says why the same-named class next
        # door was not used — and says it accurately. `reports` DOES import `BaseReport`; claiming
        # it does not would be a plain lie, and the useful fact is where it imports it from.
        @test occursin("'BaseReport' is declared by app 'billing', but app 'reports' imports it " *
                       "from 'library.base', which this import could not match to any app — so " *
                       "they were not treated as the same class", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # The invariant behind the issue title: adding an app must never REMOVE a table.
    alone, key2, existed2 = import_project(["reports" => reports];
                                           output_file = "alone_thirdparty.jl")
    try
        @test occursin("Relatorio = Models.Model(", alone)
    finally
        cleanup_project_test!(key2, existed2)
    end
end

@testset "an imported base still merges, and a concrete one is still refused (#370)" begin
    core = """
from django.db import models

class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        abstract = True

class Venda(models.Model):
    total = models.IntegerField()
"""
    good = """
from django.db import models
from core.models import TimeStampedModel

class Pedido(TimeStampedModel):
    obs = models.CharField(max_length=40)
"""
    generated, key, existed = import_project(["core" => core, "shop" => good];
                                             output_file = "gate_merge.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test !occursin("not defined in", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # A CONCRETE base, genuinely imported, is still multi-table inheritance and still refused —
    # gating the lookup must not cost the refusal that keeps a wrong primary key off the disk.
    mti = """
from django.db import models
from core.models import Venda

class Pedido(Venda):
    obs = models.CharField(max_length=40)
"""
    generated2, key2, existed2 = import_project(["core" => core, "shop" => mti];
                                                output_file = "gate_mti.jl")
    try
        @test occursin("Django multi-table inheritance", generated2)
        @test !occursin("Pedido = Models.Model", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end

    # The same abstract base, NOT imported: no merge, and the columns are reported missing rather
    # than silently taken from a class this module cannot see.
    ungated = """
from django.db import models

class Pedido(TimeStampedModel):
    obs = models.CharField(max_length=40)
"""
    generated3, key3, existed3 = import_project(["core" => core, "shop" => ungated];
                                                output_file = "gate_ungated.jl")
    try
        @test !occursin("created_at", generated3)
        @test occursin("not defined in any app of this import", generated3)
        # Here the module really did NOT import it, so that is what the hint says.
        @test occursin("'TimeStampedModel' is declared by app 'core', but app 'shop' does not " *
                       "import it — add the import if that is what you meant", generated3)
        # The table itself survives — a missing base never costs a table.
        @test occursin("Pedido = Models.Model(", generated3)
    finally
        cleanup_project_test!(key3, existed3)
    end
end

@testset "a base's own bases resolve in ITS app, not the importing one (#370)" begin
    # Two-hop abstract chain. `shop` imports only `Auditavel`, whose own base exists solely in
    # `core`. Resolving that in the IMPORTING app's namespace loses it, which makes `Auditavel`
    # field-less and therefore not-a-model, which poisons `Pedido` — and `Pedido` is then dropped
    # with no marker at all. Strictly worse than the defect #370 set out to remove.
    core = """
from django.db import models

class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        abstract = True

class Auditavel(TimeStampedModel):
    class Meta:
        abstract = True
"""
    shop = """
from django.db import models
from core.models import Auditavel

class Pedido(Auditavel):
    obs = models.CharField(max_length=40)
"""
    generated, key, existed = import_project(["core" => core, "shop" => shop];
                                             output_file = "twohop.jl")
    try
        @test occursin("Pedido = Models.Model(", generated)
        # The grandparent's column arrives through a base that declares none of its own.
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test occursin("obs = Models.CharField(max_length=40)", generated)
        @test !occursin("not defined in", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "a class name two apps share does not fabricate an inheritance cycle (#370)" begin
    # Fails before this change. `core.Bar` reaches its base `Foo` while `l.Foo` is mid-classification
    # and a BARE-NAME `visiting` set reads that as a cycle: `core.Bar` is refused, which poisons
    # `l.Foo`, which is dropped in silence. The two `Foo`s are different classes in different
    # modules, and only a name-keyed table could confuse them.
    core = """
from django.db import models

class Foo(models.Model):
    a = models.IntegerField()

    class Meta:
        abstract = True

class Bar(Foo):
    shared = models.CharField(max_length=10)

    class Meta:
        abstract = True
"""
    l = """
from django.db import models
from core.models import Bar

class Foo(Bar):
    b = models.IntegerField()
"""
    generated, key, existed = import_project(["core" => core, "l" => l];
                                             output_file = "false_cycle.jl")
    try
        # On `main`, classifying `l.Foo` marks the bare name "Foo" as in-progress; the walk into
        # `core.Bar` then resolves ITS base `Foo` through an own-app-first flat index straight back
        # to `l.Foo`, reads that as a cycle, and drops the model without a word. Here it is emitted.
        @test occursin("Foo = Models.Model(\"foo\", db_table = \"l_foo\"", generated)
        # And it carries the whole chain: its own column, `core.Bar`'s, and `core.Foo`'s.
        @test occursin("b = Models.IntegerField()", generated)
        @test occursin("shared = Models.CharField(max_length=10)", generated)
        @test occursin("a = Models.IntegerField()", generated)
        # Both `core` classes are abstract, so neither emits a table of its own.
        @test !occursin("core_foo", generated)
        @test !occursin("Bar = Models.Model", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "an alias, a star import and a re-export all resolve a base (#370)" begin
    core = """
from django.db import models

class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        abstract = True
"""
    # `from core.models import X as Y` — the base is spelled by its LOCAL name.
    aliased = """
from django.db import models
from core.models import TimeStampedModel as TSM

class Pedido(TSM):
    obs = models.CharField(max_length=40)
"""
    generated, key, existed = import_project(["core" => core, "shop" => aliased];
                                             output_file = "alias.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test !occursin("not defined in", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # `from core.models import *` binds names no parser can enumerate, so the whole app comes into
    # scope rather than none of it.
    starred = """
from django.db import models
from core.models import *

class Pedido(TimeStampedModel):
    obs = models.CharField(max_length=40)
"""
    generated2, key2, existed2 = import_project(["core" => core, "shop" => starred];
                                                output_file = "star.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated2)
        @test !occursin("not defined in", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end

    # A re-export façade: `shop` imports from `access`, which imported it from `core` and declares no
    # such class of its own. Stopping at `access` would be a fresh silent loss.
    access = """
from django.db import models
from core.models import TimeStampedModel

class Perfil(TimeStampedModel):
    nome = models.CharField(max_length=20)
"""
    downstream = """
from django.db import models
from access.models import TimeStampedModel

class Pedido(TimeStampedModel):
    obs = models.CharField(max_length=40)
"""
    generated3, key3, existed3 = import_project(["core" => core, "access" => access,
                                                 "shop" => downstream];
                                                output_file = "reexport.jl")
    try
        @test occursin("Pedido = Models.Model(", generated3)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated3)
        @test !occursin("not defined in", generated3)
    finally
        cleanup_project_test!(key3, existed3)
    end
end

@testset "a module path names an app by label or by package directory (#370)" begin
    # `Page` is here so the vendor-path sub-test below can actually FAIL when the rule is wrong.
    # Without a concrete class of that name in `core`, `from wagtail.core.models import Page` leaves
    # `Page` unresolved either way, `Artigo` is emitted either way, and the assertion passes whether
    # or not the module path was matched — a test that cannot see the bug it was written for.
    core = """
from django.db import models

class TimeStampedModel(models.Model):
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        abstract = True

class Pedido(models.Model):
    total = models.IntegerField()

class Page(models.Model):
    slug = models.CharField(max_length=30)
"""
    # A nested app package. A LEFT-to-right first-component match would stop at `apps` and resolve
    # nothing, which is why the scan runs right to left — but what makes `apps` acceptable here is
    # that the app's models.py really does live under `apps/`, so a PATH is required.
    nest_root = mktempdir()
    mkpath(joinpath(nest_root, "apps", "core"))
    write(joinpath(nest_root, "apps", "core", "models.py"), core)
    nested = """
from django.db import models
from apps.core.models import TimeStampedModel

class Nota(TimeStampedModel):
    texto = models.CharField(max_length=20)
"""
    generated, key, existed = import_project(
        ["core" => joinpath(nest_root, "apps", "core", "models.py"), "shop" => nested];
        output_file = "nested_pkg.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test !occursin("not defined in", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # The same app package re-exporting through its `__init__.py`, still qualified by `apps`.
    pkg_nested = """
from django.db import models
from apps.core import TimeStampedModel

class Nota(TimeStampedModel):
    texto = models.CharField(max_length=20)
"""
    generated5, key5, existed5 = import_project(
        ["core" => joinpath(nest_root, "apps", "core", "models.py"), "shop" => pkg_nested];
        output_file = "nested_pkg_init.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated5)
        @test !occursin("not defined in", generated5)
    finally
        cleanup_project_test!(key5, existed5)
    end

    # A THIRD-PARTY package whose own layout happens to contain the app's name followed by `models`.
    # `wagtail.core.models` is the canonical Wagtail import, and matching "an app key with `models`
    # after it" anywhere in the path read it as this project's `core` — #370 all over again. What
    # rejects it is that `wagtail` is not where `core/models.py` actually lives.
    vendor = """
from django.db import models
from wagtail.core.models import Page

class Artigo(Page):
    corpo = models.CharField(max_length=100)
"""
    generated6, key6, existed6 = import_project(
        ["core" => joinpath(nest_root, "apps", "core", "models.py"), "cms" => vendor];
        output_file = "vendor_models_tail.jl")
    try
        @test occursin("Artigo = Models.Model(\"artigo\", db_table = \"cms_artigo\"", generated6)
        @test occursin("corpo = Models.CharField(max_length=100)", generated6)
        @test !occursin("Django multi-table inheritance", generated6)
    finally
        cleanup_project_test!(key6, existed6)
        rm(nest_root; recursive = true, force = true)
    end

    # A SIBLING module of the same app is not its models module. `core/forms.py` may perfectly well
    # declare its own `Pedido`, and binding that to the model `core/models.py` declares would be
    # #370 one module over.
    from_forms = """
from django.db import models
from core.forms import Pedido

class Recibo(Pedido):
    valor = models.IntegerField()
"""
    generated2, key2, existed2 = import_project(["core" => core, "shop" => from_forms];
                                                output_file = "sibling_module.jl")
    try
        @test !occursin("Django multi-table inheritance", generated2)
        @test occursin("Recibo = Models.Model(", generated2)
        @test occursin("not defined in any app of this import", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end

    # The label is often NOT the package directory — Django's `AppConfig.label` frequently differs.
    # A pair given as a PATH carries the directory as a second key, so an import spelling the package
    # name resolves even though the label differs.
    dir_root = mktempdir()
    mkpath(joinpath(dir_root, "customers"))
    write(joinpath(dir_root, "customers", "models.py"), core)
    by_package = """
from django.db import models
from customers.models import TimeStampedModel

class Nota(TimeStampedModel):
    texto = models.CharField(max_length=20)
"""
    generated3, key3, existed3 = import_project(["crm" => joinpath(dir_root, "customers", "models.py"),
                                                 "shop" => by_package];
                                                output_file = "label_vs_dir.jl")
    try
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated3)
        @test !occursin("not defined in", generated3)
        # The label still drives the table prefix; only the LOOKUP accepts either spelling.
        @test occursin("db_table = \"crm_pedido\"", generated3)
    finally
        cleanup_project_test!(key3, existed3)
        rm(dir_root; recursive = true, force = true)
    end
end

@testset "a class with no resolvable base and no field of its own is not dropped in silence (#370)" begin
    # Every column this class might have lives in a base the importer cannot see, so there is no
    # evidence either way and it is skipped — but skipping it without a word is exactly how a real
    # model disappears leaving no trace. A DOTTED base is a different case and stays silent: it names
    # a module, so it is a helper by construction.
    src = """
from django.db import models

class Perfil(CustomUser):
    pass

class ContatoForm(forms.Form):
    pass

class Real(models.Model):
    nome = models.CharField(max_length=10)
"""
    generated, key, existed = import_project(["app" => src]; output_file = "silent_drop.jl")
    try
        @test occursin("Real = Models.Model(", generated)
        @test !occursin("Perfil = Models.Model", generated)
        @test occursin("# PormG: class 'Perfil' inherits 'CustomUser'", generated)
        @test occursin("declares no field of its own", generated)
        # A `forms.Form` helper produces no noise — the namespace already settles what it is.
        @test !occursin("ContatoForm", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "a module-level enum crosses apps only when imported (#370)" begin
    core = """
from django.db import models

class Status(models.TextChoices):
    DRAFT = "d", "Draft"
    SENT = "s", "Sent"
"""
    # `shop` never imports `Status` and declares no enum of its own. Before #370 it silently received
    # `core`'s enumeration — no marker anywhere, and the wrong choices reached the schema.
    shop = """
from django.db import models

class Batch(models.Model):
    situacao = models.CharField(max_length=1, choices=Status.choices)
"""
    generated, key, existed = import_project(["core" => core, "shop" => shop];
                                             output_file = "enum_ungated.jl")
    try
        @test !occursin("(\"d\", \"Draft\")", generated)
        @test occursin("Batch = Models.Model(", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # Imported, so it resolves — including through an alias.
    shop2 = """
from django.db import models
from core.models import Status as S

class Batch(models.Model):
    situacao = models.CharField(max_length=1, choices=S.choices, default=S.DRAFT)
"""
    generated2, key2, existed2 = import_project(["core" => core, "shop" => shop2];
                                                output_file = "enum_gated.jl")
    try
        @test occursin("choices=((\"d\", \"Draft\"), (\"s\", \"Sent\"))", generated2)
        @test occursin("default=\"d\"", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end

    # An app declaring its OWN `Status` keeps it, whatever another app imported into scope.
    shop3 = """
from django.db import models
from core.models import Status

class Batch(models.Model):
    situacao = models.CharField(max_length=1, choices=Status.choices)

class Status(models.TextChoices):
    OPEN = "o", "Open"
"""
    generated3, key3, existed3 = import_project(["core" => core, "shop" => shop3];
                                                output_file = "enum_local_wins.jl")
    try
        @test occursin("(\"o\", \"Open\")", generated3)
        @test !occursin("(\"d\", \"Draft\")", generated3)
    finally
        cleanup_project_test!(key3, existed3)
    end
end

@testset "a cross-app AbstractUser chain resolves only when imported (#370)" begin
    # `settings.AUTH_USER_MODEL` auto-detection walks the abstract chain to find the single
    # AbstractUser subclass. If gating broke that walk the reference would stop resolving — the one
    # regression shape that turns a working import into a FAILING one rather than a marked one.
    core = """
from django.contrib.auth.models import AbstractUser

class BaseUser(AbstractUser):
    class Meta:
        abstract = True
"""
    access = """
from django.db import models
from core.models import BaseUser

class User(BaseUser):
    matricula = models.CharField(max_length=20)
"""
    racing = """
from django.conf import settings
from django.db import models

class Race(models.Model):
    reported_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE)
"""
    generated, key, existed = import_project(["core" => core, "access" => access,
                                              "racing" => racing];
                                             output_file = "auth_chain.jl")
    try
        # The AbstractUser columns reached `User` through the imported abstract base...
        @test occursin("username = Models.CharField", generated)
        # ...so AUTH_USER_MODEL found its single candidate and the FK resolves to it.
        @test occursin("reported_by_id = Models.ForeignKey(\"User\"", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "a module path matches an app only where the app's models module follows (#370)" begin
    # The first cut of #370 accepted a match on the LAST component of any path, which let a
    # third-party module resolve into an app whose label happened to equal that component — the
    # original defect, one module name over. Every case here failed that way.
    core = """
from django.db import models

class Page(models.Model):
    slug = models.CharField(max_length=30)

class Perfil(models.Model):
    apelido = models.CharField(max_length=30)
"""
    # `wagtail.core` ends in `core`, and `core` is a real app in this run.
    cms = """
from django.db import models
from wagtail.core import Page

class Artigo(Page):
    corpo = models.CharField(max_length=100)
"""
    generated, key, existed = import_project(["core" => core, "cms" => cms];
                                             output_file = "thirdparty_tail.jl")
    try
        @test occursin("Artigo = Models.Model(\"artigo\", db_table = \"cms_artigo\"", generated)
        @test occursin("corpo = Models.CharField(max_length=100)", generated)
        @test !occursin("Django multi-table inheritance", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # A SINGLE-dot import names a submodule of the app doing the importing. Stripping the dot leaves
    # `core`, a perfectly ordinary app label — so one dot must never be read as naming another app,
    # with or without a `models` tail.
    for (name, line) in (("dot_pkg", "from .core import Perfil"),
                         ("dot_models", "from .core.models import Perfil"))
        shop = """
from django.db import models
$(line)

class Conta(Perfil):
    saldo = models.IntegerField()
"""
        generated2, key2, existed2 = import_project(["core" => core, "shop" => shop];
                                                    output_file = "relative_$(name).jl")
        try
            @test occursin("Conta = Models.Model(\"conta\", db_table = \"shop_conta\"", generated2)
            @test !occursin("Django multi-table inheritance", generated2)
        finally
            cleanup_project_test!(key2, existed2)
        end
    end

    # TWO dots ascend to the parent package, which is how a project laid out as `apps/{core,shop}/`
    # spells a genuine cross-app import. That one must resolve.
    ascending = """
from django.db import models
from ..core.models import Perfil

class Conta(Perfil):
    saldo = models.IntegerField()
"""
    generated4, key4, existed4 = import_project(["core" => core, "shop" => ascending];
                                                output_file = "relative_ascend.jl")
    try
        # Genuinely imported and genuinely concrete, so this IS multi-table inheritance.
        @test occursin("Django multi-table inheritance", generated4)
    finally
        cleanup_project_test!(key4, existed4)
    end

    # The one absolute single-component form IS the app package, re-exporting through `__init__.py`.
    pkg = """
from django.db import models
from core import Perfil

class Conta(Perfil):
    saldo = models.IntegerField()
"""
    generated3, key3, existed3 = import_project(["core" => core, "shop" => pkg];
                                                output_file = "bare_package.jl")
    try
        # Genuinely imported and genuinely concrete, so this one IS multi-table inheritance.
        @test occursin("Django multi-table inheritance", generated3)
    finally
        cleanup_project_test!(key3, existed3)
    end
end

@testset "two apps declaring the same class name keep their own nested enums (#370)" begin
    # The base resolved correctly here from the very first cut; it was the ENUM scope table that was
    # still flat and name-keyed, so `core.Base`'s own field silently took `shop.Base`'s members.
    # Nothing in the generated file said so — the same silent-wrong-schema class as #370 itself.
    core = """
from django.db import models

class Base(models.Model):
    class Situacao(models.TextChoices):
        ATIVO = "A", "Ativo"

    situacao = models.CharField(max_length=1, choices=Situacao.choices)

    class Meta:
        abstract = True
"""
    shop = """
from django.db import models
from core.models import Base as CoreBase

class Base(models.Model):
    class Situacao(models.TextChoices):
        OUTRO = "O", "Outro"

    class Meta:
        abstract = True

class Pedido(CoreBase):
    total = models.IntegerField()
"""
    generated, key, existed = import_project(["core" => core, "shop" => shop];
                                             output_file = "enum_class_scope.jl")
    try
        # `Pedido` inherits `core.Base`, so its `situacao` must carry CORE's members.
        @test occursin("situacao = Models.CharField(max_length=1, choices=((\"A\", \"Ativo\"),))",
                       generated)
        @test !occursin("\"Outro\"", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "a module-level enum resolves through a re-export, as a base does (#370)" begin
    # Base resolution followed a re-export façade from the start; enum resolution did not, so an
    # identically-shaped project resolved the base and dropped the enumeration — with a marker
    # telling the reader to import a module they had already imported.
    core = """
from django.db import models

class Status(models.TextChoices):
    DRAFT = "d", "Draft"
"""
    access = """
from django.db import models
from core.models import Status
"""
    shop = """
from django.db import models
from access.models import Status

class Batch(models.Model):
    situacao = models.CharField(max_length=1, choices=Status.choices, default=Status.DRAFT)
"""
    generated, key, existed = import_project(["core" => core, "access" => access, "shop" => shop];
                                             output_file = "enum_reexport.jl")
    try
        @test occursin("choices=((\"d\", \"Draft\"),)", generated)
        @test occursin("default=\"d\"", generated)
        @test !occursin("which this file does not define", generated)
    finally
        cleanup_project_test!(key, existed)
    end
end

@testset "star-import order does not decide whether a base resolves (#370)" begin
    # `seen` guarding the re-export walk was keyed by APP, not by (app, name). An app already
    # visited for one token then answered `nothing` for a different token, so which of two
    # `from … import *` lines came first decided whether the base resolved at all.
    y = """
from django.db import models

class Foo(models.Model):
    ycol = models.IntegerField()

    class Meta:
        abstract = True

class Bar(models.Model):
    bcol = models.IntegerField()

    class Meta:
        abstract = True
"""
    x = """
from django.db import models
from y.models import Foo, Bar
"""
    b = """
from django.db import models
from x.models import *
"""
    c = """
from django.db import models
from x.models import Bar as Foo
"""
    for (label, first, second) in (("c_then_b", "c", "b"), ("b_then_c", "b", "c"))
        a = """
from django.db import models
from $(first).models import *
from $(second).models import *

class Conta(Foo):
    own = models.IntegerField()
"""
        generated, key, existed = import_project(["y" => y, "x" => x, "b" => b, "c" => c,
                                                  "a" => a];
                                                 output_file = "star_order_$(label).jl")
        try
            # Whichever order the two star imports appear in, `Foo` resolves and its column arrives.
            @test occursin("Conta = Models.Model(", generated)
            @test !occursin("not defined in any app of this import", generated)
        finally
            cleanup_project_test!(key, existed)
        end
    end
end

@testset "a skipped no-field class names the module its base came from (#370)" begin
    # `ancestry_lost` exists for a class that MIGHT be a model whose columns all live in a base the
    # importer cannot see. "The base came from a module naming no app" does NOT settle that: a
    # third-party library and an app the caller forgot to pass are the same string — and in the
    # single-app arity there are no app keys at all, so that test is true for every imported base
    # and the marker would never fire for the case it exists for. The module goes in the message.
    src = """
from django.db import models
from model_utils.managers import InheritanceManager

class MeuManager(InheritanceManager):
    pass

class Perfil(CustomUser):
    pass

class Real(models.Model):
    nome = models.CharField(max_length=10)
"""
    generated, key, existed = import_project(["app" => src]; output_file = "thirdparty_helper.jl")
    try
        @test occursin("Real = Models.Model(", generated)
        # Named, so a reader dismisses the library in one glance...
        @test occursin("# PormG: class 'MeuManager' inherits 'InheritanceManager', imported from " *
                       "'model_utils.managers', which nothing in this import defines", generated)
        # ...and a base with no import line at all says exactly that instead.
        @test occursin("# PormG: class 'Perfil' inherits 'CustomUser', which nothing in this " *
                       "import defines and this models.py does not import", generated)
        @test !occursin("Perfil = Models.Model", generated)
    finally
        cleanup_project_test!(key, existed)
    end

    # The single-app arity is where this matters most, and where the discarded guard disabled it
    # outright: an app whose base lives in a sibling app the caller did not pass.
    single = """
from django.db import models
from core.models import TimeStampedModel

class Pedido(TimeStampedModel):
    pass

class Outro(models.Model):
    nome = models.CharField(max_length=10)
"""
    generated2, key2, existed2 = import_one_app(single; output_file = "single_ancestry_lost.jl")
    try
        @test occursin("# PormG: class 'Pedido' inherits 'TimeStampedModel', imported from " *
                       "'core.models', which nothing in this import defines", generated2)
        @test occursin("\"<app_label>\" => \"<models.py>\" pairs", generated2)
    finally
        cleanup_project_test!(key2, existed2)
    end
end
