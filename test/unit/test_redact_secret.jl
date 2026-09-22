"""
The connection-string redaction rule (#649).

`Configuration.redact_secret` is the **single owner** of that rule. Every site that puts a
connection string into a log line, an exception, a REPL `show` or a JSON document routes through
it, so a new DSN dialect is taught here once rather than at ~20 call sites.

What this file pins, and all of it is behaviour that actually shipped broken:

1. **The URL dialect was not redacted at all.** The rule matched `password=` / `user=` only, so
   `postgres://pingo:s3cret@localhost/f1` passed through untouched — and `connection.yml`'s `url:`
   key is documented as "passed through verbatim", so that form is a supported configuration, not
   a hypothetical. It reached every `@warn`/`@debug` in the pool and the public `PoolConnectError`.
2. **Four separate value forms leaked, each found only by asking libpq.** A quoted value
   (`password='s3 cret'`) printed ` cret'`; a backslash-escaped space did the same; spaces around
   the `=` matched nothing; and a backslash-escaped NEWLINE slipped past `\\.`, which PCRE does not
   match without DOTALL. Every one of these is legal conninfo that `PQconninfoParse` accepts.
3. **Two characters excluded from the URL userinfo class on URI-grammar grounds were whole-DSN
   leaks** — first `?` and `#`, then whitespace. libpq is more permissive than the grammar, and
   each time the class was narrower than libpq's rule, the entire connection string went through
   unredacted. The lesson is in the source comment: **the rule is libpq's, not the RFC's.**
   The one character libpq's scan DOES stop at, `/`, turned out to be the third leak (#658): libpq
   reads no password from `u:pa/ss@h`, but it reads the password's tail as the dbname. So the rule is
   **every reading at once** — libpq's userinfo, and the userinfo the user meant.
4. **The rule was DUPLICATED** — byte-identical copies of the pattern and the function in
   `Configuration.jl` and `ConnectionPool.jl`. That is not untidiness: it is the mechanism by which
   a widened rule applies at one set of call sites and silently not at the other. The structural
   testset at the foot of this file is what keeps a third copy from appearing.

None of 2 or 3 was found by reading the pattern. They came from running candidate inputs through
the real `PQconninfoParse` and comparing what libpq calls the credential against what survives
redaction — which is the technique to reach for when this rule is next changed.

Every credential literal below is INVENTED. Nothing here reads configuration, and the expected
values are written out in full rather than computed from the function under test — a test that asks
the implementation what it does cannot notice the implementation changing.

Hermetic — no database, no fixture, no driver.

julia --project=test/integration test/unit/test_redact_secret.jl
"""

using Test
using PormG

const R649 = PormG.Configuration.redact_secret

# A single quote, built rather than written, so the quoted-DSN cases below stay readable inside a
# double-quoted Julia literal.
const SQ = "'"

