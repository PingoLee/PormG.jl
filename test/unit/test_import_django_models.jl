using Test
using Logging
using PormG
using PormG.Migrations

function import_fixture_to_temp(fixture; output_file = "django_models_from_txt_unit.jl", force_replace = true)
    config_key, db_dir_existed = temp_import_config!()

    import_models_from_django(
        fixture;
        db = config_key,
        file = output_file,
        force_replace = force_replace,
    )

    return config_key, db_dir_existed, joinpath(config_key, output_file)
end

"""
    temp_import_config!(; django_prefix = nothing)

Register a throwaway config keyed on a fresh temp directory. `django_prefix` defaults to `nothing`
(the unprefixed case every pre-#345 testset in this file relies on); pass an app label to exercise
the prefixed path, where the prefix lands in `db_table` rather than in the positional model name.
"""
function temp_import_config!(; django_prefix::Union{Nothing, String} = nothing)
    config_key = mktempdir()
    db_dir_existed = isdir(PormG.MODEL_PATH)

    PormG.config[config_key] = PormG.Configuration.Settings(
        db_def_folder = config_key,
        django_prefix = django_prefix,
    )

    return config_key, db_dir_existed
end

"""
    import_django_source(source; django_prefix = nothing, output_file = ...)

Import `source` under a throwaway config and return `(generated_text, config_key, db_dir_existed)`.
Callers must `cleanup_import_test!(config_key, db_dir_existed)` in a `finally`.
"""
function import_django_source(source::String;
                              django_prefix::Union{Nothing, String} = nothing,
                              output_file::String = "django_345_unit.jl")
    config_key, db_dir_existed = temp_import_config!(django_prefix = django_prefix)
    import_models_from_django(source; db = config_key, file = output_file, force_replace = true)
    return read(joinpath(config_key, output_file), String), config_key, db_dir_existed
end

function cleanup_import_test!(config_key, db_dir_existed)
    delete!(PormG.config, config_key)

    isdir(config_key) && rm(config_key; recursive = true)

    if !db_dir_existed && isdir(PormG.MODEL_PATH) && isempty(readdir(PormG.MODEL_PATH))
        rm(PormG.MODEL_PATH)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: txt file input generates PormG model definitions
# This verifies that import_models_from_django accepts a path to Django model
# text and writes Julia model declarations without requiring a live database.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reads model definitions from txt path" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_from_txt.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(fixture)

    try
        @test isfile(generated_path)

        generated = read(generated_path, String)
        @test occursin("module django_models_from_txt_unit", generated)
        @test occursin("Dim_municipio = Models.Model(\"dim_municipio\"", generated)
        @test occursin("servidor_id = Models.ForeignKey(\"Dim_servidor\"", generated)
        @test occursin("on_delete=RESTRICT", generated)
        @test occursin("nu_cnes_temp_id = Models.ForeignKey(\"Dim_CNES\"", generated)
        @test occursin("on_delete=SET_NULL", generated)
        @test occursin("vaccine_def = Models.JSONField(blank=true, null=true)", generated)
        @test occursin("CustomUser = Models.Model(\"customuser\"", generated)
        @test occursin("password = Models.CharField()", generated)
        @test occursin("PasswordResetToken = Models.Model(\"passwordresettoken\"", generated)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test occursin("ReporteProblema = Models.Model(\"reporteproblema\"", generated)
        @test occursin("imagem = Models.ImageField(blank=true, null=true, editable=true)", generated)
        @test occursin("retorno = Models.TextField(blank=true, default=\"\")", generated)
        @test occursin("retorno_por_id = Models.ForeignKey(\"CustomUser\"", generated)
        @test occursin("related_name=\"reportes_respondidos\"", generated)
        @test occursin("usuario_lido_em = Models.DateTimeField(blank=true, null=true)", generated)
        @test occursin("Cust_adminHOD = Models.Model(\"cust_adminhod\"", generated)
        # `id` is emitted as `id`, not `_id` (#317): it was only ever prefixed because PormG's
        # `reserved_words` list wrongly carried it — it is an ordinary Julia identifier.
        #
        # The DECLARED `id = models.AutoField(primary_key=True)` on `Cust_adminHOD` now renders as
        # `IDField` (#399), which every synthetic `id` in this file also renders as — so the
        # rendered line alone no longer pins the name to THIS class. The marker does: it names the
        # class and the field, and it is emitted only for the declaration, never for a synthetic id.
        @test occursin("field 'id' on 'Cust_adminHOD' is a Django AutoField (INTEGER)", generated)
        @test occursin("id = Models.IDField()", generated)
        @test !occursin("_id = Models.IDField()", generated)
        @test occursin("user_id = Models.OneToOneField(\"CustomUser\"", generated)
        @test occursin("criado_em = Models.DateTimeField(auto_now=true)", generated)
        @test !occursin("objects = Models.Manager", generated)
        @test occursin("Prod_antropometria = Models.Model(\"prod_antropometria\"", generated)
        @test occursin("nu_peso = Models.FloatField(null=true)", generated)
        @test occursin("hora_ag = Models.TimeField(null=true)", generated)
        @test occursin("tempo_atendimento = Models.DurationField(null=true)", generated)
        @test occursin("Dim_cnes_grupo = Models.Model(\"dim_cnes_grupo\"", generated)
        @test occursin("criado_por_id = Models.ForeignKey(\"CustomUser\"", generated)
        @test occursin("unidades = Models.ManyToManyField(\"Dim_CNES\", related_name=\"grupos_unidades\")", generated)
        @test !occursin("unidades_id", generated)
        @test occursin("Dim_interacao_programa = Models.Model(\"dim_interacao_programa\"", generated)
        @test occursin("nivel_destino = Models.PositiveSmallIntegerField(default=3)", generated)
        @test occursin("tipos_permitidos = Models.JSONField(blank=true, default=\"[]\")", generated)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: invalid content returns without generating a model file
# This covers text files that are not Django model definitions, keeping the
# importer non-destructive when users pass the wrong file or pasted content.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer ignores invalid non-model content" begin
    config_key, db_dir_existed = temp_import_config!()
    output_file = "invalid_django_models_unit.jl"
    generated_path = joinpath(config_key, output_file)

    try
        import_models_from_django(
            "this is not a Django models.py file";
            db = config_key,
            file = output_file,
            force_replace = true,
        )

        @test !isfile(generated_path)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: unsupported model base classes are ignored
# This verifies helper/proxy classes do not get converted while valid
# models.Model classes in the same file still generate PormG models.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer skips unsupported model base classes" begin
    django_text = """
from django.db import models

class PlainHelper(object):
    name = models.CharField(max_length=50)

class ProxyUser(CustomUser):
    pass

class SupportedThing(models.Model):
    label = models.CharField(max_length=50)
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "unsupported_base_classes_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("SupportedThing = Models.Model(\"supportedthing\"", generated)
        @test occursin("label = Models.CharField(max_length=50)", generated)
        # `PlainHelper(object)` is a helper by its base list, so it leaves no trace at all.
        @test !occursin("PlainHelper", generated)
        # `ProxyUser(CustomUser)` is NOT the same case, and used to be treated as though it were.
        # Its only base is unresolvable and its body is `pass`, so every column it might have lives
        # somewhere the importer cannot see — which is equally the shape of a real model and of a
        # helper. It is still not emitted as a table, but dropping it in silence is how a genuine
        # model disappears without a trace, so it now says so (#370).
        @test !occursin("ProxyUser = Models.Model", generated)
        @test occursin("# PormG: class 'ProxyUser' inherits 'CustomUser'", generated)
        @test occursin("declares no field of its own", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: unsupported field types fail with field context
# This locks the current explicit-failure behavior for valid Django models that
# contain field classes PormG does not implement.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reports unsupported field types" begin
    django_text = """
from django.db import models

class UnsupportedFieldModel(models.Model):
    tags = models.ArrayField(null=True)
"""
    config_key, db_dir_existed = temp_import_config!()

    try
        # #268 audit: importer failures are typed; a wrapped PormG error rethrows as itself,
        # anything foreign (here: the unsupported-field UndefVarError) wraps as InvalidMigrationError.
        err = @test_throws PormG.InvalidMigrationError import_models_from_django(
            django_text;
            db = config_key,
            file = "unsupported_field_unit.jl",
            force_replace = true,
        )

        message = sprint(showerror, err.value)
        @test occursin("tags", message)
        @test occursin("UnsupportedFieldModel", message)
        @test occursin("ArrayField", message)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: ManyToManyField and single-quoted relation targets
# This covers Django relation fields that require a positional target but should
# not be converted to physical *_id columns in the generated PormG model.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer converts many-to-many relations" begin
    django_text = """
from django.db import models

class CustomUser(models.Model):
    username = models.CharField(max_length=150)

class Dim_CNES(models.Model):
    nome = models.CharField(max_length=120)

