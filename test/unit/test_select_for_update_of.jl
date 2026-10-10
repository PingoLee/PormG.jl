"""
Unit coverage for #169: `select_for_update(of = …)` resolves each lock target to the FROM-clause
alias the build generated, and renders `FOR UPDATE OF "<alias>"[, …]`.

PostgreSQL's `OF` names a range variable, not a table. PormG always aliases (`FROM "result" as
"Tb"`), so the obvious implementation — rendering the table name — is refused at execution:
`relation "result" in FOR UPDATE/FOR SHARE clause not found in FROM clause`. That is why the
option was deferred in #26. Without it a plain `select_for_update()` locks every table in FROM,
including the ones a `__` filter joins, and fails outright when such a join is LEFT (a nullable
foreign key): PostgreSQL cannot lock the nullable side of an outer join.

Every assertion here ties an `OF` alias to the TABLE it was joined under, read back off the same
statement, so a resolver that returns the wrong alias fails even when the alias count is right.
Hermetic: mock connections, no database.
"""

using Test
using PormG
using PormG.Models

# Dedicated mock connections + config keys: `runtests.jl` includes every unit file into one `Main`,
# so a shared name would let another file's settings decide this file's dialect.
struct SfuOfMockPostgres <: PormG.PormGPostgres end
struct SfuOfMockSQLite <: PormG.PormGSQLite end
PormG.backend_sqlite_version(::SfuOfMockSQLite) = 3045000

PormG.config["sfu_of_pg"] = PormG.Configuration.Settings(
  connections = SfuOfMockPostgres(), change_data = true, db_def_folder = "sfu_of_pg",
)
PormG.config["sfu_of_sl"] = PormG.Configuration.Settings(
  connections = SfuOfMockSQLite(), change_data = true, db_def_folder = "sfu_of_sl",
)

# An F1-shaped slice: `Result → Race → Circuit` forward (INNER), `Result → Driver` forward (INNER),
# `Result → Constructor` NULLABLE (rendered LEFT) and again as `team_id` (INNER, with a `team` short
# form), `Driver.sponsors` ManyToMany, and the reverse
# accessors `Driver.results` / `Race.results`. `set_models` is required: `_build_row_join` reads the
# model's `_module`.
module SfuOfModels
import PormG
import PormG.Models
Circuit = Models.Model("circuit",
  circuitid = Models.IDField(),
  name      = Models.CharField(),
)
Race = Models.Model("race",
  raceid    = Models.IDField(),
  year      = Models.IntegerField(),
  circuitid = Models.ForeignKey(Circuit, on_delete = "CASCADE", related_name = "races"),
)
Sponsor = Models.Model("sponsor",
  sponsorid = Models.IDField(),
  name      = Models.CharField(),
)
Driver = Models.Model("driver",
  driverid    = Models.IDField(),
  nationality = Models.CharField(),
  sponsors    = Models.ManyToManyField(Sponsor, related_name = "drivers"),
)
Constructor = Models.Model("constructor",
  constructorid = Models.IDField(),
  name          = Models.CharField(),
)
Result = Models.Model("result",
  resultid      = Models.IDField(),
  points        = Models.IntegerField(),
  raceid        = Models.ForeignKey(Race, on_delete = "CASCADE", related_name = "results"),
  driverid      = Models.ForeignKey(Driver, on_delete = "CASCADE", related_name = "results"),
  constructorid = Models.ForeignKey(Constructor, on_delete = "CASCADE", related_name = "results", null = true),
  # Django-style `<name>_id` column, so `team` and `team_id` are two spellings of ONE relation.
  team_id       = Models.ForeignKey(Constructor, on_delete = "CASCADE", related_name = "team_results"),
)
PormG.Models.set_models(@__MODULE__, "sfu_of_pg")
end

const SFU = SfuOfModels
import PormG.QueryBuilder: Joined, F

_sfu_err(f) = try f(); nothing catch e; e end
_sfu_msg(e) = replace(sprint(showerror, e), r"\e\[[0-9;]*m" => "")

