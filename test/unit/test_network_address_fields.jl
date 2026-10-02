"""
Unit tests for the network-address fields (#28): `GenericIPAddressField` (PostgreSQL `inet`) and
`CIDRField` (PostgreSQL `cidr`). PostgreSQL only: SQLite has no column for either, and rendering one
there raises `BackendCapabilityError` — PormG refuses a specialized type on SQLite rather than
emulate it (`general.instructions.md` → *Keep PostgreSQL and SQLite aligned*).

This file covers:
- Construction: defaults, `protocol`, `unpack_ipv4`, `default=` normalization and refusal
- The normalizer: the golden corpus (accepted spellings → PostgreSQL's printed text) and refusals
- Write validation through `validate_field_data` (every writer's path), including `protocol`
- DDL on PostgreSQL and the SQLite refusal, the canonical column IR, inspectdb and catalog defaults
- `Model_to_str` round trip
- Filter SQL: equality and membership (also with a `Sockets` value), pattern lookups over the printed text
- Migration retypes: the `USING` clauses, the lossy-ALTER findings and their row counts

Hermetic: mock connections only. The live half — that PostgreSQL itself prints what the normalizer
produced — is `test/integration/test_network_address_fields.jl`.
"""
# julia --project=test/integration test/unit/test_network_address_fields.jl

using Test
using Logging
using Sockets
using PormG
using PormG.Models
using PormG.QueryBuilder: validate_field_data
import PormG: Migrations, Dialect, CInet, CCidr, CText, CVarChar, CUnsupported
import PormG.Migrations: column_spec, column_delta, parse_canonical_type, _lossy_alters,
                         ColumnSpec, NoDefault

const NA = PormG.Models

struct _MockPgNet28 <: PormG.PormGPostgres end
struct _MockSlNet28 <: PormG.PormGSQLite end
const PG_NET28 = _MockPgNet28()
const SL_NET28 = _MockSlNet28()
# The constraint-name lookups `alter_field` asks a PostgreSQL catalog for.
PormG.get_constraints_pk(::_MockPgNet28, t::String, f::String) = nothing
PormG.get_constraints_unique(::_MockPgNet28, t::String, f::String) = nothing
PormG.get_constraints_checks(::_MockPgNet28, t::String, f::String) = String[]
PormG.get_constraints_byte_length_checks(::_MockPgNet28, t::String, f::String) = String[]

PormG.config["net28_pg"] = PormG.Configuration.Settings(connections = PG_NET28, change_data = true)

if !isdefined(Main, :_Net28Session)
  _Net28Session = NA.Model("pit_wall_session",
    id         = NA.IDField(),
    team       = NA.CharField(max_length = 100),
    client_ip  = NA.GenericIPAddressField(),
    relay_ip   = NA.GenericIPAddressField(protocol = "IPv4", null = true),
    mapped_ip  = NA.GenericIPAddressField(unpack_ipv4 = true, null = true),
    garage_lan = NA.CIDRField(null = true),
  )
  _Net28Session.connect_key = "net28_pg"
end
const _NS = _Net28Session

# Error messages carry ANSI colour on a TTY (and on CI); strip it before matching text.
_plain28(msg::AbstractString) = replace(msg, r"\e\[[0-9;]*m" => "")