# label => (input, exact expected output)
const REDACT_CASES = Pair{String, Tuple{String, String}}[
  # ── keyword/value DSN (libpq conninfo) ──────────────────────────────────────
  "dsn both keys"       => ("host=localhost port=5432 password=s3cret dbname=f1 user=pingo",
                            "host=localhost port=5432 password=**** dbname=f1 user=****"),
  # The exact string `test/integration/test_internals.jl` has asserted since before #649, pinned
  # here as an equality so those older, looser assertions are not the only thing holding it.
  "dsn user first"      => ("host=localhost user=admin password=s3cr3t port=5432",
                            "host=localhost user=**** password=**** port=5432"),
  "dsn uppercase key"   => ("PASSWORD=topsecret", "PASSWORD=****"),
  # A password containing `&`. This is the case that forbids tightening the value class to stop at
  # `&`: that spelling would emit `password=****&w` and leak the tail of a real password.
  "dsn & in password"   => ("password=p&w dbname=f1", "password=**** dbname=f1"),
  # Defect 2 — the quoted form. Before #649 this produced `password=**** cret'`.
  "dsn quoted value"    => ("host=localhost password=" * SQ * "s3 cret" * SQ * " dbname=f1",
                            "host=localhost password=**** dbname=f1"),
  # Defect 2's sibling, found in review: libpq honours a backslash escape OUTSIDE quotes too, so
  # `s3\ cret` is the single value `s3 cret` — and stopping at whitespace printed ` cret`.
  # Confirmed with `PQconninfoParse`, not inferred from the grammar.
  "dsn escaped space"   => ("host=h password=s3\\ cret dbname=f1", "host=h password=**** dbname=f1"),
  # Also found in review: PostgreSQL documents "spaces around a setting's equal sign are optional",
  # and libpq parses both of these as `password=s3cret`. The pre-review pattern matched neither.
  # The mask normalises the spacing, which is fine — this is a redaction, not a round trip.
  "dsn spaces around =" => ("host = h password = s3cret", "host = h password=****"),
  "dsn space after ="   => ("host=h password= s3cret", "host=h password=****"),
  # A URL nested inside a DSN value. Pins that the two passes are order-independent: whichever runs
  # first, nothing of `b@c` survives.
  "dsn value holds url" => ("password=a://b@c dbname=f1", "password=**** dbname=f1"),
  # The escape `\\.` missed, found by differential fuzzing against libpq: PCRE's `.` does not match
  # a newline without DOTALL, so `\` + LF ended the value and printed the tail. The quoted arm fell
  # through the same way — its closing quote was never reached, so the unquoted arm took `'abc` and
  # the rest was printed verbatim. `(?is)` is what closes both.
  "dsn escaped newline" => ("host=h password=abc\\\nSECRETTAIL dbname=f1",
                            "host=h password=**** dbname=f1"),
  "dsn esc nl quoted"   => ("host=h password=" * SQ * "abc\\\nSECRETTAIL" * SQ * " dbname=f1",
                            "host=h password=**** dbname=f1"),
  # A BARE space — the one form libpq rejects, and the one PormG's own builder produces, because
  # `_build_connection_pool!` interpolates the YAML value with no quoting. So a passphrase password
  # makes a DSN that cannot connect, and the connect failure is what carries the DSN into a log.
  # The value therefore runs on to the next `key=` token instead of stopping at the first space.
  "dsn bare space"      => ("host=127.0.0.1 password=corr3ct horse battery dbname=f1 user=bob",
                            "host=127.0.0.1 password=**** dbname=f1 user=****"),
  "dsn bare space tail" => ("host=h password=hunter 2 dbname=f1", "host=h password=**** dbname=f1"),
  # Double quotes are NOT a libpq quoting mechanism, so this is the same bare-space class.
  "dsn double quoted"   => ("host=h password=\"s3 cret\" dbname=f1", "host=h password=**** dbname=f1"),

  # ── URL/URI DSN ─────────────────────────────────────────────────────────────
  # Defect 1 — every row in this block came back UNCHANGED before #649.
  "url user:password"   => ("postgresql://pingo:s3cret@localhost:5432/f1",
                            "postgresql://****:****@localhost:5432/f1"),
  # The SHAPE is preserved: no `:` in the userinfo means no invented password. "This URL carries no
  # password" is the signal someone debugging an authentication failure is looking for.
  "url user only"       => ("postgresql://pingo@localhost:5432/f1",
                            "postgresql://****@localhost:5432/f1"),
  "url no userinfo"     => ("postgresql://localhost:5432/f1", "postgresql://localhost:5432/f1"),
  "url keeps query"     => ("postgres://pingo:s3cret@localhost/f1?sslmode=require",
                            "postgres://****:****@localhost/f1?sslmode=require"),
  # An unencoded `@` inside the password. The split lands on the LAST `@` before the path, which
  # OVER-redacts here: libpq itself splits on the FIRST (`postgres://u:p@ss@h/db` is password `p`,
  # host `ss@h`), so `ss` is host text rather than a password tail. Masking it anyway is the safe
  # direction and matches WHATWG URL parsing, which other consumers of a `url:` value use.
  "url @ in password"   => ("postgres://pingo:p@ss@localhost/f1",
                            "postgres://****:****@localhost/f1"),
  "url uppercase"       => ("POSTGRESQL://PINGO:S3CRET@localhost/f1",
                            "POSTGRESQL://****:****@localhost/f1"),
  # Found in review, and the worst of the three: `?` and `#` are ordinary password characters that
  # users routinely leave unencoded. `PQconninfoParse` reads both of these as the full password, so
  # excluding them from the userinfo class — which the first spelling of the pattern did, reasoning
  # from URI grammar rather than from libpq — meant such a password was never redacted at all.
  "url ? in password"   => ("postgres://u:SEC?RETpw@host/db", "postgres://****:****@host/db"),
  "url # in password"   => ("postgres://u:SEC#RETpw@host/db", "postgres://****:****@host/db"),
  # An unencoded `/` in the password (#658). This row used to assert the string came back UNCHANGED,
  # on the reasoning that libpq reads no password from it — true, but libpq reads the password's
  # tail as a DBNAME instead, so "no password parsed" never meant "nothing secret here". The row
  # recorded the leak as the rule; it now pins the mask.
  "url / in password"   => ("postgres://u:SEC/RET@host/db", "postgres://****:****@host/db"),
  # The issue's three shapes, which libpq parses three different ways — host `u` + port `pa`; host
  # `u` + an integer port, which the #657 port check lets through; and userinfo `u:pa` + host `ss`.
  # All three put the password's tail in the dbname, and all three must mask to the last `@`.
  "url / pw, alpha tail"=> ("postgresql://u:pa/ssSEC658@localhost/db",
                            "postgresql://****:****@localhost/db"),
  "url / pw, digit head"=> ("postgresql://u:1234/SEC658@localhost/db",
                            "postgresql://****:****@localhost/db"),
  "url @ then / in pw"  => ("postgresql://u:pa@ss/SEC658@localhost/db",
                            "postgresql://****:****@localhost/db"),
  # The remedy the error message gives: a percent-encoded `/` is already fine, and stays fine.
  "url %2F in password" => ("postgresql://u:p%2Fw@h/db", "postgresql://****:****@h/db"),
  # Whitespace in the userinfo: the same mistake as `?`/`#`, found the same way. libpq reads
  # `abc SECRETTAIL` as the whole password, so excluding whitespace meant the ENTIRE DSN went
  # through untouched — not a fragment, the whole string. Three shapes, because the user half leaks
  # independently of the password half.
  "url space in pw"     => ("postgres://u:abc SECRETTAIL@h/db", "postgres://****:****@h/db"),
  "url tab in pw"       => ("postgres://u:abc\tSECRET@h/db", "postgres://****:****@h/db"),
  "url space in user"   => ("postgres://ab SECRETTAIL@h/db", "postgres://****@h/db"),
  # …but a LINE BREAK still terminates, which is the deliberate bound on how far a runaway `://`
  # can reach when this public function is pointed at arbitrary log text.
  "url stops at newline"=> ("connecting to postgres://myhost\nfailed; mail ops@example.com",
                            "connecting to postgres://myhost\nfailed; mail ops@example.com"),
  # `://` with no `@` is not userinfo and must not be touched — the SQLite URI spelling.
  "url sqlite triple"   => ("sqlite:///var/data/app.sqlite3", "sqlite:///var/data/app.sqlite3"),
  # An `@` in the query OVER-redacts (#658). Before, this row asserted the string came back
  # unchanged, because the userinfo class stopped at `/`. It cannot stop there any more: a password
  # holding `/` puts the credential's tail on the far side of it, and a tail holding `?` puts it in
  # the query too (`u:pa/ss?SEC@h`). Losing `localhost/f1` from a log line is the price of never
  # leaking that tail, and it is the safe direction.
  "url @ after query"   => ("postgres://localhost/f1?opt=a@b", "postgres://****@b"),
  # The same, with a `?` after the `/`: libpq rejects this one at parse time, which is exactly when
  # the pool reports `connection=` — so the whole tail must go.
  "url / then ? in pw"  => ("postgres://u:pa/ss?SEC658@h/db", "postgres://****:****@h/db"),
  # Credentials as query parameters. The keyword rule catches them, and swallows the parameters
  # that follow on the same token — accepted over-redaction, recorded here as intended rather than
  # accidental. Scheme, host and database all sit before the `?` and survive.
  "url query creds"     => ("postgres://localhost/f1?user=pingo&password=s3cret&sslmode=require",
                            "postgres://localhost/f1?user=****"),

  # ── things that must NOT change ─────────────────────────────────────────────
  "sqlite path"         => ("/var/data/app.sqlite3", "/var/data/app.sqlite3"),
  "sqlite memory"       => (":memory:", ":memory:"),
  "no secret"           => ("dbname=f1_database", "dbname=f1_database"),
  "empty"               => ("", ""),
  # Already-redacted input: this function's output is a valid input to it.
  "already redacted"    => ("postgresql://****:****@localhost:5432/f1",
                            "postgresql://****:****@localhost:5432/f1"),
]