class Dim_cnes_grupo(models.Model):
    criado_por = models.ForeignKey('CustomUser', on_delete=models.SET_NULL, null=True, blank=True, db_constraint=False, related_name='grupos_unidades')
    unidades = models.ManyToManyField(Dim_CNES, blank=True, related_name='grupos_unidades')
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "many_to_many_django_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("criado_por_id = Models.ForeignKey(\"CustomUser\"", generated)
        @test occursin("related_name=\"grupos_unidades\"", generated)
        @test occursin("unidades = Models.ManyToManyField(\"Dim_CNES\", related_name=\"grupos_unidades\")", generated)
        @test !occursin("unidades_id", generated)
        @test !occursin("'CustomUser'", generated)
        @test !occursin("'grupos_unidades'", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: quoted string defaults are concrete String values
# This covers empty string defaults such as default='' on TextField, which must
# not leak SubString values into PormG field constructors.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer converts quoted defaults to String" begin
    django_text = """
from django.db import models

class ReporteProblema(models.Model):
    retorno = models.TextField(blank=True, default='')
    status = models.CharField(max_length=20, default='PENDENTE')
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "quoted_defaults_django_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("retorno = Models.TextField(blank=true, default=\"\")", generated)
        @test occursin("status = Models.CharField(max_length=20, default=\"PENDENTE\")", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: output_path and django_prefix overrides for foreign apps
# When staging a foreign Django app (its models.py copied into a sibling folder),
# the caller resolves Settings via `db` but must be able to redirect the output
# directory and the generated table-name prefix without mutating the shared
# config. This verifies both overrides and that the resolved config is untouched.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer honors output_path and django_prefix overrides" begin
    # A named config whose Settings carry the "main app" folder and prefix.
    folder = mktempdir()
    out_folder = mktempdir()
    config_key = "unit_django_import_override_key"
    db_dir_existed = isdir(PormG.MODEL_PATH)
    PormG.config[config_key] = PormG.Configuration.Settings(
        db_def_folder = folder,
        django_prefix = "dash",
    )
    output_file = "override_django_unit.jl"

    django_text = """
from django.db import models

class Dim_ibge(models.Model):
    cidade = models.CharField(max_length=250)
"""

    try
        import_models_from_django(
            django_text;
            db = config_key,
            file = output_file,
            output_path = out_folder,       # redirect away from db_def_folder
            django_prefix = "estoque",      # override the config's "dash" prefix
            force_replace = true,
        )

        # The file lands in the override folder, not the config's db_def_folder.
        @test isfile(joinpath(out_folder, output_file))
        @test !isfile(joinpath(folder, output_file))

        generated = read(joinpath(out_folder, output_file), String)
        # #345: the prefix rides in `db_table`, not in the positional slot. The positional slot is
        # the LOGICAL handle — `lowercase(class_name)`, which is Django's own derivation.
        @test occursin("Models.Model(\"dim_ibge\", db_table = \"estoque_dim_ibge\"", generated)
        # The old spelling (prefix fused into the positional name) must be gone entirely.
        @test !occursin("Models.Model(\"estoque_dim_ibge\"", generated)
        # The overridden prefix wins over the config's "dash" — asserted on the db_table VALUE, not
        # merely on the substring's absence. The pre-#345 assertion here was `!occursin("dash_dim_ibge")`,
        # which passed both before and after the override was honored: nothing in this file ever
        # contained that string. This one fails if the override is ignored.
        @test !occursin("db_table = \"dash_dim_ibge\"", generated)

        # The shared config Settings must be left untouched by the overrides.
        @test PormG.config[config_key].db_def_folder == folder
        @test PormG.config[config_key].django_prefix == "dash"
    finally
        delete!(PormG.config, config_key)
        isdir(folder) && rm(folder; recursive = true)
        isdir(out_folder) && rm(out_folder; recursive = true)
        if !db_dir_existed && isdir(PormG.MODEL_PATH) && isempty(readdir(PormG.MODEL_PATH))
            rm(PormG.MODEL_PATH)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): the app prefix rides in db_table, not the positional name
# `Settings.django_prefix` is ONE value per connection, so it cannot express the
# `core_` / `access_` / `imports_` of a multi-app project. The prefix therefore
# moves to per-model `db_table`. Every model gains one; the positional slot keeps
# the logical handle; the JULIA BINDING is untouched, because it was always
# derived from `model.name` (the Python class name) and never saw the prefix.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer carries the app prefix in db_table (#345)" begin
    # Two class-naming conventions on purpose: `Dim_uf` (Capitalized_snake_case) and `DimIbge`
    # (Django house style). Both must land on Django's own derivation, `class.__name__.lower()`.
    source = """
from django.db import models

class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)

class DimIbge(models.Model):
    cidade = models.CharField(max_length=10)
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = "dash")
    try
        # Positional slot = logical handle; db_table = the physical Django table.
        @test occursin("Models.Model(\"dim_uf\", db_table = \"dash_dim_uf\"", generated)
        @test occursin("Models.Model(\"dimibge\", db_table = \"dash_dimibge\"", generated)

        # `DimIbge` lowers to "dimibge", NOT "dim_ibge" — Django inserts no underscore either, so a
        # camel-cased class still addresses the table Django actually created.
        @test !occursin("\"dim_ibge\"", generated)

        # The prefix must be GONE from the positional slot. Without this the change is a no-op that
        # merely also emits db_table.
        @test !occursin("Models.Model(\"dash_dim_uf\"", generated)
        @test !occursin("Models.Model(\"dash_dimibge\"", generated)

        # The binding is unchanged by the prefix — it comes from the class name, so it is the same
        # string a consuming app already writes as `M.Dim_uf`.
        @test occursin("Dim_uf = Models.Model(", generated)
        @test occursin("DimIbge = Models.Model(", generated)
        @test !occursin("Dash_dim_uf", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): without a prefix the output is byte-for-byte unchanged
# The un-prefixed path is what every other testset in this file exercises, and it
# is the overwhelmingly common case. Pinning it here states plainly that #345 adds
# a db_table only where a prefix exists to carry — a model with no prefix and no
# Meta.db_table must still emit NO db_table at all.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits no db_table without a prefix (#345)" begin
    source = """
from django.db import models

class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = nothing)
    try
        @test occursin("Dim_uf = Models.Model(\"dim_uf\",", generated)
        @test !occursin("db_table", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): Meta.db_table stays ABSOLUTE, as in Django
# Django's Meta.db_table overrides the derived `<app>_<model>` name outright. That
# precedence has to survive the prefix moving into the same slot — otherwise the
# app label would silently win over an explicitly declared legacy table name.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer keeps Meta.db_table absolute under a prefix (#345)" begin
    source = """
from django.db import models

class Matricula(models.Model):
    codigo = models.CharField(max_length=10)

    class Meta:
        db_table = "rh_matricula_legado"
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = "dash")
    try
        # The declared table wins; the positional slot is still the logical handle.
        @test occursin("Models.Model(\"matricula\", db_table = \"rh_matricula_legado\"", generated)
        # The app prefix must NOT be applied on top of, or instead of, the declared name.
        @test !occursin("dash_matricula", generated)
        @test !occursin("dash_rh_matricula_legado", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): an auto-derived ManyToMany join table is pinned
# Django names the implicit through table `<the owning model's table>_<field>`
# (`ManyToManyField._get_m2m_db_table`, which reads `opts.db_table`) — so
# `<app>_<model>_<field>` only when the class does NOT declare Meta.db_table.
# PormG's `_many_to_many_table_name` derives `<logical model>_<field>` with the
# app label stripped, so on a prefixed app the ORM addressed a table Django never
# created. The importer is the only place that knows the app label, so it pins.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer pins the ManyToMany join table under a prefix (#345)" begin
    source = """
from django.db import models

class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)

class DimIbge(models.Model):
    ufs = models.ManyToManyField(Dim_uf)
    regioes = models.ManyToManyField(Dim_uf, db_table="legado_regioes")
    vinculos = models.ManyToManyField(Dim_uf, through='Vinculo')

class Vinculo(models.Model):
    ibge = models.ForeignKey(DimIbge, on_delete=models.CASCADE)
    uf = models.ForeignKey(Dim_uf, on_delete=models.CASCADE)

class Matricula(models.Model):
    setores = models.ManyToManyField(Dim_uf)

    class Meta:
        db_table = "rh_matricula_legado"
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = "dash")
    try
        # Django's spelling for the implicit table: <app>_<lowercased class>_<field>.
        @test occursin("ufs = Models.ManyToManyField(\"Dim_uf\", db_table=\"dash_dimibge_ufs\")", generated)
        # A db_table written in the Django source is authoritative — never overwritten by the prefix.
        @test occursin("db_table=\"legado_regioes\"", generated)
        @test !occursin("dash_legado_regioes", generated)
        @test !occursin("dash_dimibge_regioes", generated)

        # Django derives the join table from `opts.db_table` (`ManyToManyField._get_m2m_db_table`),
        # NOT from the app label + class name. With a Meta.db_table the two diverge, and composing
        # the prefix with the class name would name a table that does not exist.
        @test occursin("setores = Models.ManyToManyField(\"Dim_uf\", db_table=\"rh_matricula_legado_setores\")", generated)
        @test !occursin("dash_matricula_setores", generated)

        # `through=` means the join table IS the through model's table; Django ignores db_table
        # entirely there, so pinning one would write a false claim into the artifact.
        @test occursin("vinculos = Models.ManyToManyField(\"Dim_uf\", through=\"Vinculo\")", generated)
        @test !occursin("dash_dimibge_vinculos", generated)
        # The through model is a real table of its own and gets the app label like any other.
        @test occursin("Vinculo = Models.Model(\"vinculo\", db_table = \"dash_vinculo\"", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): no join-table pin without a prefix
# Without a configured prefix the app label is unknown, so there is nothing to
# reproduce Django's `<app>_…` spelling from. Guessing would be worse than the
# existing derivation, so the M2M field must be left exactly as it was.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer leaves the ManyToMany join table derived without a prefix (#345)" begin
    source = """
from django.db import models

class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)

class DimIbge(models.Model):
    ufs = models.ManyToManyField(Dim_uf)
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = nothing)
    try
        @test occursin("ufs = Models.ManyToManyField(\"Dim_uf\")", generated)
        @test !occursin("db_table", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end

    # An EMPTY prefix is the absence of one, and the M2M pin must agree with `Model_to_str` about
    # that (#345). Gating on a bare `!== nothing` here would compose `string("", "_", "dimibge")` and
    # pin `_dimibge_ufs` — a table with a leading underscore that nothing creates, emitted into a file
    # that otherwise looks unprefixed.
    generated_empty, key_empty, existed_empty = import_django_source(source; django_prefix = "")
    try
        @test occursin("ufs = Models.ManyToManyField(\"Dim_uf\")", generated_empty)
        @test !occursin("db_table", generated_empty)
        @test !occursin("_dimibge", generated_empty)
        # ...and identical to the genuinely-unset run, which is the contract.
        @test generated_empty == generated
    finally
        cleanup_import_test!(key_empty, existed_empty)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): an underscore-prefixed class still produces a file that LOADS
