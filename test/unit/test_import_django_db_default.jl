using Test
using Logging
using PormG
using PormG.Migrations

isdefined(Main, :SQLite) || include(joinpath(@__DIR__, "..", "load_drivers.jl"))

# ─────────────────────────────────────────────────────────────────────────────
# Django Importer (#1469): `db_default` is translated, never copied
#
# Django's `db_default` takes a literal (wrapped in `Value()`, so a Python string is DATA) or an
# expression. PormG's `db_default` takes only an expression, and since #1033 a literal belongs in
# `default=`. The importer passed Django's value straight through, so `db_default=0` aborted the
# import of every model in the file ("must be a String"), `Now()` and `"Finished"` aborted it too,
# and `db_default="CURRENT_DATE"` imported SILENTLY as the function: a text default became today's
# date. Every case below needs no database: the importer writes model text.
# ─────────────────────────────────────────────────────────────────────────────

"""
    import_db_default_source(field_line) -> String

Import a `models.py` holding `Dim_status`, a `Lap` class with `field_line` as its one field, and a
`Sibling` class after it, under a throwaway config. Returns the generated text.
"""
function import_db_default_source(field_line::AbstractString)
    config_key = mktempdir()
    PormG.config[config_key] = PormG.Configuration.Settings(db_def_folder = config_key)
    source = """
    from django.db import models
    from django.db.models.functions import Now, Lower
    from django.utils import timezone
    from django.contrib.postgres.fields import ArrayField

    LAPS = 7
    BAD_LENGTH = "ten"
    RESULT_DEFAULT = "Finished"

    class Dim_status(models.Model):
        status = models.CharField(max_length=50)

    class Lap(models.Model):
        $(field_line)

    class Sibling(models.Model):
        position = models.IntegerField()
    """
    try
        with_logger(NullLogger()) do
            import_models_from_django(source; db = config_key, file = "import_1469.jl",
                                      force_replace = true)
        end
        return read(joinpath(config_key, "import_1469.jl"), String)
    finally
        delete!(PormG.config, config_key)
        isdir(config_key) && rm(config_key; recursive = true)
    end
end

# The generated declaration line of `name`, or `nothing`. `Lap` has one field, so its line carries
# the model's closing parenthesis too.
function field_line(generated, name)
    for l in split(generated, '\n')
        s = strip(l)
        startswith(s, "$(name) = Models.") && return s
    end
    return nothing
end

const SIBLING = "position = Models.IntegerField()"

@testset "a literal db_default on a ForeignKey imports as default= (#1469)" begin
    # Expected: `statusid_id = Models.ForeignKey("Dim_status", default=0, …)`, and the next model.
    # Why: this one field aborted the import of the whole file ("'db_default' must be a String").
    g = import_db_default_source("statusid = models.ForeignKey(Dim_status, on_delete=models.RESTRICT, default=0, db_default=0, db_constraint=False)")
    @test field_line(g, "statusid_id") ==
          "statusid_id = Models.ForeignKey(\"Dim_status\", default=0, pk_field=\"id\", on_delete=RESTRICT, db_constraint=false))"
    @test !occursin("db_default", g)
    @test occursin(SIBLING, g)
end

@testset "a Bool or Int db_default imports as default=, with no marker when default agrees (#1469)" begin
    # Expected: `default=false` / `default=0` and no `# PormG:` comment: the two Django options say
    # one thing. Why: both aborted the import ("got Bool" / "got Int64").
    g = import_db_default_source("finished = models.BooleanField(default=False, db_default=False)")
    @test field_line(g, "finished") == "finished = Models.BooleanField(default=false))"
    @test !occursin("# PormG", g)
    g = import_db_default_source("laps = models.IntegerField(default=0, db_default=0)")
    @test field_line(g, "laps") == "laps = Models.IntegerField(default=0))"
    @test !occursin("# PormG", g)
    # `Value(<literal>)` is the spelling Django turns a literal into; a negative integer and a
    # constant are literals too.
    @test field_line(import_db_default_source("laps = models.IntegerField(db_default=models.Value(0))"), "laps") ==
          "laps = Models.IntegerField(default=0))"
    @test field_line(import_db_default_source("grid = models.IntegerField(default=-1, db_default=-1)"), "grid") ==
          "grid = Models.IntegerField(default=-1))"
    @test field_line(import_db_default_source("laps = models.IntegerField(db_default=LAPS)"), "laps") ==
          "laps = Models.IntegerField(default=7))"