# Every credential appearing anywhere above. All invented, so printing one in a failure message
# discloses nothing — which is what lets this file assert on VALUES where the integration suite can
# only assert on tokens.
#
# **FRAGMENTS are in this list, not just whole secrets**, and that is the difference between the
# testset below meaning what its name says and merely looking as if it does. Every defect this file
# pins is a PARTIAL leak: the pre-#649 rule emitted `password=**** cret'`, which contains no whole
# secret from a naive list and would have sailed through. `cret` and `RETpw` are what catch it.
const FAKE_SECRETS = ("s3cret", "s3cr3t", "topsecret", "pingo", "admin",
                      "PINGO", "S3CRET", "p@ss", "p&w", "s3 cret",
                      "cret", "RETpw", "SEC?RETpw", "SEC#RETpw",
                      "SECRETTAIL", "SECRET", "corr3ct", "horse", "battery", "hunter",
                      "SEC658", "RET@", "ss/", "p%2Fw")

# ─────────────────────────────────────────────────────────────────────────────
# The rule itself, as exact documents. Per-case `@testset` so a failure names the dialect that
# regressed rather than reporting `false` twenty times over.
# ─────────────────────────────────────────────────────────────────────────────
@testset "redact_secret masks both DSN dialects (#649)" begin
  for (label, (input, expected)) in REDACT_CASES
    @testset "$label" begin
      @test R649(input) == expected
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The property behind the table, asserted independently of the expected literals. Equality to a
# recorded output is only as good as the recording; this states the actual requirement — no
# fragment of a credential survives — and stays true even if every literal above were mis-recorded.
# ─────────────────────────────────────────────────────────────────────────────
@testset "no credential fragment survives" begin
  for (label, (input, _)) in REDACT_CASES
    @testset "$label" begin
      out = R649(input)
      for secret in FAKE_SECRETS
        # Only a secret this input actually CONTAINS can be leaked by it. Without the guard the
        # loop asserts absence of strings the case never held — vacuously true, and it reads as
        # coverage.
        occursin(secret, input) || continue
        @test !occursin(secret, out)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Idempotence. A redacted string is fed back through the pool's logging path on a retry, and a rule