# `_validate_positional_model_name` rejects a leading-underscore positional name
# REGARDLESS of db_table (#306). Moving the app prefix out of that slot therefore
# re-exposed the class of name the prefix used to mask: `class _Internal` under
# prefix "dash" emitted the loadable `Model("dash__internal")` before, and would
# emit `Model("_internal", …)` — a ModelDefinitionError at include time — after.
# The positional slot is free to drop the underscore precisely because db_table is
# now pinning the real table, which is the same trade `inspectdb` already makes.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits a loadable file for an underscore-prefixed class (#345)" begin
    source = """
from django.db import models

class _Internal(models.Model):
    nome = models.CharField(max_length=5)

class ___(models.Model):
    valor = models.CharField(max_length=5)
"""
    output_file = "django_345_underscore_unit.jl"
    config_key, db_dir_existed = temp_import_config!(django_prefix = "dash")

    try
        import_models_from_django(source; db = config_key, file = output_file, force_replace = true)
        generated = read(joinpath(config_key, output_file), String)

        # The physical table keeps the underscore Django gave it; the logical handle drops it.
        @test occursin("Models.Model(\"internal\", db_table = \"dash__internal\"", generated)
        @test !occursin("Models.Model(\"_internal\"", generated)

        # An ALL-underscore class strips to the empty string, which as a positional name silently
        # means "derive from the binding". The sanitizer's placeholder (`col`) is used instead —
        # free to be arbitrary precisely because db_table carries the real table.
        @test occursin("Models.Model(\"col\", db_table = \"dash____\"", generated)
        @test !occursin("Models.Model(\"___\"", generated)

        # The assertion that actually matters: the file loads. String-matching the output cannot
        # establish this — the pre-#345 spelling rendered fine and threw on include.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        m = Core.eval(sandbox, :(django_345_underscore_unit._Internal))
        @test PormG.model_table_name(m) == "dash__internal"
        @test m.name == "internal"

        allunder = Core.eval(sandbox, :(django_345_underscore_unit.Col))
        @test PormG.model_table_name(allunder) == "dash____"
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: Python None defaults map to a null (nothing) default
# Regression for default=None on a ForeignKey, which crashed the importer:
# parse_value returned the literal "None" string, and ForeignKey's typed default
# converter then tried parse(Int64, "None"). None must import as a null default
# (nothing) and be omitted from the generated field, never leaked as a string.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer maps Python None defaults to nothing" begin
    django_text = """
from django.db import models

class Bm2_map_ext_am(models.Model):
    ord = models.IntegerField(default=0)

class Bm2_map_aliq_am(models.Model):
    plan = models.ForeignKey('Bm2_map_ext_am', on_delete=models.SET_DEFAULT, default=None, blank=True, null=True, db_constraint=False)
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "none_default_django_unit.jl",
    )

    try
        generated = read(generated_path, String)
        # The foreign key still imports, keeping its non-null options...
        @test occursin("plan_id = Models.ForeignKey(\"Bm2_map_ext_am\"", generated)
        @test occursin("db_constraint=false", generated)
        # ...but None must never surface as a literal default value.
        @test !occursin("default=None", generated)
        @test !occursin("default=\"None\"", generated)

        # #287: Django's `SET_DEFAULT, default=None` on a nullable FK denotes "set the FK to
        # NULL", which is SET_NULL. It used to import verbatim as SET_DEFAULT-with-no-default —
        # a combination PormG now rejects at set_models, so the generated file would not load at
        # all, and regenerating produced the same broken file. The importer translates it.
        # Registering the old output raised ModelDefinitionError, so the generated module could
        # not be used at all; that rejection is pinned in test_alignment_sqlite.jl. Here we pin
        # the other half: the importer no longer produces that shape.
        @test occursin("on_delete=SET_NULL", generated)
        @test !occursin("on_delete=SET_DEFAULT", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: positive small integers map to PositiveSmallIntegerField
# This covers Django's PositiveSmallIntegerField (a real PormG SMALLINT field)
# plus callable JSON defaults such as default=list, which import to a concrete
# JSON default.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer converts positive small integer fields" begin
    django_text = """
from django.db import models