end

@testset "Now() imports as the portable CURRENT_TIMESTAMP, or CURRENT_DATE on a DateField (#1469)" begin
    # Expected: `db_default="CURRENT_TIMESTAMP"`. Why: Django's own docs example aborted the import
    # ("not one of the expressions PormG can render on every engine").
    g = import_db_default_source("time = models.DateTimeField(db_default=Now())")
    @test field_line(g, "time") == "time = Models.DateTimeField(db_default=\"CURRENT_TIMESTAMP\"))"
    @test occursin(SIBLING, g)
    g = import_db_default_source("date = models.DateField(db_default=models.functions.Now())")
    @test field_line(g, "date") == "date = Models.DateField(db_default=\"CURRENT_DATE\"))"
    # `default=timezone.now` beside it says the same thing in Python: both are kept, no marker.
    g = import_db_default_source("time = models.DateTimeField(default=timezone.now, db_default=Now())")
    @test field_line(g, "time") == "time = Models.DateTimeField(auto_now_add=true, db_default=\"CURRENT_TIMESTAMP\"))"
    @test !occursin("# PormG", g)
end

@testset "a string db_default is text, never SQL (#1469)" begin
    # Expected: `default="Finished"` and `default="CURRENT_DATE"`, never `db_default=`. Why: Django
    # reads a Python string as data. The first aborted with advice that rendered a column reference;
    # the second imported SILENTLY as the function, so the column's default became today's date.
    g = import_db_default_source("outcome = models.CharField(max_length=20, db_default=\"Finished\")")
    @test field_line(g, "outcome") == "outcome = Models.CharField(max_length=20, default=\"Finished\"))"
    g = import_db_default_source("outcome = models.CharField(max_length=20, db_default=\"CURRENT_DATE\")")
    @test field_line(g, "outcome") == "outcome = Models.CharField(max_length=20, default=\"CURRENT_DATE\"))"
    @test !occursin("db_default", g)
    g = import_db_default_source("code = models.CharField(max_length=5, db_default=Value(\"HAM\", output_field=models.CharField()))")
    @test field_line(g, "code") == "code = Models.CharField(max_length=5, default=\"HAM\"))"
    # `Value(value, output_field)` by position: the second argument types the value, nothing more.
    g = import_db_default_source("code = models.CharField(max_length=5, db_default=Value('VER', models.CharField()))")
    @test field_line(g, "code") == "code = Models.CharField(max_length=5, default=\"VER\"))"
    # On a date or datetime field the TEXT is not a date: the field refuses it and the marker names
    # Django's keyword, `db_default`, not the `default` it was imported as. Before #1469 this was the
    # SQL function.
    g = import_db_default_source("time = models.DateTimeField(db_default=\"CURRENT_TIMESTAMP\")")
    @test field_line(g, "time") == "time = Models.DateTimeField())"
    @test occursin("# PormG: field 'time' on 'Lap' — `db_default` rejected and dropped", g)
end