# that re-masked its own mask would corrupt the string a little more on every pass.
#
# The guarantee is stated as MONOTONE rather than "a fixed point", because the stronger claim is
# false and was caught saying so: `password=''\''x' host=h` — an unbalanced quote beside an escaped
# one — masks slightly further on a second pass. Every well-formed connection string IS a fixed
# point, which is what the table below asserts; the property that holds for malformed input too is
# that a second pass never reveals more, which is the half that actually matters.
# ─────────────────────────────────────────────────────────────────────────────
@testset "redaction is a fixed point for well-formed input" begin
  for (label, (input, _)) in REDACT_CASES
    @testset "$label" begin
      once = R649(input)
      @test R649(once) == once
    end
  end

  # The malformed counterexample, pinned so the docstring's wording stays honest: re-redacting
  # changes the string, and every change is in the direction of MORE masking.
  malformed = "password=" * SQ * SQ * "\\" * SQ * SQ * "x" * SQ * " host=h"
  once, twice = R649(malformed), R649(R649(malformed))
  @test once != twice
  @test length(twice) <= length(once)
  @test !occursin("x" * SQ, twice)
end

# ─────────────────────────────────────────────────────────────────────────────
# The signature is `AbstractString`, not `String`. `redact_secret` is public, documented API, and
# `split`/`strip` — the obvious way a caller gets a connection string out of a larger one — hand
# back a `SubString`. A `String`-only signature makes that a `MethodError` at the call site.
# ─────────────────────────────────────────────────────────────────────────────
@testset "accepts any AbstractString" begin
  full = "prefix|host=localhost password=s3cret user=pingo"
  sub = split(full, '|')[2]
  @test sub isa SubString
  masked = R649(sub)
  @test masked isa String
  @test masked == "host=localhost password=**** user=****"
end