# ─────────────────────────────────────────────────────────────────────────────
# The golden corpus: accepted spellings → the text PostgreSQL prints
# Shared with the integration file, which writes each input through PostgreSQL and asserts the row
# reads back as exactly this text. Here it pins the normalizer; there it proves the normalizer agrees
# with the server — which is what makes a declared `default=` match the one the catalog stores.
# ─────────────────────────────────────────────────────────────────────────────
const NET28_INET_CORPUS = [
  "10.0.0.1"                => "10.0.0.1",
  " 192.168.1.255 "         => "192.168.1.255",
  "0.0.0.0"                 => "0.0.0.0",
  "::1"                     => "::1",
  "::"                      => "::",
  "2001:DB8::1"             => "2001:db8::1",
  "2001:0db8:0000:0000:0000:0000:0000:0001" => "2001:db8::1",
  "::ffff:10.0.0.1"         => "::ffff:10.0.0.1",
  "0:0:0:0:0:ffff:a00:1"    => "::ffff:10.0.0.1",   # mapped: printed with its IPv4 tail
  "::a00:1"                 => "::10.0.0.1",        # compatible: likewise
  "::1:0"                   => "::0.1.0.0",         # a six-word zero run prints dotted, oddly
  "fe80:0:0:0:1:0:0:0"      => "fe80::1:0:0:0",     # tie: the FIRST longest run compresses
  "1:0:0:2:0:0:0:3"         => "1:0:0:2::3",        # the LONGER run wins over the first
  "1:2:3:4:5:6:7::"         => "1:2:3:4:5:6:7:0",   # a one-word run is never `::`
  "::2:3:4:5:6:7:8"         => "0:2:3:4:5:6:7:8",
  "1::"                     => "1::",
]
const NET28_CIDR_CORPUS = [
  "10.0.0.0/8"              => "10.0.0.0/8",
  "10.0.0.1"                => "10.0.0.1/32",       # no prefix: the full-width network
  "192.168.100.128/25"      => "192.168.100.128/25",
  "0.0.0.0/0"               => "0.0.0.0/0",
  "2001:DB8::/32"           => "2001:db8::/32",
  "::ffff:1.2.3.0/120"      => "::ffff:1.2.3.0/120",
  "::/0"                    => "::/0",
  "::1"                     => "::1/128",
]

