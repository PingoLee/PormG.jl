using Test
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
        @test occursin("_id = Models.AutoField()", generated)
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
        err = @test_throws ErrorException import_models_from_django(
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