@testset "default and db_default disagree: db_default wins, with a marker (#1469)" begin
    # Expected: `default=0` (the db_default) and a marker naming the dropped `default=1`. Why: PormG
    # takes one default; Django's `default` is Python-side only, and the database Django built holds
    # the db_default, which is what PormG's migrations compare against (decided on #1469).
    g = import_db_default_source("points = models.IntegerField(default=1, db_default=0)")
    @test field_line(g, "points") == "points = Models.IntegerField(default=0))"
    @test occursin("# PormG: field 'points' on 'Lap' declares both `default=1` and `db_default=0`; " *
                   "PormG takes one default, so `db_default` was kept and `default` dropped.", g)
    # The same rule for an expression: the literal default goes, `CURRENT_TIMESTAMP` stays.
    g = import_db_default_source("time = models.DateTimeField(default=\"2024-03-02T15:00:00\", db_default=Now())")
    @test field_line(g, "time") == "time = Models.DateTimeField(db_default=\"CURRENT_TIMESTAMP\"))"
    @test occursin("declares both `default=\"2024-03-02T15:00:00\"` and `db_default=Now()`", g)
    # `db_default=None` is no database default, and it still wins over a Python-side one.
    g = import_db_default_source("grid = models.IntegerField(null=True, default=1, db_default=None)")
    @test field_line(g, "grid") == "grid = Models.IntegerField(null=true))"
    @test occursin("declares both `default=1` and `db_default=None`; `db_default=None` declares no " *
                   "database default, and it wins: `default` was dropped, so the column has no default.", g)
    # Markers quote the source as written, so a float or a negative number greps back to models.py.
    g = import_db_default_source("grid = models.IntegerField(default=-1, db_default=-2)")
    @test occursin("declares both `default=-1` and `db_default=-2`", g)
end

@testset "an untranslatable db_default is reported and the file still imports (#1469)" begin
    # Expected: the field without a default, a marker naming the expression, and `Sibling` imported.
    # Why: one unsupported keyword used to cost every model in the file, not one field's default.
    g = import_db_default_source("name = models.CharField(max_length=20, db_default=Lower(\"x\"))")
    @test field_line(g, "name") == "name = Models.CharField(max_length=20))"
    @test occursin("has `db_default=Lower(\"x\")`, which is neither one literal the importer can " *
                   "read nor `Now()` on a date or datetime field — not imported. If it is a value, " *
                   "declare it by hand as `default = …`", g)
    @test occursin(SIBLING, g)
    # `Now()` on a type with no current-time meaning is the same case.
    g = import_db_default_source("laps = models.IntegerField(db_default=Now())")
    @test field_line(g, "laps") == "laps = Models.IntegerField())"
    @test occursin("has `db_default=Now()`, which is neither one literal", g)
    # A literal the field refuses degrades through #342's retry like any refused `default`.
    g = import_db_default_source("laps = models.IntegerField(db_default=\"many\")")
    @test field_line(g, "laps") == "laps = Models.IntegerField())"
    @test occursin("# PormG: field 'laps' on 'Lap' — `db_default` rejected and dropped", g)
    @test occursin(SIBLING, g)
    # `None` is `DEFAULT NULL`, which is no default: nothing to import, nothing to report.
    g = import_db_default_source("note = models.CharField(max_length=20, null=True, db_default=None)")
    @test field_line(g, "note") == "note = Models.CharField(max_length=20, null=true))"
    @test !occursin("# PormG", g)
end

@testset "a db_default read through a constant or on an ArrayField element is reported as db_default (#1469)" begin
    # Expected: #948's retry names `db_default` (from `RESULT_DEFAULT`), and the element's dropped
    # column option is named `db_default`. Why: the importer moves the literal into PormG's `default`,
    # and a marker naming `default` sends the reader to a keyword their models.py does not contain.
    # Both messages read the same before #1469, when nothing moved; these pin them against the
    # translation, and the first pins the constant bookkeeping `parse_field_args` rewrites after it.
    g = import_db_default_source("code = models.CharField(max_length=BAD_LENGTH, db_default=RESULT_DEFAULT)")
    @test occursin("`max_length` (from `BAD_LENGTH`), `db_default` (from `RESULT_DEFAULT`) rejected and dropped", g)
    @test occursin(SIBLING, g)
    g = import_db_default_source("laps = ArrayField(models.IntegerField(db_default=0))")
    @test field_line(g, "laps") == "laps = Models.ArrayField(Models.IntegerField()))"
    @test occursin("IntegerField element declares `db_default` — a column option", g)
end