@testset "Network address fields (#28)" begin

  # ─────────────────────────────────────────────────────────────────────────────
  # Normalizer: every accepted spelling becomes PostgreSQL's printed text
  # The renderer is a port of PostgreSQL's `inet_net_ntop_ipv6`; the corpus covers each of its
  # branches (no run, a single-word run, a tie, a longer later run, both IPv4 embeddings).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the corpus normalizes to PostgreSQL's text" begin
    for (input, printed) in NET28_INET_CORPUS
      @test (input, NA.format_inet_sql(input)) == (input, printed)
    end
    for (input, printed) in NET28_CIDR_CORPUS
      @test (input, NA.format_cidr_sql(input)) == (input, printed)
    end
    # A `Sockets` address is accepted on write, as itself.
    @test NA.format_inet_sql(ip"10.1.2.3") == "10.1.2.3"
    @test NA.format_inet_sql(ip"::FFFF:10.0.0.1") == "::ffff:10.0.0.1"
    @test NA.format_cidr_sql(ip"10.1.2.3") == "10.1.2.3/32"
    @test NA.format_inet_sql(SubString("x10.0.0.1", 2)) == "10.0.0.1"
    # NULL stays NULL.
    @test ismissing(NA.format_inet_sql(nothing)) && ismissing(NA.format_cidr_sql(missing))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Normalizer: refusals
  # Stricter than PostgreSQL on purpose — classful short forms and leading zeros are ambiguous
  # spellings the server reads one way and `inet_aton` another. Every refusal is `InvalidValueError`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "malformed and ambiguous spellings are refused" begin
    for bad in ("10.1", "010.0.0.1", "10.0.0.256", "10.0.0", "10.0.0.1.2", "", "   ",
                ":::1", "1:2:3:4:5:6:7:8::", "1::2::3", "12345::1", "fe80::1%eth0", "[::1]",
                "1:2:3:4:5:6:7", "::1.2.3", "1.2.3.4::", "10.0.0.1/", "10.0.0.1/a",
                "10.0.0.1/08", "10.0.0.1/24/8", "g::1")
      @test_throws PormG.InvalidValueError NA.format_inet_sql(bad)
    end
    # A prefix makes it a network, which this field does not hold — and the message says where to go.
    e = try NA.format_inet_sql("10.0.0.0/8"); nothing catch err; err end
    @test e isa PormG.InvalidValueError && occursin("CIDRField", e.msg)
    # A CIDR network with host bits set is refused as PostgreSQL refuses it, naming the network.
    e = try NA.format_cidr_sql("10.0.0.1/24"); nothing catch err; err end
    @test e isa PormG.InvalidValueError && occursin("10.0.0.0/24", e.msg)
    @test_throws PormG.InvalidValueError NA.format_cidr_sql("2001:db8::1/32")
    @test_throws PormG.InvalidValueError NA.format_cidr_sql("10.0.0.0/33")
    @test_throws PormG.InvalidValueError NA.format_cidr_sql("::/129")
    # Wrong types are refused, not stringified.
    @test_throws PormG.InvalidValueError NA.format_inet_sql(167772161)
    @test_throws PormG.InvalidValueError NA.format_cidr_sql(Sockets.InetAddr(ip"10.0.0.1", 80))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # unpack_ipv4: only the IPv4-MAPPED form unpacks
  # Django's rule: `::ffff:a.b.c.d` is an IPv4 address in IPv6 clothing; the deprecated compatible
  # form `::a.b.c.d` is left alone.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "unpack_ipv4 unpacks the mapped form only" begin
    @test NA.format_inet_unpacked_sql("::ffff:10.0.0.1") == "10.0.0.1"
    @test NA.format_inet_unpacked_sql("0:0:0:0:0:FFFF:a00:1") == "10.0.0.1"
    @test NA.format_inet_unpacked_sql("::10.0.0.1") == "::10.0.0.1"
    @test NA.format_inet_unpacked_sql("2001:db8::1") == "2001:db8::1"
    @test NA.format_inet_unpacked_sql("10.0.0.1") == "10.0.0.1"
    @test_throws PormG.InvalidValueError NA.format_inet_unpacked_sql("::ffff:10.0.0.0/120")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Construction
  # The slots `Model_to_str` and the kwargs snapshot read, `protocol` lower-cased, Django's
  # `unpack_ipv4` rule, and a `default=` stored in the text a written value is stored in.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "construction" begin
    f = NA.GenericIPAddressField()
    @test f.type == "INET" && f.protocol == "both" && !f.unpack_ipv4
    @test f.formatter === NA.format_inet_sql && f.editable && !f.primary_key && f.default === nothing
    @test NA.GenericIPAddressField(unpack_ipv4 = true).formatter === NA.format_inet_unpacked_sql
    @test NA.GenericIPAddressField(protocol = "IPv6").protocol == "ipv6"
    @test NA.GenericIPAddressField(protocol = SubString(" IPv4 ", 1)).protocol == "ipv4"

    c = NA.CIDRField()
    @test c.type == "CIDR" && c.formatter === NA.format_cidr_sql && c.editable && c.default === nothing

    # Defaults are normalized like a written value.
    @test NA.GenericIPAddressField(default = "2001:DB8::0001").default == "2001:db8::1"
    @test NA.GenericIPAddressField(default = ip"10.0.0.7").default == "10.0.0.7"
    @test NA.GenericIPAddressField(unpack_ipv4 = true, default = "::ffff:10.0.0.1").default == "10.0.0.1"
    @test NA.CIDRField(default = "10.0.0.1").default == "10.0.0.1/32"

    # Every refusal is a FieldValidationError — the constructor surface reports one category.
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(protocol = "ipv5")
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(protocol = 4)
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(protocol = "ipv4", unpack_ipv4 = true)
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(unpack_ipv4 = "yes")
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(default = "10.1")
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(default = "10.0.0.0/8")
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(default = 42)
    @test_throws PormG.FieldValidationError NA.GenericIPAddressField(protocol = "ipv6", default = "10.0.0.1")
    @test_throws PormG.FieldValidationError NA.CIDRField(default = "10.0.0.1/24")
    # Django's own wording for the unpack rule.
    e = try NA.GenericIPAddressField(protocol = "ipv6", unpack_ipv4 = true); nothing catch err; err end
    @test occursin("only use `unpack_ipv4` if `protocol` is set to \"both\"", _plain28(e.msg))

    # `primary_key` is not accepted: warned about and ignored, as for JSONField.
    pk = @test_logs (:warn, r"Unexpected parameter") match_mode = :any NA.GenericIPAddressField(primary_key = true)
    @test pk.primary_key == false
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Write validation (every writer goes through `_validate_field_value`)
  # `protocol` is checked here, after the formatter normalized the value — so `::ffff:10.0.0.1` is an
  # IPv6 value to a `protocol = "ipv4"` field, exactly as Django treats it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "write validation" begin
    @test validate_field_data(_NS, "client_ip", "2001:db8::1", "insert")
    @test validate_field_data(_NS, "client_ip", ip"10.0.0.1", "insert")
    @test validate_field_data(_NS, "relay_ip", "10.0.0.1", "insert")
    @test validate_field_data(_NS, "relay_ip", nothing, "insert")
    @test validate_field_data(_NS, "garage_lan", "10.20.0.0/16", "update")

    for (field, value) in (("relay_ip", "2001:db8::1"), ("relay_ip", "::ffff:10.0.0.1"),
                           ("client_ip", "10.0.0.0/8"), ("client_ip", "not-an-ip"),
                           ("client_ip", ""), ("client_ip", 42), ("client_ip", nothing),
                           ("garage_lan", "10.20.0.1/16"))
      @test_throws PormG.InvalidValueError validate_field_data(_NS, field, value, "insert")
    end
    e = try validate_field_data(_NS, "relay_ip", "2001:db8::1", "insert"); nothing catch err; err end
    @test occursin("IPv4 addresses only", e.msg)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # DDL and the column IR
  # PostgreSQL renders the native types. SQLite has no column for either: the DDL renderer refuses
  # them, and so does the planner for any model that declares one (next testset).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "DDL and canonical types" begin
    g, c = NA.GenericIPAddressField(), NA.CIDRField()
    @test Dialect._get_column_type(g, PG_NET28) == "inet"
    @test Dialect._get_column_type(c, PG_NET28) == "cidr"
    @test Dialect.field_to_column("client_ip", g, PG_NET28) == "\"client_ip\" inet NOT NULL"
    for f in (g, c, NA.GenericIPAddressField(null = true, protocol = "ipv4"))
      e = try Dialect.field_to_column("addr", f, SL_NET28); nothing catch err; err end
      @test e isa PormG.BackendCapabilityError
      @test occursin("PostgreSQL", _plain28(sprint(showerror, e)))
    end
    # An ordinary field beside them still renders on SQLite.
    @test occursin("TEXT", Dialect.field_to_column("team", NA.TextField(), SL_NET28))

    @test parse_canonical_type("inet", PG_NET28) == CInet()
    @test parse_canonical_type("cidr", PG_NET28) == CCidr()
    # PormG never writes `INET` on SQLite, so a foreign column declared that way is not PormG's.
    @test parse_canonical_type("INET", SL_NET28) isa CUnsupported

    @test column_spec(g, PG_NET28; name = "c").type == CInet()
    @test column_spec(c, PG_NET28; name = "c").type == CCidr()
    # `protocol`/`unpack_ipv4` are model-layer only: a change is no schema delta.
    a = NA.GenericIPAddressField()
    b = NA.GenericIPAddressField(protocol = "ipv4")
    @test isempty(column_delta(b, a, PG_NET28; name = "c"))
    @test isempty(column_delta(NA.GenericIPAddressField(unpack_ipv4 = true), a, PG_NET28; name = "c"))
    @test :type in column_delta(NA.TextField(), a, PG_NET28; name = "c")
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # The SQLite planner refuses a model that DECLARES a network field
  # Not only one whose column it renders: on SQLite the field's spec compiles to `CText` (for the
  # compiler alone), so re-declaring an existing `TEXT` column as a GenericIPAddressField is an empty
  # delta that renders no DDL — the hole `field_to_column` alone left open (found in review).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "the SQLite planner refuses a declared network field" begin
    settings = PormG.Configuration.Settings()
    schema_for(m) = Dict{Symbol, Dict{Symbol, Union{Bool, PormG.PormGModel}}}(
      Symbol(NA.model_table_name(m)) => Dict{Symbol, Union{Bool, PormG.PormGModel}}(:model => m, :exist => true))
    as_text = NA.Model("net28_relay", id = NA.IDField(), client_ip = NA.TextField())
    as_inet = NA.Model("net28_relay", id = NA.IDField(), client_ip = NA.GenericIPAddressField())
    # The premise of the hole: the two declarations really are the same column to the SQLite compiler.
    @test isempty(column_delta(NA.GenericIPAddressField(), NA.TextField(), SL_NET28; name = "client_ip"))
    live = [Migrations.live_table(as_text, SL_NET28)]
    e = try
      Migrations.get_migration_plan(live, schema_for(as_inet), SL_NET28, settings; interactive = false)
      nothing
    catch err
      err
    end
    @test e isa PormG.BackendCapabilityError
    @test e !== nothing && occursin("client_ip", _plain28(sprint(showerror, e)))
    # A new table is refused the same way (the empty-database path).
    @test_throws PormG.BackendCapabilityError Migrations.get_migration_plan(
      Migrations.LiveTable[], schema_for(as_inet), SL_NET28, settings; interactive = false)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # inspectdb and catalog defaults
  # An `inet`/`cidr` column used to be emitted as a warned `TextField`; it is its own field now. A
  # catalog default reads back through the field's formatter, so it compares equal to a declared one.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "inspectdb and catalog defaults" begin
    for (ctype, T) in ((CInet(), NA.sGenericIPAddressField), (CCidr(), NA.sCIDRField))
      spec = ColumnSpec("addr", ctype, true, false, false, NoDefault(), nothing,
                        Migrations.CheckKind[], nothing, ctype isa CInet ? "inet" : "cidr")
      tbl = Migrations.LiveTable("t", Migrations.OrderedDict("addr" => spec),
                                 Dict{String, Union{String, Nothing}}())
      # No "has no PormG field type" warning any more.
      f = @test_logs min_level = Logging.Warn Migrations.field_from_spec(spec, tbl, PG_NET28)
      @test f isa T && f.null
      # inspectdb round-trips: the declaration compiles back to the live spec.
      @test column_spec(f, PG_NET28; name = "addr").type == ctype
    end
    @test Migrations._coerce_default("2001:DB8::1", CInet()) == "2001:db8::1"
    @test Migrations._coerce_default("10.0.0.0/8", CCidr()) == "10.0.0.0/8"
    # A masked `inet` default is not a host address: refused (and so warned-and-dropped upstream).
    @test_throws PormG.InvalidValueError Migrations._coerce_default("10.0.0.0/8", CInet())
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Model_to_str round trip
  # The struct diff emits `protocol` and `unpack_ipv4` and never `formatter` — no constructor takes
  # one, and `unpack_ipv4 = true` makes it differ from the zero-argument instance's.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "Model_to_str round trip" begin
    src = Logging.with_logger(Logging.NullLogger()) do
      NA.Model_to_str(_NS)
    end
    @test !occursin("formatter", src)
    @test occursin("client_ip = Models.GenericIPAddressField()", src)
    @test occursin("relay_ip = Models.GenericIPAddressField(", src) && occursin("protocol=\"ipv4\"", src)
    @test occursin("unpack_ipv4=true", src)
    @test occursin("garage_lan = Models.CIDRField(null=true)", src)
    sandbox = Module()
    Core.eval(sandbox, :(import PormG; import PormG.Models))
    reloaded = Core.eval(sandbox, Meta.parse(src))
    @test reloaded.fields["relay_ip"].protocol == "ipv4"
    @test reloaded.fields["mapped_ip"].formatter === NA.format_inet_unpacked_sql
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Filters: equality and membership bind the NORMALIZED value
  # PostgreSQL compares `inet` natively, so any spelling would match; binding the printed form keeps
  # one text for a value everywhere PormG handles it, and a malformed value is refused before the
  # server sees it.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "equality and membership bind the normalized value" begin
    q = _NS.objects.filter("client_ip" => "2001:0DB8::0001")
    q.values("id")
    res = q.list(show_query = :dict)
    @test occursin("\"client_ip\" = \$1", res[:sql_text])
    @test res[:parameters] == ["2001:db8::1"]

    q_in = _NS.objects.filter("garage_lan__@in" => ["10.0.0.1", "10.20.0.0/16"])
    q_in.values("id")
    res_in = q_in.list(show_query = :dict)
    @test occursin("= ANY(\$1)", res_in[:sql_text])
    @test res_in[:parameters] == [["10.0.0.1/32", "10.20.0.0/16"]]

    # A `Sockets` value is accepted on write, so a filter takes one too — and `get_or_create` builds
    # its lookup through `filter`. It used to fall off the parse ladder as a raw `MethodError`.
    q_ip = _NS.objects.filter("client_ip" => ip"::FFFF:10.0.0.1")
    q_ip.values("id")
    @test q_ip.list(show_query = :dict)[:parameters] == ["::ffff:10.0.0.1"]
    q_ips = _NS.objects.filter("client_ip__@in" => [ip"10.0.0.1", ip"2001:db8::1"])
    q_ips.values("id")
    @test q_ips.list(show_query = :dict)[:parameters] == [["10.0.0.1", "2001:db8::1"]]

    # A malformed value is a filter error, not a silent no-match.
    @test_throws PormG.FilterError _NS.objects.filter("client_ip" => "10.1").list(show_query = :dict)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Filters: pattern lookups read the printed text, and bind the fragment raw
  # PostgreSQL has no LIKE for inet/cidr. `HOST(col)` is the printed text of an inet (a cast would
  # add `/32`), `CAST(col AS text)` that of a cidr. The value is a fragment the strict formatter would
  # refuse, so it binds as plain text.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "pattern lookups" begin
    q = _NS.objects.filter("client_ip__@startswith" => "10.20.")
    q.values("id")
    res = q.list(show_query = :dict)
    @test occursin("HOST(", res[:sql_text]) && occursin("LIKE", res[:sql_text])
    @test res[:parameters] == ["10.20.%"]

    q_c = _NS.objects.filter("garage_lan__@contains" => "/16")
    q_c.values("id")
    res_c = q_c.list(show_query = :dict)
    @test occursin("CAST(", res_c[:sql_text]) && occursin("AS text) LIKE", res_c[:sql_text])

    # Regex reads the same operand on PostgreSQL.
    q_r = _NS.objects.filter("client_ip__@regex" => "^10\\.")
    q_r.values("id")
    @test occursin("HOST(", q_r.list(show_query = :dict)[:sql_text])
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Filters: ordering compares the column natively
  # PostgreSQL orders `inet`/`cidr` by network, so `@gt`/`@range` need no rewrite — only the value is
  # normalized. (Only a pattern lookup wraps the column.)
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "ordering lookups compare natively" begin
    q = _NS.objects.filter("client_ip__@gt" => "10.0.0.9")
    q.values("id")
    res = q.list(show_query = :dict)
    @test occursin("\"client_ip\" > \$1", res[:sql_text]) && !occursin("HOST(", res[:sql_text])
    q_r = _NS.objects.filter("garage_lan__@range" => ["10.0.0.0/8", "10.255.0.0/16"])
    q_r.values("id")
    @test q_r.list(show_query = :dict)[:parameters] == ["10.0.0.0/8", "10.255.0.0/16"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Migration retypes on PostgreSQL
  # text → inet/cidr parses each value (`CAST`), recorded as a counted `:text_cast` finding. inet →
  # text uses `abbrev`, the printed text, so every row reads as it did before the change; a cidr
  # needs no USING (its text cast keeps the prefix, which is what it prints).
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "retypes" begin
    g, c, t = NA.GenericIPAddressField(), NA.CIDRField(), NA.TextField()
    retype(declared, live) = Dialect.alter_field(PG_NET28, "t", "c", declared,
                                                 column_delta(declared, live, PG_NET28; name = "c"))
    kinds(declared, live) = [f.kind for f in _lossy_alters(column_delta(declared, live, PG_NET28; name = "c"),
                                                           PG_NET28; table = "t", column = "c")]

    @test occursin("TYPE inet USING CAST(\"c\" AS inet)", retype(g, t))
    @test occursin("TYPE cidr USING CAST(\"c\" AS cidr)", retype(c, t))
    @test kinds(g, t) == [:text_cast] && kinds(c, t) == [:text_cast]

    @test occursin("USING abbrev(\"c\")", retype(t, g))
    @test occursin("TYPE VARCHAR(45) USING abbrev(\"c\")", retype(NA.CharField(max_length = 45), g))
    @test !occursin("USING", retype(t, c))
    @test isempty(kinds(t, g))
    # The `:varchar_length` count measures what the ALTER writes — `abbrev`, not the masked text cast,
    # which would refuse `192.168.100.1` for a `max_length = 15` it fits.
    narrow = NA.CharField(max_length = 15)
    @test kinds(narrow, g) == [:varchar_length]
    f = only(_lossy_alters(column_delta(narrow, g, PG_NET28; name = "c"), PG_NET28; table = "t", column = "c"))
    @test occursin("char_length(rtrim(abbrev(\"c\")))", first(Migrations._precheck_sql(PG_NET28, f)))
    # …and any other old type keeps the text cast.
    f_t = only(_lossy_alters(column_delta(narrow, NA.CharField(max_length = 40), PG_NET28; name = "c"),
                             PG_NET28; table = "t", column = "c"))
    @test occursin("CAST(\"c\" AS text)", first(Migrations._precheck_sql(PG_NET28, f_t)))

    # #905: inet → cidr goes through text, whose `cidr` parser refuses an address with bits right of
    # its mask — the assignment cast would zero them — and the rows that hold one are counted first.
    # The way back loses nothing and stays a plain ALTER.
    @test occursin("TYPE cidr USING CAST(CAST(\"c\" AS text) AS cidr)", retype(c, g))
    @test kinds(c, g) == [:host_bits]
    f_h = only(_lossy_alters(column_delta(c, g, PG_NET28; name = "c"), PG_NET28; table = "t", column = "c"))
    @test Migrations.lossy_alter_class(f_h) === :rows
    @test Migrations._precheck_sql(PG_NET28, f_h) ==
          ("SELECT COUNT(*) AS n FROM \"t\" WHERE \"c\" <> CAST(CAST(\"c\" AS cidr) AS inet)", Any[])
    # The plan header carries it, and reading the header back accepts the kind.
    header = Migrations._lossy_alter_header(f_h)
    @test Migrations._parse_lossy_alter_header(chopprefix(header, Migrations.LOSSY_ALTER_HEADER), "p.jl") == f_h
    @test !occursin("USING", retype(g, c)) && isempty(kinds(g, c))
    @test :drop_default in kinds(NA.CIDRField(null = true),
                                 NA.GenericIPAddressField(null = true, db_default = (postgres = "'10.0.0.1'::inet",)))

    # `alter_field` drops the old default before ANY `USING`, `abbrev` included — so a live expression
    # default the model does not declare is lost, and that is a finding needing the opt-in, exactly as
    # for the castless pairs (#828).
    live_with_default = NA.GenericIPAddressField(null = true, db_default = (postgres = "'10.0.0.1'::inet",))
    @test :drop_default in kinds(NA.TextField(null = true), live_with_default)
    @test occursin("DROP DEFAULT", retype(NA.TextField(null = true), live_with_default))

    # An unrelated CharField retype is unchanged by going through `retype!`.
    @test strip(retype(NA.CharField(max_length = 45), t)) ==
          "ALTER TABLE \"t\" ALTER COLUMN \"c\" TYPE VARCHAR(45);"
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Bulk writes
  # PostgreSQL's bulk writers bind one array per column inside `unnest`; an address array is a plain
  # `inet[]`.
  # ─────────────────────────────────────────────────────────────────────────────
  @testset "bulk cast" begin
    @test PormG.QueryBuilder._pg_bulk_cast_type(NA.GenericIPAddressField(), PG_NET28) == "inet"
    @test PormG.QueryBuilder._pg_bulk_cast_type(NA.CIDRField(), PG_NET28) == "cidr"
  end
end
