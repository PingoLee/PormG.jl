# ==============================================================================
# NETWORK ADDRESS FIELDS — Live-Database Integration Test (#28)
#
# `GenericIPAddressField` is PostgreSQL `inet` and `CIDRField` is `cidr`. Both are PostgreSQL only:
# SQLite has no column for either, and PormG refuses one there rather than emulate it — on SQLite this
# file asserts exactly that refusal and nothing else.
#
# PormG writes every value as THE TEXT POSTGRESQL PRINTS for it, which is what lets a declared
# `default=` match the one the catalog stores. The unit layer pins the normalizer against a golden
# corpus (`test/unit/test_network_address_fields.jl`); only the server can say the corpus is RIGHT.
# Here each input is written through PostgreSQL's own `inet`/`cidr` input function and must read back
# as exactly what `format_inet_sql` / `format_cidr_sql` produced.
#
# Self-contained: the table is created by the planner from a model, scoped with `include_table`, and
# dropped in a `finally`, so the shared fixture never sees it and the file slices on a database that
# was bootstrapped before this table existed.
#
#   julia -t auto --project=test/integration test/integration/test_network_address_fields.jl
#   PORMG_DB=db_sl julia -t 1 --project=test/integration test/integration/test_network_address_fields.jl
# ==============================================================================

if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

import Sockets
import PormG.Migrations: LiveTable, read_live_schema, get_migration_plan, _order_statements,
                         _execute_statements_pg, _execute_statements_sqlite
import PormG.ConnectionPool: with_sqlite_write_lock, acquire_connection, finalize_transaction_connection!
const _na28_tx = PormG.ConnectionPool.with_transaction

const NA28_TABLE = "pormg_na28_session"

# The corpus the unit file pins, repeated here on purpose rather than shared through an `include`:
# a slice run must not depend on the unit file being reachable, and the two lists are short.
const NA28_INET = [
    "10.0.0.1", " 192.168.1.255 ", "0.0.0.0", "::1", "::", "2001:DB8::1",
    "2001:0db8:0000:0000:0000:0000:0000:0001", "::ffff:10.0.0.1", "0:0:0:0:0:ffff:a00:1",
    "::a00:1", "::1:0", "fe80:0:0:0:1:0:0:0", "1:0:0:2:0:0:0:3", "1:2:3:4:5:6:7::",
    "::2:3:4:5:6:7:8", "1::",
]
const NA28_CIDR = [
    "10.0.0.0/8", "10.0.0.1", "192.168.100.128/25", "0.0.0.0/0", "2001:DB8::/32",
    "::ffff:1.2.3.0/120", "::/0", "::1",
]

_na28_settings() = (s = PormG.Configuration.Settings(); s.change_db = true; s)

_na28_model() = Models.Model(NA28_TABLE;
    id         = Models.IDField(),
    label      = Models.CharField(max_length = 60, unique = true),
    client_ip  = Models.GenericIPAddressField(null = true),
    relay_ip   = Models.GenericIPAddressField(protocol = "IPv4", null = true),
    mapped_ip  = Models.GenericIPAddressField(unpack_ipv4 = true, null = true),
    garage_lan = Models.CIDRField(null = true),
    pit_ip     = Models.GenericIPAddressField(null = true, unique = true))

# Apply a plan the way `migrate` does, minus the history row — the shape `test_migration_rename_table.jl`
# uses for a scratch table.
function _na28_apply!(pool, plan)
    ordered, _ = _order_statements([plan[k] for k in keys(plan)])
    if pool isa PormG.PormGPostgres
        _, conn = _na28_tx(pool, "BEGIN;")
        try
            _execute_statements_pg(pool, ordered; conn = conn)
            _na28_tx(pool, "COMMIT;", conn = conn, release_conn = false)
        catch
            _na28_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
            rethrow()
        finally
            finalize_transaction_connection!(pool, conn)
        end
    else
        with_sqlite_write_lock(pool) do
            conn = acquire_connection(pool; mode = :write)
            try
                _na28_tx(pool, "BEGIN IMMEDIATE TRANSACTION;", conn = conn)
                try
                    _execute_statements_sqlite(pool, ordered; conn = conn)
                    _na28_tx(pool, "COMMIT;", conn = conn, release_conn = false)
                catch
                    _na28_tx(pool, "ROLLBACK;", conn = conn, release_conn = false)
                    rethrow()
                end
            finally
                finalize_transaction_connection!(pool, conn)
            end
        end
    end
    return nothing
end

_na28_err(f) = try f(); nothing catch e; e end