class Dim_interacao_programa(models.Model):
    cod_programa = models.CharField(max_length=50, unique=True, db_index=True)
    nivel_destino = models.PositiveSmallIntegerField(default=3)
    tipos_permitidos = models.JSONField(default=list, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "positive_small_integer_django_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("cod_programa = Models.CharField(max_length=50, unique=true, db_index=true)", generated)
        @test occursin("nivel_destino = Models.PositiveSmallIntegerField(default=3)", generated)
        @test occursin("tipos_permitidos = Models.JSONField(blank=true, default=\"[]\")", generated)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: positive integers map to PositiveIntegerField
# Regression for an UndefVarError(:PositiveIntegerField) raised while importing a
# Django model with models.PositiveIntegerField. The class mirrors the report that
# surfaced the bug, including FileField with a callable upload_to.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer converts positive integer fields" begin
    django_text = """
from django.db import models

class Tab_interacao_mensagem(models.Model):
    corpo = models.TextField()

class CustomUser(models.Model):
    login = models.CharField(max_length=120)

class Tab_interacao_anexo(models.Model):
    mensagem = models.ForeignKey(Tab_interacao_mensagem, on_delete=models.CASCADE, related_name='anexos')
    uploaded_by = models.ForeignKey(CustomUser, on_delete=models.RESTRICT, related_name='interacoes_anexos')
    arquivo = models.FileField(upload_to=interacao_anexo_upload_to)
    nome_original = models.CharField(max_length=255)
    content_type = models.CharField(max_length=120, blank=True, default='')
    tamanho = models.PositiveIntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "positive_integer_django_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("Tab_interacao_anexo = Models.Model(\"tab_interacao_anexo\"", generated)
        @test occursin("tamanho = Models.PositiveIntegerField(default=0)", generated)
        @test occursin("mensagem_id = Models.ForeignKey(\"Tab_interacao_mensagem\"", generated)
        @test occursin("uploaded_by_id = Models.ForeignKey(\"CustomUser\"", generated)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: callable datetime defaults map to auto_now_add
# This covers default=timezone.now (and equivalent current-time callables), which
# have no literal value and must not be passed verbatim to DateTimeField.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer maps callable datetime defaults to auto_now_add" begin
    django_text = """
from django.db import models
from django.utils import timezone

class Tab_interacao_solicitacao(models.Model):
    titulo = models.CharField(max_length=200)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    gestor_lido_em = models.DateTimeField(null=True, blank=True)
    last_response_at = models.DateTimeField(default=timezone.now)
    data_evento = models.DateField(default=datetime.now)
"""
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        django_text;
        output_file = "callable_datetime_defaults_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("last_response_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test occursin("data_evento = Models.DateField(auto_now_add=true)", generated)
        @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        @test occursin("updated_at = Models.DateTimeField(auto_now=true)", generated)
        @test occursin("gestor_lido_em = Models.DateTimeField(blank=true, null=true)", generated)
        @test !occursin("timezone.now", generated)
        @test !occursin("datetime.now", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: content strings use the same conversion path as files
# This covers callers that already loaded model.py text before invoking the
# importer and verifies the output remains equivalent for representative fields.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer accepts model text string input" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_from_txt.txt")
    model_text = django_to_string(fixture)
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        model_text;
        output_file = "django_models_from_string_unit.jl",
    )

    try
        generated = read(generated_path, String)
        @test occursin("module django_models_from_string_unit", generated)
        @test occursin("Dim_CNES = Models.Model(\"dim_cnes\"", generated)
        @test occursin("agendamento_online = Models.CharField(max_length=1", generated)
        @test occursin("CustomUser = Models.Model(\"customuser\"", generated)
        @test occursin("ReporteProblema = Models.Model(\"reporteproblema\"", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: output goes to settings.db_def_folder, not the config key
# Regression for the importer treating the `db` config key as the output
# directory. With a named key whose Settings point at a different folder, the
# generated file must land in db_def_folder and no directory named after the
# key may be created.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer writes to settings.db_def_folder for named keys" begin
    folder = mktempdir()
    config_key = "unit_django_import_named_key"
    db_dir_existed = isdir(PormG.MODEL_PATH)
    PormG.config[config_key] = PormG.Configuration.Settings(
        db_def_folder = folder,
        django_prefix = nothing,
    )
    output_file = "named_key_django_unit.jl"

    django_text = """
from django.db import models

class Circuit(models.Model):
    name = models.CharField(max_length=120)
"""

    try
        import_models_from_django(
            django_text;
            db = config_key,
            file = output_file,
            force_replace = true,
        )

        # The file must be written under the configured folder...
        @test isfile(joinpath(folder, output_file))
        # ...and the config key must not be materialized as a directory.
        @test !ispath(config_key)
    finally
        delete!(PormG.config, config_key)
        isdir(folder) && rm(folder; recursive = true)
        ispath(config_key) && rm(config_key; recursive = true)
        if !db_dir_existed && isdir(PormG.MODEL_PATH) && isempty(readdir(PormG.MODEL_PATH))
            rm(PormG.MODEL_PATH)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: force_replace guards existing generated model files
# This verifies that a second import does not overwrite an existing output file
# unless callers explicitly opt in with force_replace=true.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer preserves output when force_replace is false" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_from_txt.txt")
    output_file = "django_models_force_replace_guard.jl"
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = output_file,
        force_replace = true,
    )

    try
        sentinel = "# sentinel generated file content\n"
        write(generated_path, sentinel)

        import_models_from_django(
            fixture;
            db = config_key,
            file = output_file,
            force_replace = false,
        )

        @test read(generated_path, String) == sentinel
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: line endings and stray whitespace do not truncate a class (#340)
# `import_models_from_django` accepts source as CONTENT, not only as a path, and
# only the path branch runs the reader that normalizes line endings. A statement
# indented no further than its class header closes that class — so a line holding
# just a `\r` (or a form feed, PEP 8's page separator) read as an empty statement
# at indent 0 and silently discarded every field after it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer is not truncated by CRLF or stray whitespace lines" begin
    lf = """
    from django.db import models


    class Batch(models.Model):
        filename = models.CharField(max_length=255)

        sha256 = models.CharField(max_length=64)

        created_at = models.DateTimeField(auto_now_add=True)
    """

    # Same source three ways: LF, CRLF, and with a form feed on an otherwise blank line.
    variants = Dict(
        "lf" => lf,
        "crlf" => replace(lf, "\n" => "\r\n"),
        "formfeed" => replace(lf, "\n\n" => "\n\f\n"),
    )

    for (label, src) in variants
        config_key, db_dir_existed = temp_import_config!()
        output_file = "django_lineendings_$(label).jl"
        try
            import_models_from_django(src; db = config_key, file = output_file, force_replace = true)
            generated = read(joinpath(config_key, output_file), String)

            # All three fields survive in every variant. Before the fix the CRLF and form-feed
            # variants kept only `filename` — the class was closed by the blank line.
            @test occursin("filename = Models.CharField(max_length=255)", generated)
            @test occursin("sha256 = Models.CharField(max_length=64)", generated)
            @test occursin("created_at = Models.DateTimeField(auto_now_add=true)", generated)
        finally
            cleanup_import_test!(config_key, db_dir_existed)
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a field is a LOGICAL statement, not a physical line (#340)
# The importer matched fields with a per-line regex requiring `= models.X(...)`
# to open AND close on one line, with no else branch — so a wrapped definition
# (ordinary Django formatting, and what `black` emits) was dropped in SILENCE.
# This is the highest-severity failure the importer had: the generated file
# looks complete and loads fine while the schema is missing columns.
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): a TRAILING COMMA must not clobber the relation target
#
# Python allows a trailing comma on every call and PEP 8 encourages one on a wrapped argument list,
# so this is the shape a well-formatted Django FK actually has. The whitespace between that comma and
# the `)` left `split_field_options`' buffer non-empty, so it pushed an all-blank token —
# and `parse_field_args` reads a token with no `=` as the POSITIONAL argument, which overwrote the
# target with "". The generated file then carried `Models.ForeignKey("", …)`, which throws at
# `set_models`.
#
# Found by diffing a real 434-model project's generated output across this change, not by reading:
# it hit exactly two fields there, and the whole file otherwise regenerated byte-for-byte.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer keeps the relation target through a trailing comma (#346)" begin
    source = """
from django.db import models

class Dim_municipio(models.Model):
    nome = models.CharField(max_length=80)

class Logs_auditoria(models.Model):
    ibge = models.ForeignKey(
        Dim_municipio, on_delete=models.SET_NULL, null=True, blank=True,
        db_constraint=False,
    )
    acao = models.CharField(max_length=80,)
    tabela = models.CharField(
        max_length=80,
        null=True,
    )
"""

    generated, config_key, db_dir_existed = import_django_source(source;
                                                                output_file = "trailing_comma.jl")
    try
        # The relation survives, with every keyword that followed it.
        @test occursin("ibge_id = Models.ForeignKey(\"Dim_municipio\"", generated)
        @test !occursin("Models.ForeignKey(\"\"", generated)
        @test occursin("db_constraint=false", generated)
        @test occursin("null=true", generated)

        # A trailing comma on a non-relation field never had a target to clobber, but its options
        # must survive the same way — this is the parser, not the relation path.
        @test occursin("acao = Models.CharField(max_length=80)", generated)
        @test occursin("tabela = Models.CharField(max_length=80, null=true)", generated)

        # And the file loads: `ForeignKey("")` did not, which is how this stayed invisible.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        @test Core.eval(sandbox, :(isdefined(trailing_comma, :Logs_auditoria)))
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#346): two classes differing only in case are refused
#
# Both name the Django model `pessoa` and derive the same table, so the second used to overwrite the
# first in the class index — leaving two declarations pointing at one table and a binding nothing
# could reach. Django refuses such a project outright ("Conflicting 'pessoa' models in application"),
# so there is nothing to disambiguate toward.
#
# Tested HERE, on the single-app arity, because that is where it is a breaking change: an existing
# caller regenerating an unchanged models.py now gets an error where they used to get a file. The
# `UPGRADING.md` entry claims exactly that, and a claim about the single-app path needs a single-app
# test behind it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer refuses two classes differing only in case (#346)" begin
    source = """
from django.db import models

class Pessoa(models.Model):
    nome = models.CharField(max_length=40)

class pessoa(models.Model):
    outro = models.CharField(max_length=40)
"""
    config_key, db_dir_existed = temp_import_config!()
    try
        err = nothing
        try
            import_models_from_django(source; db = config_key, file = "case_single.jl",
                                      force_replace = true)
        catch e
            err = e
        end
        @test err isa PormG.InvalidMigrationError
        msg = sprint(showerror, err)
        @test occursin("differ only in case", msg)
        @test occursin("Pessoa", msg)
        @test occursin("pessoa", msg)
        # Nothing is written — a half-import that drops one of the two would be worse than an error.
        @test !isfile(joinpath(config_key, "case_single.jl"))
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end

    # The ordinary case is untouched: names that merely SHARE a prefix, or differ by more than case,
    # still import side by side.
    ok = """
from django.db import models

class Pessoa(models.Model):
    nome = models.CharField(max_length=40)

class PessoaHistorico(models.Model):
    obs = models.CharField(max_length=40)
"""
    config_key2, existed2 = temp_import_config!()
    try
        import_models_from_django(ok; db = config_key2, file = "case_ok.jl", force_replace = true)
        generated = read(joinpath(config_key2, "case_ok.jl"), String)
        @test occursin("Pessoa = Models.Model(\"pessoa\"", generated)
        @test occursin("PessoaHistorico = Models.Model(\"pessoahistorico\"", generated)
    finally
        cleanup_import_test!(config_key2, existed2)
    end
end

@testset "Django importer reads fields wrapped across physical lines" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_statement_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_statement_forms_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The three-line ForeignKey arrives whole, target and all keyword arguments intact.
        @test occursin("created_by_id = Models.ForeignKey(\"CustomUser\"", generated)
        @test occursin("on_delete=SET_NULL", generated)
        @test occursin("blank=true", generated)
        @test occursin("null=true", generated)

        # Control (passes before and after): a single-line FK was never affected. Present so a
        # failure of the four assertions above is unambiguously about *wrapping*, not about FKs.
        @test occursin("batch_id = Models.ForeignKey(\"ImportBatch\"", generated)

        # A wrapped `models.Q(...)` inside a method body must not be read as a field. Doing so
        # resolved `getfield(Models, :Q)` and threw, aborting the import and losing every later
        # model — so the strongest assertion is simply that the LAST class exists at all.
        @test occursin("ImportRow = Models.Model(", generated)
        # Anchored on the assignment, not the bare substring: a later fixture field named
        # `condition` or `second` would otherwise flip this into a false failure.
        @test !occursin("cond = ", generated)

        # django-stubs annotation on the left-hand side does not hide the field.
        @test occursin("annotated = Models.CharField(max_length=11)", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: string- and comment-aware scanning (#340)
# Comments used to be stripped from the first `#` on a line regardless of
# strings, truncating `default="#fff"`; and the reader globally rewrote every
# apostrophe to a double quote, corrupting any value containing one. Both are
# now handled by the shared scanner rather than by regex and blunt replace.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer does not corrupt values containing # or apostrophes" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_statement_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_statement_scanner_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # `#` inside a string literal is data, not the start of a comment.
        @test occursin("color = Models.CharField(max_length=7, default=\"#fff\")", generated)

        # The apostrophe is asserted in a RETAINED parameter. Before the fix the reader rewrote
        # every `'` to `"`, so this emitted `default="Don"t stop"`. Putting it in help_text would
        # not discriminate — help_text is dropped by parameters_ignore either way.
        @test occursin("default=\"Don't stop\"", generated)

        # Choices given as a LIST. The old option splitter counted only parentheses, so `[` was
        # invisible: it split at the comma BETWEEN the two bracketed tuples, and the second choice
        # was silently discarded. Asserting on the labels rather than the exact rendering — the
        # keys keep their Python quote characters as literal text, which is pre-existing
        # `parse_choices` behaviour this change does not touch (see #342).
        @test occursin("Upload", generated)
        @test occursin("Sheets", generated)
        @test occursin("choices=", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: nested classes and module-level tail code do not leak (#340)
# `parse_class` set `inside_class = true` and never reset it, so a nested
# `class Source(models.TextChoices)` and every module-level statement following
# the last model were appended to the preceding class's field list. Class
# structure now comes from indentation, so a block ends where the source says.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer isolates nested classes and trailing module code" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_statement_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_statement_blocks_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # Module-level code after the last class belongs to no model. These two are the
        # assertions that genuinely fail with the old flag-based parser, which appended
        # every trailing statement to whichever class it saw last. The two local names are
        # deliberately non-overlapping so neither assertion is implied by the other.
        @test !occursin("LEAKED", generated)
        @test !occursin("module_tail_local", generated)

        # A method's locals are not fields either.
        @test !occursin("helper_local", generated)

        # `Meta.unique_together` is read from the isolated Meta block. The fixture's ImportBatch
        # docstring contains `unique_together = ("filename", "sha256")` naming two REAL fields, so
        # a parser scanning the whole class body resolves them and attaches a constraint that
        # ImportBatch never declared. Both halves are asserted.
        @test occursin(
            "constraints = [Models.UniqueConstraint(fields = (\"batch_id\", \"row_number\",))]",
            generated,
        )
        @test !occursin("UniqueConstraint(fields = (\"filename\", \"sha256\",))", generated)

        # Nested class isolation asserted STRUCTURALLY. It has no signature in the generated text
        # — enum members were never `models.X(...)`, so `!occursin("UPLOAD")` passes with or
        # without the fix — but the parse tree shows it directly.
        parsed = PormG.Migrations.parse_class(read(fixture, String))
        batch = only(filter(c -> c.name == "ImportBatch", parsed))
        @test "Source" in [n.name for n in batch.nested]
        @test isempty(filter(s -> occursin("UPLOAD", s.text), batch.body))
        @test count("Models.Model(", generated) == 3
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: an unreadable field-shaped statement is reported (#340)
# The point of #340 is not merely "parse wrapped calls" — it is "never drop a
# field-shaped statement in silence". An assignment whose right-hand side is a
# call the importer cannot read (a field imported directly rather than through
# `models.`) is warned with its source line so the author can port it by hand.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer warns on a field-shaped statement it cannot read" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_statement_forms.txt")
    config_key, db_dir_existed = temp_import_config!()
    output_file = "django_statement_warn_unit.jl"

    try
        # The warning carries the field name as STRUCTURED metadata, not inside the message, so
        # assert on `kwargs` — a message-only matcher would silently stop discriminating.
        logs, _ = Test.collect_test_logs() do
            import_models_from_django(
                fixture; db = config_key, file = output_file, force_replace = true,
            )
        end
        unreadable = [r for r in logs
                      if r.level == Logging.Warn && occursin("field-shaped call", string(r.message))]
        named = [get(Dict(r.kwargs), :field, nothing) for r in unreadable]

        # The fixture's `tags = ArrayField(...)` is a field-shaped call that cannot be read.
        @test "tags" in named

        # ...and so is `direct_fk = ForeignKey(...)`. It is asserted separately because
        # `ForeignKey` does NOT end in "Field": a predicate keyed on that suffix alone stays
        # silent here, which drops the single most important field type without a word. The
        # relation family straddles both suffixes — OneToOneField/ManyToManyField end in
        # "Field", ForeignKey and django-mptt's TreeForeignKey do not.
        @test "direct_fk" in named

        # ...and it must stay QUIET about everything that is not a field. Warning on every
        # unreadable assignment buried the one real finding under manager wiring and method
        # locals — which is the silent drop this issue exists to remove, wearing a hat.
        @test !("objects" in named)      # ImportBatchQuerySet.as_manager() is a manager
        @test !("helper_local" in named) # lives in a method body
        @test !("cond" in named)         # ditto, and it used to abort the whole import
        @test length(unreadable) == 2

        # The import completed despite the warning.
        generated = read(joinpath(config_key, output_file), String)
        # `tags` must not become a COLUMN. Since #341 the word does appear in the file — in a
        # `# PormG:` marker naming the field — which is the point: the gap is recorded in the
        # artifact, not only in a console warning that scrolls away. So assert the absence of the
        # DECLARATION, which is what this test always meant, rather than the absence of the word.
        @test !occursin("tags = Models.", generated)
        @test occursin("# PormG: field 'tags' on 'ImportBatch'", generated)
        @test occursin("ImportBatch = Models.Model(", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: Meta.db_table pins the physical table (#341)
# The importer read exactly ONE Meta option before this. A model declaring
# `db_table` therefore generated a declaration addressing a table that does not
# exist — the schema was wrong, and nothing said so.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reads Meta.db_table" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_db_table_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The positional slot stays the LOGICAL name while `db_table` carries the physical one —
        # the #59 split. Asserted as ONE string so a regression emitting only half fails here.
        @test occursin(
            "Matricula = Models.Model(\"matricula\", db_table = \"rh_matricula_legado\"",
            generated,
        )

        # A model that declares no db_table must not acquire one.
        @test !occursin("Setor = Models.Model(\"setor\", db_table", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a computed Meta.db_table is refused, not applied (#341)
# `parse_value` returns anything it cannot classify verbatim, so applying the
# option without a literal check would pin the table name to the expression's
# own source text (`TABELA_LEGADO`). The model still imports.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer refuses a non-literal Meta.db_table" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_db_table_computed_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The expression's source text must never reach a `db_table=` kwarg, quoted or bare.
        @test !occursin("db_table = \"TABELA_LEGADO\"", generated)
        @test !occursin("db_table = TABELA_LEGADO", generated)

        # ...and the model is still imported, under its derived name, with the reason stated.
        @test occursin("Legado = Models.Model(\"legado\"", generated)
        @test occursin("# PormG: Meta.db_table on 'Legado' is not a string literal", generated)

        # A TRIPLE-quoted literal is the case a naive "starts with a quote" test lets through:
        # `parse_value` strips one character per side, so the value keeps two stray quotes.
        @test !occursin("arq_legado", generated)
        @test occursin("# PormG: Meta.db_table on 'Arquivado' is not a string literal", generated)
        @test occursin("Arquivado = Models.Model(\"arquivado\"", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: Meta.constraints, accepted by whitelist (#341)
# The modern Django spelling of composite uniqueness. Argument acceptance is a
# whitelist rather than a blacklist because the failure direction is asymmetric:
# a `condition=` partial index imported as an unconditional one starts silently
# rejecting rows the live database accepts.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer converts Meta.constraints and rejects what it cannot express" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_constraints_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The plain constraint is imported with its Django name, and `lotacao` is resolved to the
        # imported `lotacao_id` column — FK fields gain that suffix at import.
        @test occursin(
            "constraints = [Models.UniqueConstraint(fields = (\"cpf\", \"lotacao_id\",), " *
            "name = \"uniq_servidor_cpf_lotacao\")]",
            generated,
        )

        # The rejected forms never become constraints. `apelido` is the column all three of them
        # cover, so a single-field UniqueConstraint over it is the signature of any leaking through.
        @test !occursin("Models.UniqueConstraint(fields = (\"apelido\",)", generated)

        # ...and each rejection says which argument it could not express.
        @test occursin("`condition=` changes what the index means", generated)
        @test occursin("it takes a positional expression", generated)
        @test occursin("CheckConstraint has no PormG equivalent", generated)

        # Rejection is PER CONSTRAINT. Three dropped and the fourth kept, on one model — the
        # assertion above proves the survivor, this one proves the other three did not take it with
        # them, which is exactly what the coarse try/catch this replaces used to do.
        # Scoped to Servidor's own markers: other models in the fixture report dropped
        # `unique_together` groups with the same wording, and a file-wide count would silently
        # stop measuring this model the moment one of those changed.
        @test count("a constraint on 'Servidor' was dropped", generated) == 3
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: abstract bases merge into their children (#341)
# `class Matricula(Auditavel):` matched neither literal base list before this, so
# the model was not imported at all and nothing said so. The base itself must
# emit no table — Django never created one for it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer merges abstract base fields into concrete children" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_abstract_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The abstract base emits no TABLE. It is named in the file — in the marker explaining that
        # its `db_table` is not inherited — so the assertion is on the declaration, not the word.
        @test !occursin("Auditavel = Models.Model(", generated)
        @test !occursin("Models.Model(\"auditavel\"", generated)

        # Its columns reach EVERY child — Matricula, Ocorrencia and SoDocstring. A count rather than
        # three `occursin`s, so a merge that fires for only some of them fails here.
        @test count("criado_em = Models.DateTimeField(auto_now_add=true)", generated) == 3

        # The CHILD's redeclaration wins. This pair proves merge ORDER, not merely that a merge
        # happened: Matricula redeclares `origem` at max_length=32 over the base's 8, Ocorrencia
        # does not redeclare it and keeps 8. Reversing the concatenation order flips both.
        @test occursin("origem = Models.CharField(max_length=32, default=\"matricula\")", generated)
        @test occursin("origem = Models.CharField(max_length=8, default=\"base\")", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: an abstract base's Meta reaches only a child with no Meta
# Django installs an abstract base's Meta on a child that declares none of its
# own. Both halves matter, so the fixture pairs a child that declares Meta with
# one that does not, and the same `unique_together` must reach exactly one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer inherits an abstract base's Meta only when the child declares none" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_inherit_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # Ocorrencia declares no Meta, so the base's unique_together applies to it...
        @test occursin(
            "constraints = [Models.UniqueConstraint(fields = (\"criado_em\", \"origem\",))]",
            generated,
        )
        # ...exactly once. Matricula declares its own Meta, so Django does NOT install the base's.
        # The count is what discriminates "inherited by the right child" from "inherited by all".
        @test count("UniqueConstraint(fields = (\"criado_em\", \"origem\",))", generated) == 1

        # `db_table` is deliberately NOT inherited even though Django inherits it: otherwise every
        # child of one abstract base would point at a single table. `Auditavel` declares
        # `db_table = "aud_base"` precisely so this assertion has something that could fail —
        # without it on the base, no implementation could ever put one on the child.
        @test !occursin("Ocorrencia = Models.Model(\"ocorrencia\", db_table", generated)
        @test !occursin("aud_base", generated)
        # ...and the refusal is REPORTED, not silent — otherwise a reader sees a model addressing a
        # different table from the one Django would have given it, with nothing to explain why.
        @test occursin("abstract base 'Auditavel' declares Meta.db_table — NOT inherited", generated)

        # ...and it is reported for exactly the base Django would have inherited from, not for every
        # ancestor. In the three-level chain RaizConfig -> MeioConfig -> FimConfig, `FimConfig`
        # inherits `MeioConfig`'s Meta (the nearest with a Meta block), which declares no db_table —
        # so `RaizConfig`'s must NOT be reported against it, and `MeioConfig`'s ordering must be.
        @test !occursin("abstract base 'RaizConfig' declares Meta.db_table", generated)
        @test occursin("Meta.ordering on 'FimConfig'", generated)
        @test occursin("FimConfig = Models.Model(\"fimconfig\"", generated)

        # A `class Meta:` carrying ONLY a docstring is still a declaration, so Django inherits
        # nothing past it. Gating on the parsed OPTIONS instead of on the block would hand
        # `SoDocstring` the base's unique_together and the withheld-db_table marker; gating on the
        # block — which is what the code does — gives it neither.
        # The `== 1` count above already covers the constraint half: SoDocstring is a third child of
        # Auditavel, so inheriting past its docstring-only Meta would make it 2.
        @test occursin("SoDocstring = Models.Model(\"sodocstring\"", generated)
        @test !occursin("abstract base 'Auditavel' declares Meta.db_table — NOT inherited by 'SoDocstring'", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: multi-table inheritance and proxies emit no table (#341)
# Django gives an MTI child its own table keyed by a `<parent>_ptr_id` one-to-one;
# a proxy gets no table at all. PormG can express neither, and any table emitted
# for them would contradict the live schema — so the omission is recorded in the
# generated file rather than left to a console warning nobody re-reads.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer refuses multi-table inheritance and proxy models" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_mti_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # Neither child is declared...
        @test !occursin("Pedido = Models.Model(", generated)
        @test !occursin("ServidorAtivo = Models.Model(", generated)
        # ...nor do the MTI child's own fields leak into any other model.
        @test !occursin("desconto", generated)

        # The parents still import — refusing the child must not cost the parent.
        @test occursin("Venda = Models.Model(\"venda\"", generated)
        @test occursin("Servidor = Models.Model(\"servidor\"", generated)

        # The generated file states each omission and its reason. ServidorAtivo doubles as the
        # check that `proxy = True` is read BEFORE the inheritance kind is decided: its base is
        # concrete, which is otherwise exactly the multi-table-inheritance shape.
        @test occursin("# PormG: model 'Pedido' inherits the concrete model 'Venda'", generated)
        @test occursin("# PormG: model 'ServidorAtivo' is a Django proxy", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: an unresolvable base degrades, it does not delete (#341)
# A base living in another app cannot be merged from one file. Skipping the model
# would re-create the exact bug this issue closes, so it is imported with its own
# fields and a marker naming what is absent. #346 resolves these by importing the
# defining app alongside this one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer imports a model whose base is defined in another file" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_unresolved_unit.jl",
    )

    try
        generated = read(generated_path, String)

        @test occursin("Relatorio = Models.Model(\"relatorio\"", generated)
        @test occursin("titulo = Models.CharField(max_length=80)", generated)
        @test occursin("# PormG: model 'Relatorio' inherits 'TimeStampedModel'", generated)

        # The other half of the rule: an unresolvable base with NO field declarations in the body
        # is a form/serializer/manager, not a model. Without that gate every such class in a real
        # models.py would import as a table.
        @test !occursin("RelatorioForm", generated)

        # A ModelSerializer does declare field-shaped members, so the field gate alone lets it
        # through. `Meta.model` is what keeps it out — the signature of a class that describes a
        # model, which Django's ModelBase rejects on a real one.
        @test !occursin("ServidorSerializer", generated)

        # A PLAIN form and a PLAIN serializer have no `Meta.model` at all, so that rule cannot help
        # here — the NAMESPACE does. `forms.CharField` and `models.CharField` differ by nothing
        # else, and accepting any field-shaped call turned both of these into `id`-only tables that
        # would reach makemigrations as real CREATE TABLEs. Silent junk in the schema is the mirror
        # of silent loss, and the worse of the two.
        @test !occursin("ContatoForm", generated)
        @test !occursin("RelatorioSerializer", generated)

        # ...and the two guards are not redundant. `ServidorAdminForm` carries a genuine
        # `models.CharField(...)`, so the namespace rule sees a real model field and cannot help —
        # `Meta.model` is the only thing keeping the form out of the schema.
        @test !occursin("ServidorAdminForm", generated)

        # The unresolved-base walk climbs the ABSTRACT chain. `Encomenda` inherits the abstract
        # `Rastreavel`, whose own base is the one missing — and `Rastreavel` emits nothing, so
        # without the walk its gap would reach the file with no marker anywhere.
        @test occursin("Encomenda = Models.Model(\"encomenda\"", generated)
        @test occursin("rastreio = Models.CharField(max_length=20)", generated)
        @test occursin("# PormG: model 'Encomenda' inherits 'TimeStampedModel'", generated)

        # A module-level enum is skipped in silence. Note this is carried by the field gate above,
        # not by `_NON_MODEL_BASES` — a TextChoices declares no field-shaped members either way.
        # The blacklist's own coverage comes from `PlainHelper(object)`, which DOES declare a field.
        @test !occursin("Source = Models.Model(", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a plain mixin beside a model root does not delete the model
# `class Servidor(models.Model, ExportMixin)` is ordinary Django. Classifying on
# the non-model base first dropped the whole model in SILENCE — the very shape
# #341 exists to close, and one the code's own comments claimed to support.
# Django collects fields only from bases that are themselves models, so the
# mixin correctly contributes no columns.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer keeps a model that mixes a model root with a plain mixin" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_mixin_unit.jl",
    )

    try
        generated = read(generated_path, String)

        @test occursin("Lotacao = Models.Model(\"lotacao\"", generated)
        @test occursin("setor = Models.CharField(max_length=40)", generated)

        # ...and the same for a BLACKLISTED base rather than an in-file helper. `object` must come
        # last in a Python base list, so `class Ausencia(models.Model, object)` is the only legal
        # ordering — and it is asserted separately because the two exclusions are separate flags:
        # fixing one and leaving the other still deletes the model in silence.
        @test occursin("Ausencia = Models.Model(\"ausencia\"", generated)
        @test occursin("motivo = Models.CharField(max_length=30)", generated)

        # The mixin itself is not a table, and contributes nothing — matching Django, which only
        # collects fields from bases that carry `_meta`.
        @test !occursin("ExportMixin = Models.Model(", generated)
        @test !occursin("to_csv", generated)

        # A class this file DEFINES outranks the non-model name list. `Manager` is a perfectly good
        # model name — in an HR schema a manager is a person — and matching that list against the
        # raw base list made the class invisible as a base, so `SeniorManager` resolved no parent
        # and was dropped in silence. It is multi-table inheritance, and must be reported as such.
        @test occursin("Manager = Models.Model(\"manager\"", generated)
        @test occursin("# PormG: model 'SeniorManager' inherits the concrete model 'Manager'", generated)

        # A duplicated class name is pathological Python, and reporting it is conditional on what is
        # actually at stake. Helper-first / model-second loses a TABLE — and classification is
        # memoized by name from the first definition, so only the duplicate's own field declarations
        # reveal it.
        @test occursin("# PormG: 'Duplicada' is declared more than once", generated)
        # ...while two helpers under one name lose nothing that reaches the schema, so a comment
        # about a QuerySet in a module that never mentions it would be pure noise.
        @test !occursin("SoRuido", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a directly-imported field type still counts as a field (#341)
# `from django.db.models import CharField` then `titulo = CharField(...)` is
# ordinary Django. Gating "is this a model?" on the dotted `models.X(...)`
# spelling alone made such a class vanish with no warning — while #340's own
# reporter already recognised the bare form. The gate and the reporter must
# agree, or the gate wins and the model disappears.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer recognises a directly-imported field type" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_bare_field_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The model survives...
        @test occursin("Frequencia = Models.Model(\"frequencia\"", generated)
        # ...and the field it could not read is named in the file, not merely warned about.
        @test occursin("field 'competencia' on 'Frequencia'", generated)
        @test occursin("is a field-shaped call the importer cannot read", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: unique_together loses nothing in silence (#341)
# Three paths used to drop a composite key with neither a warn nor a marker,
# while the SAME shapes on `Meta.constraints` were always reported. The
# asymmetry is the bug: a reader of the generated file could not tell a model
# with no composite key from one whose key was thrown away.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reports every unique_together it cannot recover" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_meta_ut_reported_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # (a) the value is a NAME, not a literal — nothing to parse.
        @test occursin("Meta.unique_together on 'Reserva' is not a tuple or list literal", generated)
        # (b) a member matches no imported field.
        @test occursin("field 'nao_existe_esse_campo' matches no imported field", generated)
        # (c) an entry in a grouped list is not itself a group...
        @test occursin("a unique_together entry on 'Quarto' is not a field group", generated)
        # ...and the well-formed group beside it still survives, so (c) is a targeted drop rather
        # than the whole option being abandoned.
        @test occursin("Models.UniqueConstraint(fields = (\"andar\", \"numero\",))", generated)

        # All three models are still imported — reporting is not refusing.
        @test occursin("Reserva = Models.Model(\"reserva\"", generated)
        @test occursin("Diaria = Models.Model(\"diaria\"", generated)
        @test occursin("Quarto = Models.Model(\"quarto\"", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: Meta options with no PormG equivalent are reported (#341)
# Every option the importer cannot honor is named in the generated file with its
# reason. A dropped option that only ever appeared in a console warning is the
# silent loss this issue exists to remove — one level up from #340's fields.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reports Meta options it cannot honor" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    config_key, db_dir_existed = temp_import_config!()
    output_file = "django_meta_dropped_options_unit.jl"

    try
        # The option name is STRUCTURED metadata on the warning, not text inside the message, so a
        # message-only matcher would silently stop discriminating.
        logs, _ = Test.collect_test_logs() do
            import_models_from_django(
                fixture; db = config_key, file = output_file, force_replace = true,
            )
        end
        dropped = [get(Dict(r.kwargs), :option, nothing) for r in logs
                   if r.level == Logging.Warn && occursin("Meta option", string(r.message))]

        @test "ordering" in dropped
        # An UNRECOGNISED key is reported too: it is a typo or a Django option this importer has
        # not met, and passing over either quietly is how a real option gets lost.
        @test "nao_existe_essa_opcao" in dropped

        # Options the importer consumes itself are never reported as dropped. Asserted one by one
        # because a blanket "report everything" regression passes the two assertions above.
        @test !("db_table" in dropped)
        @test !("abstract" in dropped)
        @test !("constraints" in dropped)
        @test !("unique_together" in dropped)
        @test !("proxy" in dropped)
        # #347 moved these two from "no PormG equivalent" to consumed. The whole-option report is
        # what a regression would restore, and it would be a REGRESSION now: reporting the option
        # as dropped while also importing it is worse than either alone.
        @test !("indexes" in dropped)
        @test !("index_together" in dropped)

        generated = read(joinpath(config_key, output_file), String)
        @test occursin("# PormG: Meta.nao_existe_essa_opcao on 'Legado' is not recognised", generated)
        # The whole-option marker is gone; per-ENTRY markers took its place, one per index the
        # importer refuses (descending, functional, GinIndex, partial — see the fixture).
        @test !occursin("Meta.indexes on 'Servidor' — dropped", generated)
        @test count("an index on 'Servidor' was dropped", generated) == 4
        # And what it CAN express reached the model: the composite index, plus the single-column
        # entry translated to `db_index` on the field rather than a one-field Index.
        @test occursin("Models.Index(fields = (\"cpf\", \"lotacao_id\",), name = \"idx_servidor_cpf_lotacao\")", generated)
        @test occursin("Models.Index(fields = (\"apelido\", \"ativo\",))", generated)   # index_together
        @test occursin("apelido = Models.CharField(max_length=30, db_index=true)", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: the generated Meta output is loadable Julia (#341)
# Everything above is downstream of this. `db_table=` and `constraints=` are
# emitted as kwargs on Models.Model, and `_apply_unique_constraints!` rejects a
# constraint naming a field the model does not carry — so a file that renders but
# does not evaluate is the failure that actually reaches a user.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits a Meta-carrying module that evaluates" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_meta_forms.txt")
    output_file = "django_meta_evaluates_unit.jl"
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = output_file,
    )

    try
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(read(generated_path, String)))
        # Each binding is read back through `Core.eval` rather than `getfield`: the module was
        # defined during this call, so its bindings are newer than this frame's world age and a
        # direct `getfield` raises UndefVarError.
        modelof(sym) = Core.eval(sandbox, :(django_meta_evaluates_unit.$sym))

        # `db_table` survives the round trip as the PHYSICAL table while the logical name stays
        # lowercase. Reloading is where a wrong kwarg actually bites — rendering it is not enough.
        matricula = modelof(:Matricula)
        @test PormG.model_table_name(matricula) == "rh_matricula_legado"
        @test matricula.name == "matricula"

        # ...and so do the constraints, including the FK `_id` resolution and the Django name.
        rc = modelof(:Servidor).cache["unique_constraints"]["constraints"]
        @test length(rc) == 1
        @test rc[1].fields == ["cpf", "lotacao_id"]
        @test rc[1].name == "uniq_servidor_cpf_lotacao"

        # A model declaring no db_table must not have acquired one on the way through.
        # (#345 note: this fixture imports with NO prefix — `temp_import_config!` defaults to
        # `django_prefix = nothing`. Under a prefix every model legitimately gains a db_table, which
        # is what the prefixed round-trip below asserts instead.)
        @test !PormG.model_has_db_table(modelof(:Setor))
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#345): the PREFIXED generated module is loadable Julia
# The sharpest test of the change: rendering the right string proves nothing if
# the file does not load, or if the reloaded model addresses a different table
# than the one Django owns. This evaluates the generated module and reads the
# physical table, the logical name and the binding back off the live objects.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits a loadable prefixed module (#345)" begin
    source = """
from django.db import models

class Dim_uf(models.Model):
    nome = models.CharField(max_length=50)

class Matricula(models.Model):
    codigo = models.CharField(max_length=10)

    class Meta:
        db_table = "rh_matricula_legado"
"""
    output_file = "django_345_roundtrip_unit.jl"
    config_key, db_dir_existed = temp_import_config!(django_prefix = "dash")

    try
        import_models_from_django(source; db = config_key, file = output_file, force_replace = true)

        sandbox = Module()
        Core.eval(sandbox, Meta.parse(read(joinpath(config_key, output_file), String)))
        # Same world-age dance as the testset above.
        modelof(sym) = Core.eval(sandbox, :(django_345_roundtrip_unit.$sym))

        # The reloaded model queries Django's real table while its logical name — the thing every
        # accessor and reverse relation is keyed on — stays un-prefixed.
        dim_uf = modelof(:Dim_uf)
        @test PormG.model_table_name(dim_uf) == "dash_dim_uf"
        @test dim_uf.name == "dim_uf"
        @test PormG.model_has_db_table(dim_uf)

        # Meta.db_table remains absolute after a reload, not just at render time.
        matricula = modelof(:Matricula)
        @test PormG.model_table_name(matricula) == "rh_matricula_legado"
        @test matricula.name == "matricula"

        # The BINDING is the class name, unchanged by the prefix. Asserted by resolving the exact
        # symbol a consuming app writes — `Dash_dim_uf` would raise here.
        @test modelof(:Dim_uf) isa PormG.PormGModel
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: TextChoices / IntegerChoices resolve (#342)
# `choices=Status.choices` used to parse to the literal string "Status.choices"
# and `default=Status.DRAFT` to "Status.DRAFT"; CharField then rejected the pair
# and the FieldValidationError killed the ENTIRE import — every other model in
# the file lost to one enum. The enum classes were already parsed into
# `PyClass.nested` by #340; this is the seam that consumes them.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer resolves nested TextChoices" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_nested_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # Both kwargs resolve through the enum — the exact shape from the issue.
        @test occursin(
            "status = Models.CharField(max_length=20, default=\"DRAFT\", " *
            "choices=((\"DRAFT\", \"Em processamento\"), (\"APPLIED\", \"Aplicado\"), " *
            "(\"IN_PROGRESS\", \"In Progress\")))",
            generated,
        )
        # Neither literal survives anywhere: those are what CharField choked on.
        @test !occursin("Status.choices", generated)
        @test !occursin("Status.DRAFT", generated)

        # An omitted label is derived Django-style: IN_PROGRESS -> "In Progress".
        @test occursin("(\"IN_PROGRESS\", \"In Progress\")", generated)
        # `__empty__` declares Django's blank choice; it is not a member.
        @test !occursin("Desconhecido", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: enum resolution is class-scoped (#342)
# Two models may each nest a `Status` with different members. A flat symbol
# table silently gives both the last one parsed, and the failure is invisible —
# the field still imports, with the wrong enumeration.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer scopes enum lookup to the declaring class" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_scope_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # ImportRow.Status, not ImportBatch.Status — the whole point.
        @test occursin(
            "situacao = Models.CharField(max_length=20, default=\"OK\", " *
            "choices=((\"OK\", \"Validada\"), (\"REJECTED\", \"Rejeitada\")))",
            generated,
        )
        # A module-level enum reaches a model that nests one of its own...
        @test occursin(
            "prioridade = Models.CharField(max_length=2, default=\"1\", " *
            "choices=((\"1\", \"Baixa\"), (\"2\", \"Alta\")))",
            generated,
        )
        # ...and a nested enum can be addressed through its owner, as Django allows. This resolves
        # to ImportBatch's members from inside ImportRow, which a class-scoped-only lookup misses.
        @test occursin(
            "espelho = Models.CharField(max_length=20, " *
            "choices=((\"DRAFT\", \"Em processamento\"), (\"APPLIED\", \"Aplicado\"), " *
            "(\"IN_PROGRESS\", \"In Progress\")))",
            generated,
        )

        # A DOUBLY-nested enum. Python resolves it as `Grupo.Situacao`, so it has to be registered
        # under that dotted path — collecting it under the bare `Situacao` finds the enum and then
        # reports it as undefined, because the reference the source actually contains never matches.
        @test occursin(
            "campo = Models.CharField(max_length=2, default=\"a\", " *
            "choices=((\"a\", \"Aa\"), (\"b\", \"Bb\")))",
            generated,
        )
        @test !occursin("`Grupo.Situacao`, which this file does not define", generated)

        # ...and the dotted key is the ONLY one a deep enum gets. Registering the bare name too
        # shadows the module scope, because lookup searches the class before `""` — `Sombreado`
        # would then silently import `Interno.Prioridade2` where Python binds the module-level one.
        #
        # The numeric members pin the other half: Django stores what a literal MEANS, so `1_000` is
        # 1000 and `0x1F` is 31. Carrying the source spelling declares an enumeration no row can
        # match — and because the default would be wrong identically, validation passes and nothing
        # is reported. A silent wrong value is worse than the reported drop it replaced.
        # The DEFAULT is the non-canonical member on purpose: normalizing only the choices leaves
        # `default="1_000"` agreeing with nothing, and both halves have to go through the same path.
        @test occursin(
            "nivel = Models.CharField(max_length=5, default=\"1000\", " *
            "choices=((\"1000\", \"Mil\"), (\"31\", \"Meio\"), (\"1\", \"Um\")))",
            generated,
        )
        @test !occursin("1_000", generated)
        @test !occursin("0x1F", generated)
        @test !occursin("(\"F\", \"Fundo\")", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: every choices degrade is reported, and costs one field (#342)
# The bug is not that some enums cannot be resolved — it is that one of them
# used to cost the whole file. Each degrade names itself in the generated file,
# and a model declared after all of them must still be there.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer degrades unresolvable choices without losing the file" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_degrade_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # An enum defined in another module: choices AND default drop together. Dropping only one
        # leaves the survivor carrying the unresolvable literal — which is the original abort.
        # "which this file does not define", not "enum": the same shape catches a module constant
        # (`default=constants.MAX`), and calling that an enumeration in the artifact is a claim the
        # reader has no way to check.
        @test occursin("references `Externo`, which this file does not define", generated)
        @test occursin("origem = Models.CharField(max_length=10)", generated)
        # The literal must never reach the field as a VALUE. Both names do appear in the file now —
        # inside markers naming what was dropped — so the assertion is on the declaration form,
        # which is what it always meant.
        @test !occursin("default=\"Externo.ATIVO\"", generated)
        @test !occursin("\"Externo.choices\"", generated)

        # When only the DEFAULT is unresolvable, the resolvable `choices` stays. A blanket
        # "drop both" is tidier to write and throws away what the source did give us — this is the
        # assertion that keeps it honest.
        @test occursin(
            "parcial = Models.CharField(max_length=10, " *
            "choices=((\"1\", \"Baixa\"), (\"2\", \"Alta\")))",
            generated,
        )
        @test occursin("`default` dropped", generated)

        # `.values` is a list of values, not (value, label) pairs.
        @test occursin("uses `Prioridade.values`", generated)
        @test occursin("listagem = Models.CharField(max_length=10)", generated)

        # A member that does not exist on the enum.
        @test occursin("`Prioridade.INEXISTENTE`, which is not a member", generated)
        @test occursin("fantasma = Models.CharField(max_length=10)", generated)

        # Only CharField has a choices slot. `_common_kwargs` would warn anonymously
        # ("Unexpected parameter for TextField"); this names the field and class.
        @test occursin("TextField has no choices slot in PormG", generated)
        @test occursin("corpo = Models.TextField()", generated)

        # ...and the model declared AFTER all of them is still here. This is the assertion that
        # actually pins the issue: one bad enum must cost one field's metadata, not the file.
        @test occursin("Posterior = Models.Model(\"posterior\"", generated)
        # Every model in the fixture reaches the file. A count rather than nine `occursin`s, so a
        # regression that loses one anywhere in the middle fails here.
        # Bump this when the fixture gains a model — that maintenance is the price of catching a
        # model that silently disappears from the middle of the file.
        @test count("Models.Model(", generated) == 14
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: the construction-time safety net (#342)
# `choices=Prioridade.choices, default="NOPE"` — both kwargs resolve perfectly
# well and the PAIR is invalid. Nothing in parse_field_args can see that; only
# CharField's own validation can, and before #342 it aborted the whole import.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer recovers from a rejected choices/default pair" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_safetynet_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The field survives without its enumeration...
        @test occursin("combinado = Models.CharField(max_length=10)", generated)
        # ...and says why, naming ONLY the kwargs that were actually present and quoting the
        # validation that rejected them. The blanket wording claimed "the enumeration is not
        # enforced" on fields that had no enumeration — an over-long `default` on a plain CharField
        # recovers through this same path.
        @test occursin("`choices` and `default` rejected and dropped", generated)
        @test occursin("The default value must be one of the choices", generated)
        # The bad default never reaches the output.
        @test !occursin("\"NOPE\"", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: inline choice values carry no quote characters (#342)
# `parse_value` stored a Django ("UP", "Upload") as the four-character string
# `"UP"` — quote marks kept as part of the value. Metadata-only, so nothing
# downstream broke, but enum resolution produces the clean form and one model
# would otherwise have carried two spellings of the same concept.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer strips quotes from inline choice values" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_quotes_unit.jl",
    )

    try
        generated = read(generated_path, String)

        @test occursin(
            "canal = Models.CharField(max_length=2, default=\"UP\", " *
            "choices=((\"UP\", \"Upload\"), (\"GS\", \"Sheets\")))",
            generated,
        )
        # The old shape, spelled out so the assertion cannot pass by accident: the value used to be
        # the four-character string including its quote marks.
        @test !occursin("\\\"UP\\\"", generated)

        # ...and a LIST container gets the same treatment. It used to bypass the importer's
        # parse_choices entirely (which only handled `(...)`) and be re-parsed much later by the
        # field layer, which still keeps the quotes — so one generated model carried both spellings
        # of the same concept, the very thing the normalization exists to prevent.
        @test occursin(
            "lista = Models.CharField(max_length=2, default=\"UP\", " *
            "choices=((\"UP\", \"Upload\"), (\"GS\", \"Sheets\")))",
            generated,
        )
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a choices literal is read with the shared scanner (#342)
# `parse_choices` split on EVERY comma and threw InvalidMigrationError from
# OUTSIDE the field-construction try. A comma inside a human-readable label —
# "Aplicado, com ressalvas" — therefore aborted the whole import: no file
# written, every model lost. That is verbatim the failure this issue exists to
# remove, in the function the issue asks to rewrite.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reads choices literals with the bracket-aware scanner" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_scanner_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # A comma inside a label is content, not a separator.
        @test occursin(
            "virgula = Models.CharField(max_length=3, default=\"a\", " *
            "choices=((\"a\", \"Alpha, primeiro\"),))",
            generated,
        )

        # A list of LISTS is valid Django. It used to import as an empty `choices=()` with no
        # warning at all — a documented limitation that the scanner rebase removes.
        @test occursin(
            "listas = Models.CharField(max_length=2, default=\"A\", " *
            "choices=((\"A\", \"Alpha\"), (\"B\", \"Beta\")))",
            generated,
        )

        # A genuinely malformed entry is reported and skipped; the good one beside it survives, so
        # the leniency is per entry rather than a blanket bail-out.
        @test occursin("has a choices entry that is not a (value, label) pair", generated)
        @test occursin(
            "torto = Models.CharField(max_length=2, default=\"A\", choices=((\"A\", \"Alpha\"),))",
            generated,
        )
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: an abstract base's enum resolves from its children (#342)
# Inherited statements are merged into the child and processed under the CHILD's
# name, so a base declaring both the enum and a field using it hands the child a
# reference that is nowhere in its own scope. The importer then reported it as
# "not defined in this file" about an enum three lines above — a marker stating
# something the reader can see is false.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer resolves an enum declared on an abstract base" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_abstract_unit.jl",
    )

    try
        generated = read(generated_path, String)

        @test occursin(
            "estado = Models.CharField(max_length=3, default=\"ON\", " *
            "choices=((\"ON\", \"Ligado\"), (\"OFF\", \"Desligado\")))",
            generated,
        )
        # ...and no marker claims the base's enum is missing.
        @test !occursin("`Estado`, which this file does not define", generated)
        # The abstract base itself emits no table.
        @test !occursin("Auditavel = Models.Model(", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a dotted default that is not an enum is left alone (#342)
# Enum resolution runs on EVERY option value. Capturing any dotted `default=`
# made `default=uuid.uuid4` and `default=timezone.now` disappear from fields
# that have nothing to do with enumerations — an undocumented behavior change,
# reported with a diagnostic that named the wrong thing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer does not treat every dotted default as an enum" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_dotted_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # Kept exactly as before this change.
        @test occursin("ident = Models.CharField(max_length=36, default=\"uuid.uuid4\")", generated)
        # ...and the datetime-callable mapping still wins for `timezone.now`.
        @test occursin("criado = Models.DateTimeField(auto_now_add=true)", generated)
        # Neither is reported as an enumeration.
        @test !occursin("`uuid`, which this file does not define", generated)
        @test !occursin("`timezone`, which this file does not define", generated)

        # But a dotted default that IS kept verbatim is still reported. `Externo.ativo` is an enum
        # member spelled unconventionally and is indistinguishable from `uuid.uuid4` by syntax
        # alone — so the value is left untouched and the reader is told an expression landed in the
        # schema as literal text. Keeping it AND saying nothing is the silent gain the contract
        # forbids.
        @test occursin("a = Models.CharField(max_length=40, default=\"Externo.ativo\")", generated)
        @test occursin("an expression the importer cannot evaluate — kept verbatim as text", generated)

        # `.value` on an UNRESOLVABLE enum. The member-attribute peel cannot fire, so `.value`
        # counting as an enum-shaped attribute is the only thing keeping the literal out of the
        # schema — dropped and reported, not kept verbatim like `Externo.ativo` above.
        @test occursin("b = Models.CharField(max_length=40)", generated)
        @test !occursin("\"Externo.ATIVO.value\"", generated)

        # `.value` resolves to the member's stored value — it is an ordinary way to spell a default,
        # and rejecting it cost the resolvable `choices` as well via the safety net.
        @test occursin(
            "com_value = Models.CharField(max_length=10, default=\"NOVO\", " *
            "choices=((\"NOVO\", \"Novo\"), (\"VELHO\", \"Velho\")))",
            generated,
        )
        # `.label` is display text, not a stored value: dropped and named, choices kept.
        @test occursin("which is the member's label rather than its stored value", generated)
        @test occursin(
            "com_label = Models.CharField(max_length=10, " *
            "choices=((\"NOVO\", \"Novo\"), (\"VELHO\", \"Velho\")))",
            generated,
        )

        # `choices` naming a module-level constant: nothing to read, and an empty tuple in silence
        # is how a field lost its whole enumeration without a trace. The marker must say the WHOLE
        # option went — the per-entry phrasing shares this channel and would leave a reader thinking
        # the rest survived.
        @test occursin("s = Models.CharField(max_length=3)", generated)
        @test occursin(
            "has `choices=SITUACAO_CONSTANTE`, which is a name rather than a literal — the whole " *
            "option was dropped.",
            generated,
        )
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: enum member values the importer cannot read (#342)
# `CARRO = auto()` is a documented Django idiom. Imported verbatim it gives
# every member the value "auto()" — duplicates that then PASS validation,
# because the default is literally in the set. Wrong metadata kept in silence is
# the mirror of a silent drop, and this importer's contract forbids both.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer reports enum members whose values are not literals" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_nonliteral_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # `auto()` never reaches the output as a value...
        @test !occursin("auto()\"", generated)
        @test occursin("have values the importer cannot read", generated)
        @test occursin("tipo = Models.CharField(max_length=10)", generated)

        # An enum with no members cannot supply choices.
        @test occursin("`Vazia` declares no members", generated)
        @test occursin("vazia = Models.CharField(max_length=5)", generated)

        # A gettext-wrapped label is unwrapped: the wrapper is i18n plumbing, not the display text.
        @test occursin(
            "cor = Models.CharField(max_length=10, default=\"AZUL\", " *
            "choices=((\"AZUL\", \"Azul\"), (\"VERDE\", \"Verde\"), (\"MISTO\", \"Misto\")))",
            generated,
        )
        @test !occursin("_(\\\"Azul\\\")", generated)

        # A COMPOUND label unwraps to the fragment `a") + _("b`. Falling back to Django's derived
        # label keeps that fragment out of the generated file as display text. Only the LABEL
        # degrades this way; a non-literal VALUE drops the option, because a value is schema.
        @test occursin("(\"MISTO\", \"Misto\")", generated)
        @test !occursin("+ _(", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: a resolved `None` member is not mistaken for a drop (#342)
# `parse_value("None")` is `nothing`, and `nothing` was also the "drop this
# option" signal. A member declared `NENHUM = None, "Nenhum"` therefore made the
# option vanish with no warn and no marker — the one thing this importer
# promises never to do. The two now use distinct sentinels.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer distinguishes a None member value from a dropped option" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = "django_choices_none_unit.jl",
    )

    try
        generated = read(generated_path, String)

        # The field imports with its choices...
        @test occursin("x = Models.CharField(max_length=3, null=true, choices=(", generated)
        # ...and nothing about it is reported, because nothing about it was dropped. A silent drop
        # would look identical in the declaration, so the absence of a marker is the assertion.
        @test !occursin("on 'NoneMembro'", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer: the choices output is loadable Julia (#342)
# Everything above is downstream of this. The whole issue is an import that ends
# as a stack trace and no file at all, so the file existing, parsing, evaluating
# and carrying the right choices on the right field is the real assertion.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Django importer emits a choices-carrying module that evaluates" begin
    fixture = joinpath(@__DIR__, "fixtures", "django_models_choices_forms.txt")
    output_file = "django_choices_evaluates_unit.jl"
    config_key, db_dir_existed, generated_path = import_fixture_to_temp(
        fixture;
        output_file = output_file,
    )

    try
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(read(generated_path, String)))
        # Read back through `Core.eval`: the module was defined during this call, so its bindings
        # are newer than this frame's world age and a direct `getfield` raises UndefVarError.
        modelof(sym) = Core.eval(sandbox, :(django_choices_evaluates_unit.$sym))

        batch = modelof(:ImportBatch)
        @test batch.fields["status"].choices ==
              (("DRAFT", "Em processamento"), ("APPLIED", "Aplicado"), ("IN_PROGRESS", "In Progress"))
        @test batch.fields["status"].default == "DRAFT"

        # An IntegerChoices on a CharField: parse_choices stringifies the values and CharField
        # coerces the Int default, so both enum kinds land correctly.
        row = modelof(:ImportRow)
        @test row.fields["prioridade"].choices == (("1", "Baixa"), ("2", "Alta"))
        @test row.fields["prioridade"].default == "1"

        # A degraded field keeps its column and loses only the enumeration.
        rel = modelof(:Relatorio)
        @test rel.fields["origem"].choices === nothing
        @test rel.fields["origem"].default === nothing
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#371): the label is what decides, not the arity
#
# A single-app import with a `django_prefix` HAS an app label — `django_prefix` *is* the Django app
# label — so its markers are qualified on the same rule a multi-app import uses. That is not a new
# behaviour so much as the end of an inconsistency: relation markers already went through
# `_django_ref_label`, so one generated file used to carry `'dash.Legado'` from a degraded relation
# and `'Legado'` from the `Meta.db_table` marker three lines away.
#
# Both halves are asserted from ONE source imported twice, because the claim is a difference: the
# unlabelled arity must be unchanged, and only a paired assertion can show that the qualification
# comes from the label rather than from the fix firing everywhere.
# ─────────────────────────────────────────────────────────────────────────────
@testset "markers are qualified under a django_prefix and bare without one (#371)" begin
    source = """
from django.db import models

class Legado(models.Model):
    nome = models.CharField(max_length=10)
    tags = ArrayField(models.CharField(max_length=5))
    situacao = models.CharField(max_length=5, default=Status.DRAFT)

    class Meta:
        db_table = TABELA_LEGADO
        ordering = ['nome']
        unique_together = CHAVE_EXTERNA
        indexes = [models.Index(fields=['nao_existe'], name='ix_fantasma')]
"""

    generated, config_key, db_dir_existed = import_django_source(source; django_prefix = "dash",
                                                                 output_file = "qualified_prefix.jl")
    try
        # One marker per producing mechanism: the field walker, the option parser, the inline
        # `_import_django_apps` sites, and two of the Meta helpers.
        @test occursin("# PormG: field 'tags' on 'dash.Legado'", generated)
        @test occursin("# PormG: field 'situacao' on 'dash.Legado' references `Status`", generated)
        @test occursin("# PormG: Meta.db_table on 'dash.Legado' is not a string literal", generated)
        @test occursin("# PormG: Meta.ordering on 'dash.Legado'", generated)
        @test occursin("# PormG: Meta.unique_together on 'dash.Legado' is not a tuple or list",
                       generated)
        @test occursin("# PormG: an index on 'dash.Legado' was dropped", generated)

        # Not one site left behind. `on 'Legado'` cannot match `on 'dash.Legado'`.
        @test !occursin("on 'Legado'", generated)
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end

    # The unlabelled arity is untouched: one app, nothing to disambiguate against, and a prefix
    # nobody typed would be a lie about which Django app the class came from.
    bare, key2, existed2 = import_django_source(source; output_file = "unqualified_prefix.jl")
    try
        @test occursin("# PormG: field 'tags' on 'Legado'", bare)
        @test occursin("# PormG: field 'situacao' on 'Legado' references `Status`", bare)
        @test occursin("# PormG: Meta.db_table on 'Legado' is not a string literal", bare)
        @test occursin("# PormG: Meta.ordering on 'Legado'", bare)
        @test occursin("# PormG: Meta.unique_together on 'Legado' is not a tuple or list", bare)
        @test occursin("# PormG: an index on 'Legado' was dropped", bare)
        @test !occursin("dash.", bare)
    finally
        cleanup_import_test!(key2, existed2)
    end
end