# ─────────────────────────────────────────────────────────────────────────────
# The rule must not THROW, whatever it is handed. `redact_secret` runs inside error constructors —
# `PoolConnectError` is built from it — so an exception here would replace the real failure with a
# regex error, at exactly the moment the operator needs the real one.
#
# The adversarial input is not decoration. With a backtrackable URL pattern this very string throws
# `PCRE.exec error: JIT stack limit reached`, because a reconsiderable repeat costs one JIT stack
# frame per iteration. The shipped pattern is possessive, which is what makes this pass — measured
# at ~1 ms for 250k segments, against a throw for the backtrackable spelling.
# ─────────────────────────────────────────────────────────────────────────────
@testset "redaction never throws" begin
  hostile = [
    "adversarial userinfo" => "postgres://" * repeat("a@", 250_000) * "host/db",
    # BOTH patterns need the adversarial case, which is the lesson from review: the first version
    # of the quoted arm was written `(?:[^'\\]|\\.)*` — a backtrackable group repeat — and threw
    # `JIT stack limit reached` at a 43,689-character value while the URL pattern beside it was
    # hardened against exactly that. The testset existed and exercised only the URL half, so the
    # regression was invisible here. The arm is unrolled and possessive now; these run in ~5 ms.
    "adversarial quoted"   => "password=" * SQ * repeat("a", 1_000_000),
    "adversarial closed"   => "password=" * SQ * repeat("a", 1_000_000) * SQ * " host=h",
    "adversarial unquoted" => "password=" * repeat("a", 1_000_000) * " host=h",
    # Many `://` and no `@` on the line (#658). Once `/` stopped ending a userinfo run, each failed
    # `://` scanned to the line's end — quadratic, 12 s for this 520 KB line before `(*SKIP)`. The
    # timing half is asserted in the testset below; here it only has to return.
    "many schemes, no @ on the line" => repeat("see http://x ", 40_000) * "\nops@example.com",
    "trailing @"           => "postgres://pingo@",
    "bare scheme"          => "postgres://",
    "colons only"          => "::::",
    "unterminated quote"   => "password=" * SQ * "s3cret dbname=f1",
    "newlines"             => "host=a\npassword=s3cret\nuser=b",
    "unicode"              => "host=café password=ségret user=naïve",
  ]
  for (label, input) in hostile
    @testset "$label" begin
      out = R649(input)
      @test out isa String
      # Whatever the shape, a credential the rule DID match must still be gone.
      if label == "newlines" || label == "unterminated quote"
        @test !occursin("s3cret", out)
      elseif label == "unicode"
        @test !occursin("ségret", out)
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The URL rule must stay LINEAR in the line length (#658).
# Widening the userinfo class across `/` made every `://` that never reaches an `@` scan to the end
# of its line, so a log line full of URLs cost N². `(*SKIP)` restores linear time; this pins it,
# because the output is identical either way and only a clock can tell the two spellings apart.
# Measured: 12 s (quadratic) against ~1 ms (linear) on the first input. The 1 s bound is two orders of
# magnitude clear of both, so it does not flake on a slow CI runner and still fails the regression.
# ─────────────────────────────────────────────────────────────────────────────
@testset "the URL rule is linear on many `://` with no `@` on the same line (#658)" begin
  for (label, input) in ["prose with URLs" => repeat("see http://x ", 40_000) * "\nops@example.com",
                         "bare schemes"    => repeat("://", 40_000) * "\n@"]
    @testset "$label" begin
      R649(input)                     # compile outside the clock
      @test (@elapsed R649(input)) < 1.0
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# ONE owner for the rule (#649, acceptance criterion 2).
#
# `ConnectionPool.jl` used to carry a byte-identical copy of both the pattern and the function. The
# identity assertion pins that its ~17 call sites now resolve to Configuration's binding; the
# source scan is the half that catches the real regression, because a second copy can be pasted
# back in without the identity check noticing — a new `const _REDACT_*` beside a locally defined
# function would simply shadow the import.
# ─────────────────────────────────────────────────────────────────────────────
@testset "redaction has exactly one owner" begin
  @test PormG.ConnectionPool.redact_secret === PormG.Configuration.redact_secret
  @test parentmodule(PormG.Configuration.redact_secret) === PormG.Configuration
  @test length(methods(PormG.Configuration.redact_secret)) == 1

  src = normpath(joinpath(@__DIR__, "..", "..", "src"))
  files = sort!([joinpath(r, f) for (r, _, fs) in walkdir(src) for f in fs if endswith(f, ".jl")])
  # A floor, so a scan that silently found nothing fails loudly instead of passing vacuously.
  @test length(files) > 10

  read_n(p) = replace(read(p, String), "\r\n" => "\n")
  rel(p) = replace(relpath(p, src), '\\' => '/')
  definers = [rel(p) for p in files if occursin("function redact_secret(", read_n(p))]
  patterns = [rel(p) for p in files if occursin("const _REDACT_", read_n(p))]

  @test definers == ["Configuration.jl"]
  @test patterns == ["Configuration.jl"]
end