# The alias a table was joined under in this statement — read off the JOIN line, so an `OF` alias
# is checked against the table it names rather than against a hard-coded `Tb_<n>`.
function _sfu_alias(sql::AbstractString, table::AbstractString)
  m = match(Regex("JOIN \"$(table)\" AS \"([^\"]+)\""), sql)
  m === nothing && error("no JOIN to \"$(table)\" in:\n$(sql)")
  return m.captures[1]
end

# The rendered lock clause: the statement's last non-blank line.
_sfu_lock(sql::AbstractString) = strip(last(filter(!isempty, strip.(split(sql, "\n")))))

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): "self" and forward relation paths resolve to their generated aliases
# `"self"` is the base alias; a path the query joins is the alias that join was emitted under —
# including a hop that is only an INTERMEDIATE step of a longer path, and a chained path. The `OF`
# list keeps the caller's order and drops a second name for an alias already listed.
# ─────────────────────────────────────────────────────────────────────────────
@testset "of = self and forward paths → generated aliases (#169)" begin
  # "self" alone: the base table only, even though the filter joins `driver`.
  q = SFU.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("resultid").
    select_for_update(of = ("self",))
  sql = q.list(show_query = :sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\""

  # self + the joined driver: the second alias is the one `driver` is joined under.
  q = SFU.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("resultid").
    select_for_update(of = ("self", "driverid"))
  sql = q.list(show_query = :sql)
  d = _sfu_alias(sql, "driver")
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\", \"$(d)\""

  # A chained path, and its intermediate hop, each name their own join. The OF order is the
  # caller's (circuit first), not the join order.
  q = SFU.Result.objects.
    values("resultid", "raceid__circuitid__name").
    select_for_update(of = ["raceid__circuitid", "raceid"])
  sql = q.list(show_query = :sql)
  c, r = _sfu_alias(sql, "circuit"), _sfu_alias(sql, "race")
  @test c != r
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(c)\", \"$(r)\""

  # A single String is one target; a repeated target is listed once.
  q = SFU.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("resultid").
    select_for_update(of = "driverid")
  sql = q.list(show_query = :sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(_sfu_alias(sql, "driver"))\""
  q = SFU.Result.objects.values("resultid").select_for_update(of = ("self", "self"))
  @test _sfu_lock(q.list(show_query = :sql)) == "FOR UPDATE OF \"Tb\""

  # Two spellings of one relation — the short form `team` in the filter, both `team_id` and `team`
  # in `of` — resolve to the one join emitted, and the alias is listed once.
  q = SFU.Result.objects.
    filter("team__name" => "Ferrari").
    values("resultid").
    select_for_update(of = ("team_id", "team"))
  sql = q.list(show_query = :sql)
  @test count("JOIN \"constructor\"", sql) == 1
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(_sfu_alias(sql, "constructor"))\""
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): ManyToMany, reverse accessors and cjoin_on aliases
# A ManyToMany path is two joins; the target is the RELATED table, never the link table. A reverse
# accessor names the child table it joins. A `cjoin_on` alias is already user-named and resolves to
# itself — including when the relation its ON clause names was joined only for that clause.
# ─────────────────────────────────────────────────────────────────────────────
@testset "of = ManyToMany, reverse and cjoin_on targets (#169)" begin
  q = SFU.Result.objects.
    filter("driverid__sponsors__name" => "Petrobras").
    values("resultid", "driverid__sponsors__name").   # #1002: the locked rows are projected, so asked for
    select_for_update(of = ("driverid__sponsors",))
  sql = q.list(show_query = :sql)
  s = _sfu_alias(sql, "sponsor")
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(s)\""
  # The link table is joined, and is not what was locked.
  @test _sfu_alias(sql, "driver_sponsors") != s

  # Reverse accessor: Driver → its results.
  q = SFU.Driver.objects.
    filter("results__points" => 25).
    values("driverid", "results__points").
    select_for_update(of = ("self", "results"))
  sql = q.list(show_query = :sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\", \"$(_sfu_alias(sql, "result"))\""

  # cjoin_on alias.
  q = SFU.Result.objects
  q.cjoin_on("Circuit", alias = "c", on = [Joined("c", "circuitid") == F("raceid__circuitid")])
  q.values("resultid")
  q.select_for_update(of = ("self", "c"))
  sql = q.list(show_query = :sql)
  @test occursin("JOIN \"circuit\" AS \"c\"", sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\", \"c\""
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): targets that cannot be locked are refused before the database
# An unknown name, a column path, and a real relation the query never joins each raise
# QueryBuildError listing the targets that WOULD resolve — the query is not widened to make the name
# fit. A target joined LEFT is refused with PostgreSQL's reason, and a name that is both a relation
# path and a cjoin_on alias is AmbiguousFieldError (#492): PormG will not pick which table to lock.
# ─────────────────────────────────────────────────────────────────────────────
@testset "unresolvable, LEFT-joined and ambiguous targets are refused (#169)" begin
  joined = () -> SFU.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("resultid")

  # Unknown name: the choices are what this query can lock.
  err = _sfu_err(() -> joined().select_for_update(of = ("bogus",)).list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  msg = _sfu_msg(err)
  @test occursin("\"bogus\" is not a relation path or cjoin_on alias of this query", msg)
  @test occursin("Choices: self, driverid.", msg)

  # A column through a relation canonicalizes to the relation's prefix — it must not lock `driver`.
  err = _sfu_err(() -> joined().select_for_update(of = ("driverid__nationality",)).list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  @test occursin("\"driverid__nationality\" is not a relation path", _sfu_msg(err))

  # A real relation the query does not join is refused, not joined on the spot.
  err = _sfu_err(() -> joined().select_for_update(of = ("raceid",)).list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  @test occursin("\"raceid\" is a relation on result that this query does not join", _sfu_msg(err))

  # Nullable FK → LEFT JOIN → PostgreSQL's nullable-side rule. "self" alone still works there,
  # which is the remedy the message names.
  left = () -> SFU.Result.objects.
    filter("constructorid__name" => "Ferrari").
    values("resultid")
  err = _sfu_err(() -> left().select_for_update(of = ("self", "constructorid")).list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  msg = _sfu_msg(err)
  @test occursin("\"constructorid\" is joined LEFT", msg)
  @test occursin("cannot lock the nullable side of an outer join", msg)
  # …and the "Choices" an unknown name lists does not offer the LEFT path it would then refuse.
  err = _sfu_err(() -> left().select_for_update(of = ("bogus",)).list(show_query = :sql))
  @test occursin("Choices: self.", _sfu_msg(err))
  sql = left().select_for_update(of = ("self",)).list(show_query = :sql)
  @test occursin("LEFT JOIN \"constructor\"", sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\""

  # An alias spelled like a relation path the query joins: two tables, one name.
  err = _sfu_err(() -> begin
    q = SFU.Result.objects
    q.cjoin_on("Driver", alias = "driverid", on = [Joined("driverid", "driverid") == F("driverid")])
    q.values("resultid")
    q.select_for_update(of = ("driverid",))
    q.list(show_query = :sql)
  end)
  @test err isa PormG.AmbiguousFieldError
  @test occursin("names a relation path on result and a cjoin_on alias", _sfu_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): the argument's shape is checked at the call
# `of` is one String or a tuple/vector of non-empty Strings. An empty collection would render a bare
# `FOR UPDATE OF` (a syntax error); a non-String has no meaning as a target. Both refused at the call,
# before any build.
# ─────────────────────────────────────────────────────────────────────────────
@testset "malformed of is refused at the call (#169)" begin
  err = _sfu_err(() -> SFU.Result.objects.select_for_update(of = ()))
  @test err isa PormG.QueryBuildError
  @test occursin("`of` is empty", _sfu_msg(err))

  err = _sfu_err(() -> SFU.Result.objects.select_for_update(of = ("self", "")))
  @test err isa PormG.QueryBuildError
  @test occursin("must be a non-empty String — got an empty string", _sfu_msg(err))

  err = _sfu_err(() -> SFU.Result.objects.select_for_update(of = ("self", 1)))
  @test err isa PormG.QueryBuildError
  @test occursin("must be a non-empty String — got a $(Int)", _sfu_msg(err))

  err = _sfu_err(() -> SFU.Result.objects.select_for_update(of = :self))
  @test err isa PormG.QueryBuildError
  @test occursin("must be a String or a tuple/vector of Strings — got a Symbol", _sfu_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): OF sits between the lock strength and the wait policy
# PostgreSQL's grammar is `FOR <strength> [OF …] [NOWAIT | SKIP LOCKED]`, so `OF` must render after
# `NO KEY UPDATE` and before `NOWAIT`/`SKIP LOCKED`; any other order is a syntax error. Without
# `of` the clause is unchanged from #26.
# ─────────────────────────────────────────────────────────────────────────────
@testset "OF renders between lock strength and wait policy (#169)" begin
  base = () -> SFU.Result.objects.values("resultid")
  @test _sfu_lock(base().select_for_update(of = "self", nowait = true).list(show_query = :sql)) ==
        "FOR UPDATE OF \"Tb\" NOWAIT"
  @test _sfu_lock(base().select_for_update(of = "self", skip_locked = true, no_key = true).list(show_query = :sql)) ==
        "FOR NO KEY UPDATE OF \"Tb\" SKIP LOCKED"
  @test _sfu_lock(base().select_for_update().list(show_query = :sql)) == "FOR UPDATE"
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): SQLite renders no lock, but still resolves the targets
# SQLite has no row locks, so the clause stays "" (#26). The targets are resolved anyway: a name that
# cannot be locked is a bug in the call, and the development engine is where it should surface
# rather than in production on PostgreSQL.
# ─────────────────────────────────────────────────────────────────────────────
@testset "SQLite: of renders nothing but is still validated (#169)" begin
  sql = SFU.Result.objects.
    filter("driverid__nationality" => "Brazilian").
    values("resultid").
    select_for_update(of = ("self", "driverid")).
    db("sfu_of_sl").
    list(show_query = :sql)
  @test !occursin("FOR UPDATE", sql)
  @test !occursin(" OF ", sql)

  err = _sfu_err(() -> SFU.Result.objects.values("resultid").
    select_for_update(of = ("bogus",)).db("sfu_of_sl").list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  @test occursin("\"bogus\" is not a relation path or cjoin_on alias", _sfu_msg(err))

  err = _sfu_err(() -> SFU.Result.objects.filter("constructorid__name" => "Ferrari").values("resultid").
    select_for_update(of = ("constructorid",)).db("sfu_of_sl").list(show_query = :sql))
  @test err isa PormG.QueryBuildError
  @test occursin("is joined LEFT", _sfu_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): a RIGHT or FULL join refuses `of` for the whole statement
# A RIGHT/FULL join puts the tables joined BEFORE it — the base table included — on the nullable
# side, so even `of = ("self",)` would fail on PostgreSQL although no target's own row is LEFT. The
# refusal is statement-wide on both engines; a plain lock (no `of`) is left to PostgreSQL as before.
# ─────────────────────────────────────────────────────────────────────────────
@testset "a RIGHT or FULL join refuses of (#169)" begin
  # An explicit `on(...)` join type, FULL and RIGHT, and a RIGHT `cjoin_on`.
  shapes = [
    "RIGHT via on()" => () -> begin
      q = SFU.Result.objects
      q.on("driverid", join_type = "RIGHT")
      q.values("resultid", "driverid__nationality")
      q
    end,
    "FULL via on()" => () -> begin
      q = SFU.Result.objects
      q.on("raceid", join_type = "FULL")
      q.values("resultid", "raceid__year")
      q
    end,
    "RIGHT cjoin_on" => () -> begin
      q = SFU.Result.objects
      q.cjoin_on("Circuit", alias = "c", join_type = "RIGHT", on = [Joined("c", "circuitid") == F("raceid__circuitid")])
      q.values("resultid")
      q
    end,
  ]
  for (label, shape) in shapes
    # A `cjoin_on` target model is bound to its connection and cannot be re-routed with `.db(...)`
    # (cross-connection joins are refused), so that shape is checked on the PostgreSQL mock only.
    for key in (label == "RIGHT cjoin_on" ? ("sfu_of_pg",) : ("sfu_of_pg", "sfu_of_sl"))
      err = _sfu_err(() -> shape().select_for_update(of = ("self",)).db(key).list(show_query = :sql))
      @test err isa PormG.QueryBuildError
      @test occursin("cannot be used on a query with a", _sfu_msg(err))
    end
    # Without `of` nothing new is refused: PormG renders the plain lock as #26 always did.
    @test _sfu_lock(shape().select_for_update().list(show_query = :sql)) == "FOR UPDATE"
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): every way a join is materialized is recorded under its path
# A relation joined only by `order_by`, only by an `on()` with no traversal, or by an INNER override
# of a nullable foreign key is as lockable as one a filter joins — and a LEFT `cjoin_on` alias is
# refused like a LEFT path, since PostgreSQL's rule is about the join, not about how it was named.
# ─────────────────────────────────────────────────────────────────────────────
@testset "order_by, on() and join_type overrides resolve like filters (#169)" begin
  # Joined by ORDER BY alone.
  sql = SFU.Result.objects.values("resultid").order_by("driverid__nationality").
    select_for_update(of = ("driverid",)).list(show_query = :sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(_sfu_alias(sql, "driver"))\""

  # Joined by an `on()` path that nothing else traverses.
  q = SFU.Result.objects
  q.on("driverid", "nationality" => "Dutch")
  q.values("resultid")
  q.select_for_update(of = ("self", "driverid"))
  sql = q.list(show_query = :sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"Tb\", \"$(_sfu_alias(sql, "driver"))\""

  # A nullable FK forced INNER is no longer the nullable side, so it may be locked.
  q = SFU.Result.objects
  q.on("constructorid", join_type = "INNER")
  q.filter("constructorid__name" => "Ferrari")
  q.values("resultid")
  q.select_for_update(of = ("constructorid",))
  sql = q.list(show_query = :sql)
  @test occursin("INNER JOIN \"constructor\"", sql)
  @test _sfu_lock(sql) == "FOR UPDATE OF \"$(_sfu_alias(sql, "constructor"))\""

  # A LEFT cjoin_on alias is the nullable side too.
  err = _sfu_err(() -> begin
    q = SFU.Result.objects
    q.cjoin_on("Circuit", alias = "c", join_type = "LEFT", on = [Joined("c", "circuitid") == F("raceid__circuitid")])
    q.values("resultid")
    q.select_for_update(of = ("c",))
    q.list(show_query = :sql)
  end)
  @test err isa PormG.QueryBuildError
  @test occursin("\"c\" is joined LEFT", _sfu_msg(err))
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): a locked subquery resolves against its OWN aliases
# "self" is the alias of the query that carries the lock, which inside a subquery is `R<n>`, not
# `Tb`. Each build keeps its own path→alias map, so the inner lock names inner joins only. A locked
# subquery also needs a transaction; on this file's mock pool one is reported open (the method is
# defined for the mock type alone).
# ─────────────────────────────────────────────────────────────────────────────
PormG.Configuration.transaction_connection_for(::SfuOfMockPostgres) = :sfu_of_mock_tx
@testset "a locked subquery resolves self and paths to its own aliases (#169)" begin
  inner = SFU.Result.objects.
    filter("driverid__nationality" => "Dutch").
    values("raceid").
    select_for_update(of = ("self", "driverid"))
  sql = SFU.Race.objects.filter("raceid__@in" => inner).values("raceid").list(show_query = :sql)
  m = match(r"FROM \"result\" as \"([^\"]+)\"", sql)
  @test m !== nothing
  inner_base = m.captures[1]
  @test inner_base != "Tb"
  @test occursin("FOR UPDATE OF \"$(inner_base)\", \"$(_sfu_alias(sql, "driver"))\"", sql)
end

# ─────────────────────────────────────────────────────────────────────────────
# select_for_update(of): the path→alias map is built only for a lock that names targets
# Every build is allocation-sensitive (#41), and only an `of` lock reads the map, so a build without
# one must leave it `nothing` — including a joined build with a plain lock.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the alias map is allocated only when of is given (#169)" begin
  map_of(q) = begin
    seen = Ref{Any}(:unset)
    PormG.QueryBuilder.query(q; show_query = :sql, built = i -> (seen[] = i.join_alias_by_path))
    seen[]
  end
  joined = () -> SFU.Result.objects.filter("driverid__nationality" => "Dutch").values("resultid")
  @test map_of(joined()) === nothing
  @test map_of(joined().select_for_update()) === nothing
  @test map_of(joined().select_for_update(of = "self")) == Dict("driverid" => _sfu_alias(joined().list(show_query = :sql), "driver"))
end
