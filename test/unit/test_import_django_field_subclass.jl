using Test
using Logging
using PormG
using PormG.Migrations

isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): a custom field class is imported as its Django base
#
# `class DriverCodeField(models.CharField)` and then `code = DriverCodeField(max_length=3)` used to
# take the "field-shaped call the importer cannot read" path. The column was dropped from the model,
# and the marker beside it said the next `makemigrations` would propose DROPPING a populated column.
# A consuming app regenerating its models with `force_replace = true` lost the hand declaration on
# every sync. The base type is in the source, so the importer now reads it.
# ─────────────────────────────────────────────────────────────────────────────

"""
    import_subclass_source(source; output_file, kwargs...) -> (generated, config_key)

Import one `models.py` source under a throwaway config and return the generated text. Callers
must `cleanup_subclass_import!(config_key)` in a `finally`.
"""
function import_subclass_source(source; output_file::String = "field_subclass_unit.jl", kwargs...)
    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    import_models_from_django(source; db = config_key, file = output_file, force_replace = true,
                              kwargs...)
    return read(joinpath(config_key, output_file), String), config_key
end

function cleanup_subclass_import!(config_key)
    delete!(PormG.config, config_key)
    isdir(config_key) && rm(config_key; recursive = true)
end

# The marker the importer leaves when it cannot read a field-shaped call at all. Every unresolved
# case below must still produce it, so the "not imported" warning never goes away for a column
# that really is missing.
const CANNOT_READ = "is a field-shaped call the importer cannot read — NOT imported."

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the issue's own shape, plus a transitive chain
# A subclass used by two models imports as `Models.CharField` with the call's options in both. A
# subclass of that subclass resolves too. The marker that replaces the DROP warning names the chain,
# so the reader knows that Python-side behaviour exists and PormG does not replicate it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a same-file CharField subclass imports as CharField, transitively (#1041)" begin
    source = """
from django.db import models

class DriverCodeField(models.CharField):
    def pre_save(self, model_instance, add):
        return super().pre_save(model_instance, add)

    def get_prep_value(self, value):
        return value.upper() if value else value

class ShortCodeField(DriverCodeField):
    pass

class Driver(models.Model):
    code = DriverCodeField(max_length=3, null=True, blank=True)
    nickname = ShortCodeField(max_length=5)

class Constructor(models.Model):
    code = DriverCodeField(max_length=3)
"""
    generated, config_key = import_subclass_source(source)
    try
        # The column is declared on BOTH models with the call's own options. Before #1041 neither
        # line existed.
        @test occursin("code = Models.CharField(max_length=3, blank=true, null=true)", generated)
        @test occursin(r"\nConstructor = Models\.Model\(\n  id = Models\.IDField\(\),\n  code = Models\.CharField\(max_length=3\)\)", generated)
        # The second hop of the chain resolves through the first.
        @test occursin("nickname = Models.CharField(max_length=5)", generated)

        # The informational marker replaces the DROP warning and spells the chain as written.
        @test occursin("# PormG: field 'code' on 'Driver' (models.py line 14) is " *
                       "DriverCodeField(models.CharField) — imported as CharField with the call's " *
                       "own options.", generated)
        @test occursin("# PormG: field 'nickname' on 'Driver' (models.py line 15) is " *
                       "ShortCodeField(DriverCodeField(models.CharField)) — imported as CharField",
                       generated)
        @test occursin("(pre_save, get_prep_value, validators) is not replicated by PormG.", generated)
        @test !occursin(CANNOT_READ, generated)
        @test !occursin("proposes DROPPING", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): a bare base counts only when Django bound it
# `from django.db.models import CharField` and then `class X(CharField)` is the same class as
# `models.CharField`. A `CharField` bound from another module is somebody else's class, and the
# importer cannot know its column, so that case keeps the cannot-read marker.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a bare base resolves only through a Django import (#1041)" begin
    source = """
from django.db import models
from django.db.models import CharField
from timing.fields import CharField as TimingCharField

class CircuitRefField(CharField):
    pass

class LapTimeField(TimingCharField):
    pass

class Circuit(models.Model):
    circuitref = CircuitRefField(max_length=255)
    best_lap = LapTimeField(max_length=12)
"""
    generated, config_key = import_subclass_source(source)
    try
        @test occursin("circuitref = Models.CharField(max_length=255)", generated)
        @test occursin("is CircuitRefField(CharField) — imported as CharField", generated)
        # The field class itself is not reported as a skipped class whose ancestry was lost: a
        # Django-bound field base says it is a custom field, not a model. A base bound from
        # elsewhere still gets that report, as it did before #1041.
        @test !occursin("class 'CircuitRefField' inherits", generated)
        @test occursin("class 'LapTimeField' inherits 'TimingCharField'", generated)
        # `TimingCharField` is bound from `timing.fields`, which is not Django. The column is not
        # imported, and the marker is the unchanged cannot-read one: no subclass reason is invented.
        @test !occursin("best_lap = Models.", generated)
        @test occursin("# PormG: field 'best_lap' on 'Circuit' (models.py line 13) " * CANNOT_READ *
                       " Declare it in PormG by hand; until you do, the column is still in the " *
                       "database and absent from this model, so makemigrations reads it as drift " *
                       "and proposes DROPPING it.", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): what stays unresolved
