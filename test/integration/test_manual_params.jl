# ─────────────────────────────────────────────────────────────────────────────
# Manual-params raw SQL (#218): fetch / fetch_async accept a plain values array
# The raw-SQL escape hatch now binds a user-supplied Vector/Tuple of values. The
# caller writes the placeholder native to their backend — $1,$2 on PostgreSQL,
# ? on SQLite — and PormG performs NO placeholder translation (the low-level-driver
# convention: Go database/sql, Python DB-API, Julia DBInterface). These tests pin
# that the array-bound raw query returns the same value as the ORM equivalent on
# both backends, that positional binding order is honored, that a hostile value
# stays bound (never interpreted as SQL), and that NULL binds from both `missing`
# and `nothing` (the latter via the #218 nothing→missing normalization).
# ─────────────────────────────────────────────────────────────────────────────
if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

using Test

settings = PormG.config[PORMG_DB_FOLDER]
pool     = settings.connections

# Backend-native placeholder: PostgreSQL numbers them ($1,$2…), SQLite is positional (?).
# PormG does no translation (#218) — the caller writes the dialect's own marker. This helper
# is the entire "portability" surface of these tests.
ph(i) = pool isa PormG.PormGPostgres ? "\$$(i)" : "?"

# ─────────────────────────────────────────────────────────────────────────────
# A — fetch parity vs ORM (single param)
# The array-bound raw count must equal the ORM's own count. Cross-checked against an
# independent ORM computation (not "it ran"); reverting the widening makes fetch(...; params=[...])
# a MethodError, so this errors rather than silently passing.
# ─────────────────────────────────────────────────────────────────────────────
@testset "fetch parity vs ORM (single param)" begin
    n_orm = M.Driver.objects.filter("nationality" => "Brazilian").count()
    @test n_orm > 0   # guard: a vacuous 0 == 0 would prove nothing

    sql = "SELECT count(*) AS c FROM driver WHERE nationality = $(ph(1))"
    df  = DataFrame(fetch(settings, sql; params = ["Brazilian"]))
    @test df[1, :c] == n_orm
end

# ─────────────────────────────────────────────────────────────────────────────
# B — fetch_async + await_result parity (positional ManualParams overload)
# Same value via the positional array form `fetch_async(settings, sql, [...])`, which exercises
# the widened positional overload (distinct from the keyword path in A).
# ─────────────────────────────────────────────────────────────────────────────
@testset "fetch_async positional-array parity" begin
    n_orm = M.Driver.objects.filter("nationality" => "Brazilian").count()
    sql   = "SELECT count(*) AS c FROM driver WHERE nationality = $(ph(1))"

    task = fetch_async(settings, sql, ["Brazilian"])
    df   = DataFrame(await_result(task))
    @test df[1, :c] == n_orm
end

# ─────────────────────────────────────────────────────────────────────────────
# C — multiple params + positional ordering
# Two placeholders: the values must bind in array order. The swapped-order call returns 0 rows
# (a real driver/name never equals a nationality), which can only happen if positional binding is
# honored end to end — the ordering proof.
# ─────────────────────────────────────────────────────────────────────────────
@testset "multiple params bind in positional order" begin
    d        = M.Driver.objects.filter("nationality" => "Brazilian").order_by("surname").list()[1]
    nat, sur = d.nationality, d.surname
    n_orm    = M.Driver.objects.filter("nationality" => nat, "surname" => sur).count()
    @test n_orm > 0

    sql = "SELECT count(*) AS c FROM driver WHERE nationality = $(ph(1)) AND surname = $(ph(2))"
    @test DataFrame(fetch(settings, sql; params = [nat, sur]))[1, :c] == n_orm   # correct order
    @test DataFrame(fetch(settings, sql; params = [sur, nat]))[1, :c] == 0       # swapped → empty
end

# ─────────────────────────────────────────────────────────────────────────────
# D — injection value stays bound (0 rows + table intact)
# A value containing SQL syntax is bound as data, never parsed. If it were interpolated, the
# first query would match every row (== total) and the second would drop the table.
# ─────────────────────────────────────────────────────────────────────────────
@testset "hostile value stays bound, not interpreted" begin
    total = M.Driver.objects.count()
    sql   = "SELECT count(*) AS c FROM driver WHERE nationality = $(ph(1))"

    @test DataFrame(fetch(settings, sql; params = ["' OR '1'='1"]))[1, :c] == 0
    @test DataFrame(fetch(settings, sql; params = ["x'; DROP TABLE driver; --"]))[1, :c] == 0
    @test M.Driver.objects.count() == total   # table intact — value never executed as SQL
end

# ─────────────────────────────────────────────────────────────────────────────
# E — NULL binds from both `missing` and `nothing`
# A bound NULL is observed via `<param> IS NULL` (a `col = NULL` filter can't — NULL is never
# =-true). PostgreSQL needs an explicit cast to type an all-NULL parameter; SQLite does not.
# The `nothing` case is exactly what the #218 nothing→missing normalization exists to make pass;
# the non-null control makes the assertion non-vacuous.
# ─────────────────────────────────────────────────────────────────────────────
@testset "NULL binds from missing and nothing" begin
    # Alias is `is_null`, not `isnull` — SQLite reserves ISNULL as a postfix operator keyword.
    sql = pool isa PormG.PormGPostgres ?
        "SELECT ($(ph(1))::text IS NULL) AS is_null" :
        "SELECT ($(ph(1)) IS NULL) AS is_null"

    for nullish in (missing, nothing)
        got = DataFrame(fetch(settings, sql; params = [nullish]))[1, :is_null]
        @test got in (true, 1)    # PG returns Bool, SQLite returns Int 1
    end
    ctrl = DataFrame(fetch(settings, sql; params = ["x"]))[1, :is_null]
    @test ctrl in (false, 0)      # control: a non-null value is not NULL
end

# ─────────────────────────────────────────────────────────────────────────────
# F — Tuple params
# The ManualParams union is Union{AbstractVector, Tuple}; a Tuple binds identically to a Vector.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Tuple params bind like a Vector" begin
    n_orm = M.Driver.objects.filter("nationality" => "Brazilian").count()
    sql   = "SELECT count(*) AS c FROM driver WHERE nationality = $(ph(1))"

    df = DataFrame(fetch(settings, sql; params = ("Brazilian",)))
    @test df[1, :c] == n_orm
end