@testset "Network address fields, live ($(PORMG_DB_FOLDER)) (#28)" begin
    pool = PormG.config[PORMG_DB_FOLDER].connections
    is_pg = pool isa PormG.PormGPostgres
    drop() = try; PormG.ConnectionPool.fetch(pool, Dialect.drop_table(pool, NA28_TABLE)); catch; end

    model = _na28_model()
    model.connect_key = PORMG_DB_FOLDER
    schema = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
        Symbol(NA28_TABLE) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => model, :exist => false))
    live() = read_live_schema(pool; include_table = [NA28_TABLE])

    # ─────────────────────────────────────────────────────────────────────
    # SQLite: the column is refused, and nothing is created
    # The planner renders DDL at `makemigrations`, so the refusal arrives before a plan exists — not
    # part-way through a migration. The other fields of the model are not created either: the table
    # is one statement.
    # ─────────────────────────────────────────────────────────────────────
    if !is_pg
        @testset "SQLite refuses the column" begin
            drop()
            err = _na28_err(() -> get_migration_plan(LiveTable[], schema, pool, _na28_settings(); interactive = false))
            @test err isa PormG.BackendCapabilityError
            @test err !== nothing && occursin("PostgreSQL", sprint(showerror, err))
            @test isempty(live())
        end
    else
        drop()
        try
            _na28_apply!(pool, get_migration_plan(LiveTable[], schema, pool, _na28_settings(); interactive = false))
            # A fresh handler per query: a handler accumulates its filters, so one cached `objects` would
            # AND every later filter onto the first.
            S() = model.objects

            # ─────────────────────────────────────────────────────────────────────
            # The native column types, and a schema that converges with its own declaration
            # The catalog says `inet`/`cidr`; the reader maps them back to the same kinds, so the next
            # makemigrations proposes nothing.
            # ─────────────────────────────────────────────────────────────────────
            @testset "DDL and convergence" begin
                spec = only(live()).columns
                @test spec["client_ip"].raw == "inet" && spec["garage_lan"].raw == "cidr"
                @test spec["client_ip"].type == PormG.CInet() && spec["garage_lan"].type == PormG.CCidr()
                @test isempty(get_migration_plan(live(), schema, pool, _na28_settings(); interactive = false))
            end

            # ─────────────────────────────────────────────────────────────────────
            # The golden corpus, written and read back
            # The proof the normalizer prints what the server prints: the value is
            # parsed by `inet_in`/`cidr_in` and re-printed by `inet_out`/`cidr_out`, and must come back as
            # the text PormG computed. If it does not, the renderer is wrong — not the expectation.
            # ─────────────────────────────────────────────────────────────────────
            @testset "corpus round trip" begin
                for (i, input) in enumerate(NA28_INET)
                    S().create("label" => "inet-$i", "client_ip" => input)
                    row = S().filter("label" => "inet-$i").values("client_ip").list()[1]
                    @test (input, row["client_ip"]) == (input, Models.format_inet_sql(input))
                end
                for (i, input) in enumerate(NA28_CIDR)
                    S().create("label" => "cidr-$i", "garage_lan" => input)
                    row = S().filter("label" => "cidr-$i").values("garage_lan").list()[1]
                    @test (input, row["garage_lan"]) == (input, Models.format_cidr_sql(input))
                end
                # The server's own text, asked directly: nothing between PormG and the column rewrote it on
                # the way back.
                txt = PormG.ConnectionPool.fetch(pool,
                    "SELECT client_ip::text AS t, host(client_ip) AS h FROM \"$NA28_TABLE\" WHERE label = 'inet-1'") |> DataFrame
                @test txt.t[1] == "10.0.0.1/32" && txt.h[1] == "10.0.0.1"
            end

            # ─────────────────────────────────────────────────────────────────────
            # Every writer, and the options
            # update, bulk_insert, bulk_update and bulk_copy all normalize; `unpack_ipv4`
            # stores the mapped form as IPv4; `protocol = "IPv4"` refuses IPv6 before the database sees it.
            # ─────────────────────────────────────────────────────────────────────
            @testset "writers and options" begin
                S().create("label" => "opts", "relay_ip" => Sockets.IPv4("10.9.8.7"),
                         "mapped_ip" => "::FFFF:10.0.0.42")
                row = S().filter("label" => "opts").values("relay_ip", "mapped_ip").list()[1]
                @test row["relay_ip"] == "10.9.8.7" && row["mapped_ip"] == "10.0.0.42"

                S().filter("label" => "opts").update("client_ip" => "2001:0DB8:0:0:0:0:0:00AA")
                @test S().filter("label" => "opts").values("client_ip").list()[1]["client_ip"] == "2001:db8::aa"

                @test _na28_err(() -> S().create("label" => "bad-proto", "relay_ip" => "2001:db8::1")) isa PormG.InvalidValueError
                @test _na28_err(() -> S().create("label" => "bad-cidr", "garage_lan" => "10.0.0.1/24")) isa PormG.InvalidValueError
                @test !S().filter("label__@in" => ["bad-proto", "bad-cidr"]).exists()

                df = DataFrame(label = ["bulk-1", "bulk-2"], client_ip = ["10.30.0.1", "::FFFF:10.30.0.2"],
                               garage_lan = ["10.30.0.0/16", "10.31.0.0/16"])
                bulk_insert(model, df)
                got = S().filter("label__@in" => ["bulk-1", "bulk-2"]).order_by("label").
                    values("client_ip", "garage_lan").list()
                @test [r["client_ip"] for r in got] == ["10.30.0.1", "::ffff:10.30.0.2"]

                ids = S().filter("label__@in" => ["bulk-1", "bulk-2"]).order_by("label").values("id").list()
                upd = DataFrame(id = [r["id"] for r in ids], client_ip = ["10.40.0.1", "2001:DB8::40"])
                bulk_update(model, upd; columns = ["client_ip"])
                got = S().filter("label__@in" => ["bulk-1", "bulk-2"]).order_by("label").values("client_ip").list()
                @test [r["client_ip"] for r in got] == ["10.40.0.1", "2001:db8::40"]

                bulk_copy(model, DataFrame(label = ["copy-1"], client_ip = ["2001:0DB8::0050"],
                                           garage_lan = ["2001:DB8:50::/48"]))
                row = S().filter("label" => "copy-1").values("client_ip", "garage_lan").list()[1]
                @test row["client_ip"] == "2001:db8::50" && row["garage_lan"] == "2001:db8:50::/48"

                # A `Sockets` value works as a lookup too, so `get_or_create` finds the row it would
                # otherwise duplicate.
                obj, created = S().get_or_create("label" => "opts", "relay_ip" => Sockets.IPv4("10.9.8.7"))
                @test !created
            end

            # ─────────────────────────────────────────────────────────────────────
            # Lookups: equality by any spelling, UNIQUE across spellings, pattern lookups, ordering
            # ─────────────────────────────────────────────────────────────────────
            @testset "lookups" begin
                # A non-canonical spelling finds the row — by equality and by membership.
                @test S().filter("client_ip" => "2001:0db8:0000::0001").values("label").list()[1]["label"] == "inet-6"
                @test S().filter("client_ip__@in" => ["0:0:0:0:0:FFFF:A00:1"]).count() == 2   # inet-8, inet-9
                @test S().filter("garage_lan" => "10.0.0.1/32").count() == 1

                # UNIQUE sees two spellings of one address as one value.
                S().create("label" => "pit-1", "pit_ip" => "2001:db8::7")
                @test _na28_err(() -> S().create("label" => "pit-2", "pit_ip" => "2001:0DB8:0::0007")) !== nothing
                @test !S().filter("label" => "pit-2").exists()

                # Pattern lookups read the printed text (`HOST(col)`, the cidr text).
                @test S().filter("client_ip__@startswith" => "10.40.").values("label").list()[1]["label"] == "bulk-1"
                @test S().filter("client_ip__@contains" => "ffff:10.").count() == 2
                @test sort([r["label"] for r in S().filter("garage_lan__@endswith" => "/16").values("label").list()]) ==
                      ["bulk-1", "bulk-2"]

                # #903: a pattern lookup on an alias over the column reads the same text — the server
                # has no LIKE for `MAX(inet)`, so this is `HOST(MAX(…))` and must run, not just render.
                q_alias = S()
                q_alias.values("label", "top_ip" => PormG.Functions.Max("client_ip"))
                q_alias.filter("top_ip__@startswith" => "10.40.")
                @test [r["label"] for r in q_alias.list()] == ["bulk-1"]

                # #903: a `Sockets` literal binds as PostgreSQL's text for it, typed inet — the server
                # reads it back as it prints it (`::ffff:10.0.0.1`, not `Sockets`' `::ffff:a00:1`).
                q_lit = S().filter("label" => "opts")
                q_lit.values("label", "probe" => PormG.Functions.Value(parse(Sockets.IPAddr, "::FFFF:10.0.0.1")))
                @test string(q_lit.list()[1]["probe"]) == "::ffff:10.0.0.1"

                # Ordering is by network: 10.9.8.7 < 10.9.8.10, though not as text.
                @test S().filter("relay_ip__@gt" => "10.9.8.10").count() == 0
                @test S().filter("relay_ip__@lt" => "10.9.8.10").count() == 1
            end
        finally
            drop()
        end
    end
end
