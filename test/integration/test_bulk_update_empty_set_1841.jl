if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# ─────────────────────────────────────────────────────────────────────────────
# #1841: a bulk_update whose every field is a key leaves nothing for SET.
# Tests: the shapes that left the SET list empty — filters= keys alone, match_on keys alone (the primary key, another
#   field), the two together, the primary-key fallback, and a table whose every column is the primary key — on this
#   run's engine (PostgreSQL under either driver, SQLite, MySQL).
# Expected: each raises `QueryBuildError` naming the fields and where their keys came from, before any SQL; the race
#   row they name is unchanged. A `filters=` lookup on the field (`year__@in`) still renders a SET of that field.
# Matters: the statement used to go out with an empty SET list, a syntax error the server raised as a
#   `StatementError` after it was sent; the refusal is the same on every engine, decided where the SET list is.
# ─────────────────────────────────────────────────────────────────────────────
@testset "bulk_update refuses an empty SET list before any SQL (#1841)" begin
    strip_ansi(s) = replace(s, r"\e\[[0-9;]*m" => "")
    refusal(f) = try
        f(); nothing
    catch e
        e isa PormG.QueryBuildError || rethrow()
        strip_ansi(sprint(showerror, e))
    end
    snapshot() = (r = M.Race.objects.filter("raceid" => 1).values("raceid", "year", "round").list()[1];
                  (r["raceid"], r["year"], r["round"]))
    before = snapshot()
    rid, y = before[1], before[2]
    sid = M.Status.objects.filter("statusid" => 1).values("statusid").list()[1]["statusid"]
    tail = "nothing is left to update. A key is matched, never set: name in columns= at least one field that is not a key."
    pk = "the primary key, which bulk_update matches on when match_on= is not given"
    cases = (
        ("filters= keys alone",
         (; kw...) -> PormG.bulk_update(M.Race.objects, (raceid = [rid], year = [y]); columns = ["year"], filters = ["year" => y], kw...),
         "bulk_update: every field in columns= (year) is a key in filters=; $(tail)"),
        ("match_on keys alone, the primary key",
         (; kw...) -> PormG.bulk_update(M.Race.objects, (raceid = [rid],); columns = ["raceid"], match_on = ["raceid"], kw...),
         "bulk_update: every field in columns= (raceid) is a key in match_on=; $(tail)"),
        ("match_on keys alone, another field",
         (; kw...) -> PormG.bulk_update(M.Race.objects, (year = [y],); columns = ["year"], match_on = ["year"], kw...),
         "bulk_update: every field in columns= (year) is a key in match_on=; $(tail)"),
        ("match_on and filters= together",
         (; kw...) -> PormG.bulk_update(M.Race.objects, (raceid = [rid], year = [y]); columns = ["year"], match_on = ["raceid"],
                                 filters = ["year" => y], kw...),
         "bulk_update: every field in columns= (year) is a key in filters=; $(tail)"),
        ("the primary-key fallback",
         (; kw...) -> PormG.bulk_update(M.Race.objects, (raceid = [rid],); columns = ["raceid"], kw...),
         "bulk_update: every field in columns= (raceid) is $(pk); $(tail)"),
        ("every column of the table a key, columns= not given",
         (; kw...) -> PormG.bulk_update(M.Status.objects, (statusid = [sid],); kw...),
         "bulk_update: every column of the table (statusid) is $(pk); $(tail)"),
    )
    for (label, call, expected) in cases
        @test (label, refusal(() -> call())) == (label, expected)
        # The inspection modes refuse the same way: the statement is never built.
        @test (label, refusal(() -> call(show_query = :sql))) == (label, expected)
    end
    @test snapshot() == before
    # A lookup on the field is a predicate, not a key: the field stays in SET.
    d = PormG.bulk_update(M.Race.objects, (raceid = [rid], year = [y]); columns = ["year"], match_on = ["raceid"],
                          filters = ["year__@in" => [y]], show_query = :sql)
    @test occursin(r"SET\s+\S*year\S*\s*=", string(d))
end
