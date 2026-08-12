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

function temp_import_config!()
    config_key = mktempdir()
    db_dir_existed = isdir(PormG.MODEL_PATH)

    PormG.config[config_key] = PormG.Configuration.Settings(
        db_def_folder = config_key,
        django_prefix = nothing,
    )

    return config_key, db_dir_existed
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
        @test occursin("id = Models.AutoField()", generated)
        @test !occursin("_id = Models.AutoField()", generated)
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
        @test !occursin("PlainHelper", generated)
        @test !occursin("ProxyUser", generated)
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
        # Table name uses the overridden prefix...
        @test occursin("Models.Model(\"estoque_dim_ibge\"", generated)
        # ...never the config's "dash" prefix.
        @test !occursin("dash_dim_ibge", generated)

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

        @test "indexes" in dropped
        @test "ordering" in dropped
        # An UNRECOGNISED key is reported too: it is a typo or a Django option this importer has
        # not met, and passing over either quietly is how a real option gets lost.
        @test "nao_existe_essa_opcao" in dropped

        # Options the importer consumes itself are never reported as dropped. Asserted one by one
        # because a blanket "report everything" regression passes the three assertions above.
        @test !("db_table" in dropped)
        @test !("abstract" in dropped)
        @test !("constraints" in dropped)
        @test !("unique_together" in dropped)
        @test !("proxy" in dropped)

        generated = read(joinpath(config_key, output_file), String)
        @test occursin("# PormG: Meta.indexes on 'Servidor' — dropped: PormG has no composite-index", generated)
        @test occursin("# PormG: Meta.nao_existe_essa_opcao on 'Legado' is not recognised", generated)
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
        @test !PormG.model_has_db_table(modelof(:Setor))
    finally
        cleanup_import_test!(config_key, db_dir_existed)
    end
end