# A from-scratch `models.Field` subclass has no column type the importer can know. A base from a
# third-party package is outside the scope. An inheritance cycle is malformed Python. All three
# keep the cannot-read marker, and the cycle must terminate rather than recurse forever.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a Field subclass, a third-party base and a cycle stay unresolved (#1041)" begin
    source = """
from django.db import models
from encrypted_model_fields.fields import EncryptedCharField

class TelemetryField(models.Field):
    pass

class SecretNoteField(EncryptedCharField):
    pass

class LoopAField(LoopBField):
    pass

class LoopBField(LoopAField):
    pass

class Race(models.Model):
    telemetry = TelemetryField()
    note = SecretNoteField(max_length=40)
    loop = LoopAField(max_length=4)
"""
    generated, config_key = import_subclass_source(source)
    try
        for name in ("telemetry", "note", "loop")
            @test !occursin("$(name) = Models.", generated)
            @test occursin("# PormG: field '$(name)' on 'Race'", generated)
        end
        @test count(CANNOT_READ, generated) == 3
        # None of them was resolved, so none carries a refusal reason or an "imported as" note.
        @test !occursin("subclasses", generated)
        @test !occursin("imported as", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): schema hooks refuse, __init__ imports with a caveat
# `db_type` (and its siblings) decides the column itself, so the base type is provably not the
# column, and declaring it would hand `makemigrations` a wrong ALTER. The marker names the method.
# The same holds for a base the importer cannot see, since it could override the column too. An
# `__init__` override only fills in options, so the field imports, and the marker says options may
# be missing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "schema hooks and unseen bases refuse; __init__ imports with a caveat (#1041)" begin
    source = """
from django.db import models
from audit.mixins import AuditMixin

class CaseInsensitiveField(models.CharField):
    def db_type(self, connection):
        return "citext"

class UpperMixin:
    def get_prep_value(self, value):
        return value.upper()

class LowerNameField(UpperMixin, CaseInsensitiveField):
    pass

class AuditedCodeField(AuditMixin, models.CharField):
    pass

class PaddedCodeField(models.CharField):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("max_length", 3)
        super().__init__(*args, **kwargs)

class UpperCodeField(UpperMixin, models.CharField):
    pass

class Constructor(models.Model):
    name = CaseInsensitiveField(max_length=255)
    nationality = LowerNameField(max_length=255)
    audited = AuditedCodeField(max_length=8)
    code = PaddedCodeField()
    ref = UpperCodeField(max_length=10)
"""
    generated, config_key = import_subclass_source(source)
    try
        # db_type, directly and through a subclass whose OTHER base is an in-file mixin.
        @test !occursin("name = Models.", generated)
        @test occursin("# PormG: field 'name' on 'Constructor' (models.py line 27) " * CANNOT_READ *
                       " 'CaseInsensitiveField' subclasses CharField, but 'CaseInsensitiveField' " *
                       "overrides db_type(), so its column is not necessarily a CharField, so it is " *
                       "not imported as one.", generated)
        @test !occursin("nationality = Models.", generated)
        @test occursin("'LowerNameField' subclasses CharField, but 'CaseInsensitiveField' overrides " *
                       "db_type()", generated)

        # A mixin bound from outside the import: unknowable, so refused.
        @test !occursin("audited = Models.", generated)
        @test occursin("'AuditedCodeField' subclasses CharField, but 'AuditedCodeField' inherits " *
                       "'AuditMixin', which the importer cannot see", generated)

        # __init__: imported from the call's options, with the caveat.
        @test occursin("code = Models.CharField()", generated)
        @test occursin("is PaddedCodeField(models.CharField) — imported as CharField", generated)
        @test occursin("Its class chain also overrides __init__, which may supply options", generated)

        # An in-file mixin with no schema hook is harmless: the field imports, with no caveat.
        @test occursin("ref = Models.CharField(max_length=10)", generated)
        @test occursin("is UpperCodeField(models.CharField) — imported as CharField", generated)
        @test count("overrides __init__", generated) == 1
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): a ForeignKey subclass keeps its relation
# Once the base is read, the field goes through the ordinary path, so a `ForeignKey` subclass gets
# Django's `<name>_id` column and its target. The generated module must still load.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a ForeignKey subclass imports as a ForeignKey (#1041)" begin
    source = """
from django.db import models

class TeamKey(models.ForeignKey):
    pass

class Constructor(models.Model):
    name = models.CharField(max_length=255)

class Result(models.Model):
    constructor = TeamKey(Constructor, on_delete=models.CASCADE)
"""
    generated, config_key = import_subclass_source(source; output_file = "field_subclass_fk.jl")
    try
        @test occursin(r"constructor_id = Models\.ForeignKey\(\"Constructor\", pk_field=\"id\", on_delete=CASCADE\)", generated)
        @test occursin("is TeamKey(models.ForeignKey) — imported as ForeignKey", generated)
        # The module evaluates and the FK target resolves by binding, as `set_models` does.
        sandbox = Module()
        Core.eval(sandbox, Meta.parse(generated))
        mod = Core.eval(sandbox, :(field_subclass_fk))
        result = Core.eval(mod, :Result)
        @test haskey(result.fields, "constructor_id")
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the author's vocabulary in autofields_ignore and #410
# `autofields_ignore` drops a field by the name the author typed, so the custom class name works,
# and nothing then says "imported as". A subclass of a type PormG does not implement takes the
# #410 skip, with the subclass named, and `strict_fields = true` raises for it as for the type
# itself.
# ─────────────────────────────────────────────────────────────────────────────
@testset "autofields_ignore and the #410 skip name the custom class (#1041)" begin
    source = """
from django.db import models

class DriverCodeField(models.CharField):
    pass

class GridSlotField(models.SmallIntegerField):
    pass

class Qualifying(models.Model):
    code = DriverCodeField(max_length=3)
    grid = GridSlotField()
"""
    generated, config_key = import_subclass_source(source; output_file = "field_subclass_ignore.jl",
                                                   autofields_ignore = ["Manager", "DriverCodeField"])
    try
        @test !occursin("code = Models.", generated)
        @test !occursin("is DriverCodeField(models.CharField) — imported as", generated)

        @test !occursin("grid = Models.", generated)
        @test occursin("# PormG: field 'grid' on 'Qualifying' (models.py line 11) is a " *
                       "GridSlotField, a subclass of models.SmallIntegerField, which PormG does not " *
                       "implement — NOT imported.", generated)
        # The skipped column is not also announced as imported.
        @test !occursin("imported as SmallIntegerField", generated)
    finally
        cleanup_subclass_import!(config_key)
    end

    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    try
        err = try
            import_models_from_django(source; db = config_key, file = "strict.jl",
                                      force_replace = true, strict_fields = true)
            nothing
        catch e
            e
        end
        @test err isa PormG.InvalidMigrationError
        @test occursin("a GridSlotField, a subclass of models.SmallIntegerField", sprint(showerror, err))
        @test occursin("add \"GridSlotField\" to autofields_ignore", sprint(showerror, err))
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): a field class from another app of the same import
# The class is resolved through the import table exactly as a model base is (#370), so a field
# class `core` defines and `racing` imports resolves. The same name, never imported, does not: a
# name the module never bound is not in scope in Python.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a field class imported from another app resolves; an unimported one does not (#1041)" begin
    core = """
from django.db import models

class DriverCodeField(models.CharField):
    pass
"""
    racing = """
from django.db import models
from core.models import DriverCodeField

class Driver(models.Model):
    code = DriverCodeField(max_length=3)
"""
    access = """
from django.db import models

class Steward(models.Model):
    code = DriverCodeField(max_length=3)
"""
    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    try
        import_models_from_django(["core" => core, "racing" => racing, "access" => access];
                                  db = config_key, file = "field_subclass_apps.jl",
                                  force_replace = true)
        generated = read(joinpath(config_key, "field_subclass_apps.jl"), String)
        @test occursin(r"\nDriver = Models\.Model\(db_table = \"racing_driver\",\n  id = Models\.IDField\(\),\n  code = Models\.CharField\(max_length=3\)\)", generated)
        @test occursin("field 'code' on 'racing.Driver' (models.py line 5) is " *
                       "DriverCodeField(models.CharField) — imported as CharField", generated)
        # `access` never imported the class, so the field stays unread there.
        @test occursin("# PormG: field 'code' on 'access.Steward' (models.py line 4) " * CANNOT_READ,
                       generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the note never outlives the declaration it describes
# A child re-declaring a field it inherited is the ordinary, silent abstract-base override. The
# file then holds the CHILD's column, so an "imported as CharField with the call's own options" note
# about the base's statement would describe a declaration that is not there. The same holds when a
# later statement collides on the column (#429), and that report names the class the author typed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "an overridden custom field leaves no 'imported as' note (#1041)" begin
    source = """
from django.db import models

class DriverCodeField(models.CharField):
    pass

class TeamKey(models.ForeignKey):
    pass

class Person(models.Model):
    code = DriverCodeField(max_length=3)

    class Meta:
        abstract = True

class Driver(Person):
    code = models.CharField(max_length=5)

class Constructor(models.Model):
    name = models.CharField(max_length=255)

class Result(models.Model):
    constructor = TeamKey(Constructor, on_delete=models.CASCADE)
    constructor_id = models.IntegerField()
"""
    generated, config_key = import_subclass_source(source; output_file = "field_subclass_override.jl")
    try
        # The child's own declaration is what the file holds, and nothing claims otherwise.
        @test occursin("code = Models.CharField(max_length=5)", generated)
        @test !occursin("is DriverCodeField(models.CharField) — imported as", generated)
        # The collision report names `TeamKey`, as the source spelled it, and no note says the lost
        # ForeignKey was imported.
        @test occursin("declares 'constructor' (TeamKey, models.py line 22)", generated)
        @test !occursin("imported as ForeignKey", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the class name is not what makes it a field
# `class Money(models.DecimalField)` resolves to a Django field type, so `salary = Money(...)` is
# a column whatever the class is called. Before, it was dropped with no marker at all, because the
# old reporter only looked for a `Field`/`Key` suffix. A refused one is reported, too.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a custom field class without a Field suffix still resolves (#1041)" begin
    source = """
from django.db import models

class Money(models.DecimalField):
    pass

class Citext(models.TextField):
    def db_type(self, connection):
        return "citext"

class Constructor(models.Model):
    budget = Money(max_digits=12, decimal_places=2)
    motto = Citext()
"""
    generated, config_key = import_subclass_source(source)
    try
        @test occursin("budget = Models.DecimalField(", generated)
        @test occursin("is Money(models.DecimalField) — imported as DecimalField", generated)
        @test !occursin("motto = Models.", generated)
        @test occursin("# PormG: field 'motto' on 'Constructor' (models.py line 12) " * CANNOT_READ *
                       " 'Citext' subclasses TextField, but 'Citext' overrides db_type()", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): every schema hook refuses, and abstract Django bases stay unresolved
# Each method in `_FIELD_SCHEMA_HOOKS` decides the column, so each one alone must refuse the
# import. `RelatedField` is as abstract as `Field`, so a subclass of it has no knowable column and
# keeps the plain marker rather than the #410 "PormG does not implement" wording. A base imported
# from `django.db.models.fields` counts like one from `django.db.models`.
# ─────────────────────────────────────────────────────────────────────────────
@testset "each schema hook refuses; RelatedField stays unresolved (#1041)" begin
    for hook in ("db_type", "db_parameters", "get_internal_type", "rel_db_type", "contribute_to_class")
        source = """
from django.db import models

class HookedField(models.CharField):
    def $(hook)(self, *args, **kwargs):
        return None

class Circuit(models.Model):
    name = HookedField(max_length=255)
"""
        generated, config_key = import_subclass_source(source)
        try
            @test !occursin("name = Models.", generated)
            @test occursin("'HookedField' overrides $(hook)()", generated)
        finally
            cleanup_subclass_import!(config_key)
        end
    end

    source = """
from django.db import models
from django.db.models.fields import CharField
from django.db.models.fields.related import RelatedField

class LocationField(CharField):
    pass

class OddRelationField(RelatedField):
    pass

class Circuit(models.Model):
    location = LocationField(max_length=255)
    odd = OddRelationField()
"""
    generated, config_key = import_subclass_source(source)
    try
        @test occursin("location = Models.CharField(max_length=255)", generated)
        @test !occursin("odd = Models.", generated)
        @test occursin("# PormG: field 'odd' on 'Circuit' (models.py line 13) " * CANNOT_READ, generated)
        @test !occursin("RelatedField, which PormG does not implement", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): a merged statement resolves in its OWNER's module
# A field statement merged in from an abstract base in another app names classes in that base's
# module, as Python does (#402). Here both apps define a `DriverCodeField` with different bases, so
# resolving the base's statement in the child's app would type the column wrongly.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a merged statement resolves its field class in the owner's app (#1041)" begin
    core = """
from django.db import models

class DriverCodeField(models.CharField):
    pass

class Person(models.Model):
    code = DriverCodeField(max_length=3)

    class Meta:
        abstract = True
"""
    racing = """
from django.db import models
from core.models import Person

class DriverCodeField(models.IntegerField):
    pass

class Driver(Person):
    number = DriverCodeField()
"""
    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    try
        import_models_from_django(["core" => core, "racing" => racing];
                                  db = config_key, file = "field_subclass_owner.jl",
                                  force_replace = true)
        generated = read(joinpath(config_key, "field_subclass_owner.jl"), String)
        # `code` comes from core's statement, so core's CharField subclass types it...
        @test occursin("code = Models.CharField(max_length=3)", generated)
        # ...while racing's own statement uses racing's IntegerField subclass.
        @test occursin("number = Models.IntegerField()", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the console agrees with the artifact
# Every annotated row of the import contract emits a `@warn` as well as a marker. The import-as-base
# note does too, and a refusal's warning carries the reason the marker gives.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the import-as-base note and a refusal both warn (#1041)" begin
    source = """
from django.db import models

class DriverCodeField(models.CharField):
    pass

class Citext(models.TextField):
    def db_type(self, connection):
        return "citext"

class Driver(models.Model):
    code = DriverCodeField(max_length=3)
    surname = Citext()
"""
    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    try
        @test_logs (:warn, r"custom field class imported as its Django base type") (:warn, r"field-shaped call the importer cannot read") match_mode = :any import_models_from_django(source; db = config_key, file = "field_subclass_logs.jl", force_replace = true)
        logger = Test.TestLogger(min_level = Logging.Warn)
        with_logger(logger) do
            import_models_from_django(source; db = config_key, file = "field_subclass_logs.jl",
                                      force_replace = true)
        end
        refused = [r for r in logger.logs if occursin("cannot read", string(r.message))]
        @test length(refused) == 1
        @test occursin("overrides db_type()", string(Dict(refused[1].kwargs)[:reason]))
    finally
        cleanup_subclass_import!(config_key)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1041): the note waits for the name rule and the relation pass
# A child declaring the same NAME as a different kind of field replaces the inherited one in Django
# although the two write different columns (`code` vs `code_id`), so the inherited custom field's
# note goes. A relation subclass whose target is outside the import is dropped (ManyToMany) or
# degraded to a plain column (ForeignKey) by the relation pass, which reports it itself, and
# "imported as ForeignKey" beside that report would contradict it.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the note respects the name rule and the relation pass (#1041)" begin
    source = """
from django.db import models

class CodeField(models.CharField):
    pass

class TagsField(models.ManyToManyField):
    pass

class OwnerKey(models.ForeignKey):
    pass

class Team(models.Model):
    name = models.CharField(max_length=255)

class Person(models.Model):
    code = CodeField(max_length=3)

    class Meta:
        abstract = True

class Driver(Person):
    code = models.ForeignKey(Team, on_delete=models.CASCADE)
    tags = TagsField("contenttypes.ContentType")
    owner = OwnerKey("auth.Group", on_delete=models.CASCADE)
"""
    generated, config_key = import_subclass_source(source; output_file = "field_subclass_relpass.jl")
    try
        @test !occursin("is CodeField(models.CharField) — imported as", generated)
        # The relation pass dropped / degraded these, and said so; no note claims otherwise.
        @test !occursin("tags = Models.", generated)
        @test occursin("owner_id = Models.BigIntegerField(", generated)
        @test !occursin("imported as ManyToManyField", generated)
        @test !occursin("imported as ForeignKey", generated)
    finally
        cleanup_subclass_import!(config_key)
    end

    # The same subclasses with targets INSIDE the import keep their relation, and their notes.
    source_ok = """
from django.db import models

class TagsField(models.ManyToManyField):
    pass

class OwnerKey(models.ForeignKey):
    pass

class Team(models.Model):
    name = models.CharField(max_length=255)

class Driver(models.Model):
    tags = TagsField(Team)
    owner = OwnerKey(Team, on_delete=models.CASCADE)
"""
    generated, config_key = import_subclass_source(source_ok; output_file = "field_subclass_relok.jl")
    try
        @test occursin("is TagsField(models.ManyToManyField) — imported as ManyToManyField", generated)
        @test occursin("is OwnerKey(models.ForeignKey) — imported as ForeignKey", generated)
    finally
        cleanup_subclass_import!(config_key)
    end
end
