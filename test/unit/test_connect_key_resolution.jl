"""
Unit coverage for models-folder → connection-key resolution (`Models._resolve_connect_key`,
`Models._pick_connect_key`, `Kernel._folder_tag`, `Kernel._canonical_folder_path`), the #550 regression.

`set_models` and `ensure_model_initialized` both had to answer "which configured connection does
this models folder belong to?", and both answered it with a first-match `break` over `config` —
a `Dict`. Two conditions of different strength were OR'd into one test, so a match on the folder's
final component on an earlier-hashed key beat an exact path match on a later one. Which database a
model's queries reached was decided by hash order, and nothing was logged when it went wrong.

The resolver is pure apart from its warnings, so its rules pin deterministically here:

  1. the strongest rank wins (exact path over folder name);
  2. within a rank, an explicitly loaded key beats one `set_models` minted implicitly — recorded on
     the entry as `implicit = true`, never inferred from the key's spelling (#553);
  3. anything still tied is a warned ambiguity resolved lexicographically, for reproducibility.

Rule 2 is not decoration. The incident behind #550 is one folder registered TWICE — once implicitly
by `set_models` under an absolute path (environment taken from `default_env:`), once explicitly by
`Configuration.load("db"; env = ...)`. Both match at the path rank, and a plain lexicographic
tiebreak picks the absolute path EVERY time, because `/` (0x2F) sorts below every letter and digit.
Ranking without rule 2 therefore turns a coin-flip into a guaranteed wrong answer.

Sibling guard, same failure mode one layer up: `test_self_heal_inference.jl`.
"""

using Test
using Logging
using PormG
import PormG: Configuration
using PormG.Models: Model, IDField

const _S550 = Configuration.Settings

# ─────────────────────────────────────────────────────────────────────────────
# Path canonicalisation and folder tags
# Both helpers exist to neutralise one stdlib trap each, and both traps are pinned here so a
# future reader can see why the plain stdlib call was not used. `basename("db/") == ""` would
# make every trailing-separator folder match every other; `abspath("db/") != abspath("db")`
# would push a folder configured with a trailing separator out of the path rank entirely.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Path canonicalisation and folder tags" begin
  # The stdlib behaviours the helpers work around. Asserted so the reason they exist is explicit.
  @test basename("db/") == ""
  @test abspath("db/") != abspath("db")

  # The ordinary spellings an app actually passes all reduce to the same tag.
  @test PormG.Models._folder_tag("db")          == "db"
  @test PormG.Models._folder_tag("../db")       == "db"
  @test PormG.Models._folder_tag("./db")        == "db"
  @test PormG.Models._folder_tag("/srv/app/db") == "db"
  @test PormG.Models._folder_tag("db/")  == "db"     # the basename trap, neutralised
  @test PormG.Models._folder_tag("db//") == "db"

  # `_canonical_folder_path` collapses the trailing separator that `abspath` preserves.
  @test PormG.Models._canonical_folder_path("db/")  == PormG.Models._canonical_folder_path("db")
  @test PormG.Models._canonical_folder_path("./db") == PormG.Models._canonical_folder_path("db")

  # A tag that names no folder can never be matched on. `isdirpath` is true for all four of
  # these — that single predicate is the whole guard, so these assertions document its reach
  # rather than covering separate branches.
  @test !PormG.Models._usable_folder_tag("")
  @test !PormG.Models._usable_folder_tag(".")
  @test !PormG.Models._usable_folder_tag("..")
  @test !PormG.Models._usable_folder_tag("/")
  @test PormG.Models._usable_folder_tag("db")
end

# ─────────────────────────────────────────────────────────────────────────────
# Rank beats hash order: an exact path match always wins over a folder-name match
# The #550 regression proper. `config` is a Dict, so the pre-fix loop's `break` handed the
# binding to whichever key hashed first regardless of how strong its match was.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Ranked resolution: exact path beats folder name" begin
  target = abspath("some_app/db")

  # Hash order is not ours to choose, and a single hard-coded pair of key names proves nothing:
  # with `Dict("a_db"=>weak, "z_db"=>exact)` Julia happens to present the EXACT key first, so
  # even the pre-fix first-match loop returns the right answer and the assertion is theatre.
  # So sweep a spread of name pairs, and assert below that at least one of them really does
  # present the weak key first — the ordering that exposed the defect.
  weak_names  = ("a_db", "alpha", "cfg_a", "one", "near")
  exact_names = ("z_db", "zeta", "cfg_b", "two", "far")
  configs = [Dict(w => _S550(db_def_folder = "other_app/db"), e => _S550(db_def_folder = target))
             for w in weak_names, e in exact_names]

  # Precondition: the sweep is adversarial. If a future Julia's hashing makes every pair
  # exact-first, this test silently stops discriminating — so fail here instead.
  @test any(cfg -> first(collect(keys(cfg))) ∉ exact_names, configs)

  # The actual invariant: the exact-path match wins in EVERY one of those orderings.
  for cfg in configs
    exact_key = only(k for (k, v) in cfg if abspath(v.db_def_folder) == target)
    @test PormG.Models._resolve_connect_key(target, cfg) == exact_key
    @test PormG.Models._resolve_connect_key("some_app/db", cfg) == exact_key
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Explicit beats implicit: the incident shape from #550
# One folder registered twice — implicitly under its absolute path (environment from
# `default_env:`, i.e. nobody's choice) and explicitly under a short key. Both match at the path
# rank. Ranking alone does NOT settle this, and a lexicographic tiebreak settles it the wrong
# way every single time because "/" sorts below every letter. The explicit key must win.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Explicit key beats an implicitly minted absolute-path key" begin
  mktempdir() do root
    app = joinpath(root, "app")
    mkpath(joinpath(app, "db"))
    cd(app) do
      abs_key = joinpath(app, "db")          # what the implicit load in set_models registers
      cfg = Dict(abs_key => _S550(db_def_folder = abs_key, implicit = true),
                 "db"    => _S550(db_def_folder = "db"))

      # The lexicographic trap this rule exists to defeat: sort() puts the absolute path first.
      @test first(sort([abs_key, "db"])) == abs_key

      # Every spelling a caller might pass must land on the EXPLICIT key, not the absolute one.
      for spelling in (abs_key, "db", "./db")
        key = @test_logs (:warn,) match_mode = :any PormG.Models._resolve_connect_key(spelling, cfg)
        @test key == "db"
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# The recorded flag decides, not the key's spelling (#553)
# `_pick_connect_key` used `isabspath(key)` as a stand-in for "minted by the implicit load". That
# is exact on the `@import_models` route, which always registers an absolute folder, and inverted
# for the other documented form: `set_models(mod, "db")` implicit-loads under the RELATIVE string,
# so an application that loaded "/srv/app/db" explicitly lost to its own implicit entry. The fact
# is now recorded on the settings entry, and the key's shape is irrelevant.
# ─────────────────────────────────────────────────────────────────────────────
@testset "The recorded flag decides, not the key's spelling (#553)" begin
  # The trap the proxy walked into, documented: filtering on `!isabspath` keeps "db".
  @test filter(!isabspath, ["/srv/app/db", "db"]) == ["db"]

  # Same candidates with the fact attached: the explicit absolute key wins, and the warning says
  # the losers were recorded as implicit rather than hedging about their spelling.
  key = @test_logs((:warn, r"recorded as minted by `set_models`' implicit load"), match_mode = :any,
                   PormG.Models._pick_connect_key(["/srv/app/db" => false, "db" => true],
                                                  "x/db", "folder name"))
  @test key == "/srv/app/db"

  # Through the resolver, which reads the flag off each settings entry.
  cfg = Dict("/srv/app/db" => _S550(db_def_folder = "/srv/app/db"),
             "db"          => _S550(db_def_folder = "db", implicit = true))
  key = @test_logs (:warn,) match_mode = :any PormG.Models._resolve_connect_key("x/db", cfg)
  @test key == "/srv/app/db"

  # The flag defaults to explicit — a plain `Settings()` is what `Configuration.load` mints.
  @test !_S550().implicit

  # A bare key vector is no longer a candidate list. The flag travels with the key so the two
  # cannot disagree, and the old signature must fail by dispatch rather than silently fall back
  # to the spelling rule.
  @test_throws MethodError PormG.Models._pick_connect_key(["/b/db", "/a/db"], "/c/db", "path")
end

# ─────────────────────────────────────────────────────────────────────────────
# The tiebreak of last resort is reproducible, not hash-ordered
# When the explicit/implicit rule cannot separate the candidates — two folders that genuinely
# share a name, or two absolute-path keys — the choice is arbitrary. It must at least be the
# SAME arbitrary choice on every boot, which the Dict-order version could not offer.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Irreducible ambiguity warns and resolves reproducibly" begin
  # Two distinct folders sharing a final component: both explicit, nothing to prefer.
  cfg = Dict("zeta"  => _S550(db_def_folder = "zeta_app/db"),
             "alpha" => _S550(db_def_folder = "alpha_app/db"))

  # The message is matched, not just the level. Two real defects hid behind a bare `(:warn,)`:
  # the folder-name rank claimed a duplicate registration that did not exist, and the candidate
  # list printed the NARROWED set, hiding the very entries the reader has to remove.
  key = @test_logs((:warn, r"several configured folders share this folder's name"),
                   match_mode = :any,
                   PormG.Models._resolve_connect_key("third_app/db", cfg))
  @test key == "alpha"                                  # sorted, not hash order
  @test (@test_logs((:warn,), match_mode = :any,
                    PormG.Models._resolve_connect_key("third_app/db", cfg))) == "alpha"

  # Two IMPLICIT keys for the same folder: the explicit-beats-implicit filter finds no explicit
  # candidate, so it falls through to the reproducible sort rather than preferring at random.
  @test PormG.Models._pick_connect_key(["/b/db" => true, "/a/db" => true], "/c/db", "path") == "/a/db"

  # TWO explicit candidates plus one implicit: the preference must narrow to the explicit SET
  # first and break the tie inside it. Preferring only when exactly one explicit key exists put
  # the absolute key back in the running, and "/" sorts below every letter — so a single implicit
  # key beat two explicit ones, which is the very outcome the rule exists to prevent.
  @test PormG.Models._pick_connect_key(["/x/db" => true, "db_b" => false, "db_a" => false], "other/db", "folder name") == "db_a"

  # The prose must follow the RANK, because the two ranks describe opposite situations and their
  # remedies contradict each other. A rank-agnostic message is wrong at one of them, and both
  # wordings shipped wrong before this was asserted.
  @test_logs((:warn, r"registered under more than one configuration key"), match_mode = :any,
             PormG.Models._pick_connect_key(["/b/db" => true, "/a/db" => true], "/c/db", "path"))
  @test_logs((:warn, r"Load the folder once"), match_mode = :any,
             PormG.Models._pick_connect_key(["/b/db" => true, "/a/db" => true], "/c/db", "path"))
  @test_logs((:warn, r"distinct final components"), match_mode = :any,
             PormG.Models._pick_connect_key(["db_b" => false, "db_a" => false], "other/db", "folder name"))

  # The candidate list must be the FULL set. Narrowing it to the preferred keys dropped exactly
  # the implicit duplicates the warning is telling the reader to go and remove.
  full = nothing
  logs = Test.collect_test_logs() do
    PormG.Models._pick_connect_key(["/x/db" => true, "db_b" => false, "db_a" => false], "other/db", "folder name")
  end
  for rec in logs[1]
    haskey(rec.kwargs, :candidates) && (full = rec.kwargs[:candidates])
  end
  @test full == ["/x/db", "db_a", "db_b"]

  # An unambiguous match must stay quiet: a warning that fires in the normal case gets muted.
  quiet = Dict("db" => _S550(db_def_folder = "db"))
  @test_logs min_level = Logging.Warn PormG.Models._resolve_connect_key("../db", quiet)
end

# ─────────────────────────────────────────────────────────────────────────────
# Folder-name matching survives: it is what makes the ordinary case work
# Apps load configuration by short key (db_def_folder == "db") and import models by relative
# path ("../db"), which agree on abspath only when pwd() lines up. Removing the fallback would
# break every consuming app, so the fix ranks it rather than deleting it.
# NOTE: these assertions hold for the PRE-FIX code too. They are non-regression guards against
# "just delete the basename fallback", not evidence that the #550 fix works.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Folder-name fallback still resolves the normal case" begin
  cfg = Dict("db"     => _S550(db_def_folder = "db"),
             "db_gal" => _S550(db_def_folder = "db_gal"))

  @test PormG.Models._resolve_connect_key("../db", cfg)     == "db"
  @test PormG.Models._resolve_connect_key("../db_gal", cfg) == "db_gal"

  # Nothing matches at either rank → nothing, which is the caller's implicit-load branch.
  @test PormG.Models._resolve_connect_key("../db_unknown", cfg) === nothing
  @test PormG.Models._resolve_connect_key("db", Dict{String,PormG.PormGSettings}()) === nothing
end

# ─────────────────────────────────────────────────────────────────────────────
# Degenerate spellings never bind unrelated folders together
# Two pins: the `basename("db/") == ""` wildcard collision, and the mirror-image defect where a
# trailing separator pushed a legitimate folder out of the path rank and into the weaker one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Trailing separators neither wildcard nor demote a match" begin
  cfg = Dict("one" => _S550(db_def_folder = "app_one/db/"),
             "two" => _S550(db_def_folder = "app_two/reports/"))

  # Under the old `basename` comparison both folders tagged as "" and matched anything that
  # also tagged as "" — including each other and this unrelated path.
  @test PormG.Models._resolve_connect_key("app_three/warehouse/", cfg) === nothing

  # The real name still resolves through a trailing separator on either side.
  @test PormG.Models._resolve_connect_key("elsewhere/db", cfg) == "one"

  # A folder configured WITH a trailing separator must still match at the PATH rank, quietly —
  # `abspath` preserves the separator, so without `_canonical_path` this fell through to the
  # folder-name rank and picked up a spurious second candidate.
  cfg2 = Dict("db/"    => _S550(db_def_folder = "db/"),
              "vendor" => _S550(db_def_folder = "vendor/db"))
  @test_logs min_level = Logging.Warn PormG.Models._resolve_connect_key("db", cfg2)
  @test PormG.Models._resolve_connect_key("db", cfg2) == "db/"
end

# ─────────────────────────────────────────────────────────────────────────────
# `dynamic_connection` entries are not folders and must not be matched
# `add_connection` registers settings with this sentinel instead of a real folder. Every such
# entry would otherwise collide with every other, and `Configuration._resolve_loaded_key` already
# skips them — the two resolvers must not disagree about what counts as a folder.
# ─────────────────────────────────────────────────────────────────────────────
@testset "dynamic_connection entries are skipped" begin
  cfg = Dict("dyn1" => _S550(db_def_folder = "dynamic_connection"),
             "dyn2" => _S550(db_def_folder = "dynamic_connection"))
  @test PormG.Models._resolve_connect_key("dynamic_connection", cfg) === nothing

  # A real folder alongside them still resolves, unaffected.
  cfg2 = Dict("dyn1" => _S550(db_def_folder = "dynamic_connection"),
              "db"   => _S550(db_def_folder = "db"))
  @test PormG.Models._resolve_connect_key("../db", cfg2) == "db"
end

# ─────────────────────────────────────────────────────────────────────────────
# Call site: ensure_model_initialized routes through the resolver and warns on the remap
# Not a pure-function test — this drives the real `ensure_model_initialized` branch, so it fails
# if that call site is reverted to its own inline loop. It also pins the @info → @warn change:
# a remap fires when a model's key is absent from `config` entirely, which is a recovery rather
# than a normal event.
# ─────────────────────────────────────────────────────────────────────────────
@testset "ensure_model_initialized remaps through the resolver and warns" begin
  saved = copy(PormG.config)
  try
    empty!(PormG.config)
    mktempdir() do root
      app = joinpath(root, "app")
      mkpath(joinpath(app, "db"))
      cd(app) do
        abs_key = joinpath(app, "db")
        # The incident shape: the absolute entry is the one the implicit load minted, and since
        # #553 that is a recorded flag rather than something read off the key's spelling.
        PormG.config[abs_key] = _S550(db_def_folder = abs_key, implicit = true)
        PormG.config["db"]    = _S550(db_def_folder = "db")

        # A model carrying a key that is NOT in config — the shape left behind when a package is
        # precompiled against one configuration and loaded into a session with another.
        m = Model("remap_tbl", id = IDField())
        m.connect_key = joinpath(root, "gone", "db")

        @test_logs (:warn,) match_mode = :any PormG.Models.ensure_model_initialized(m)

        # Both config entries match this model's folder name; the explicit key must win, which
        # the pre-fix inline loop could not guarantee — it took whichever hashed first.
        @test m.connect_key == "db"
      end
    end
  finally
    empty!(PormG.config)
    merge!(PormG.config, saved)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Call site: set_models warns when it falls through to the implicit load
# The branch that guesses BOTH the environment (from `default_env:`) and the key (the caller's
# absolute path). It was silent before #550. Driving the real `set_models` also proves that call
# site consults the resolver rather than its own loop.
# ─────────────────────────────────────────────────────────────────────────────
@testset "set_models warns on the implicit load" begin
  saved = copy(PormG.config)
  root = mktempdir()
  try
    empty!(PormG.config)
    db = joinpath(root, "scratch_db")
    mkpath(db)
    write(joinpath(db, "connection.yml"),
          "default_env: test\ntest:\n  adapter: SQLite\n  database: \":memory:\"\n" *
          "  config:\n    change_db: true\n    change_data: true\n")

    # A throwaway module holding one model, exactly what `@import_models` would produce.
    scratch = Module(:ScratchImplicitModels)
    Core.eval(scratch, :(import PormG.Models))
    Core.eval(scratch, :(Thing = Models.Model("thing", id = Models.IDField())))

    # Every call below goes through `invokelatest`, and that is not incidental: since Julia 1.12
    # a binding created by `Core.eval` is only visible in a LATER world age, so calling
    # `set_models` directly from this block makes `names()` inside it return an empty module.
    # It would collect no models, bind nothing, and every assertion here would pass vacuously.
    # `@import_models`'s injected `__init__` calls it through `invokelatest` for the same reason
    # (see `Utils.ensure_models_init!`), so this also matches how production reaches it.
    @test :Thing in Base.invokelatest(names, scratch; all = true, imported = true)

    # Nothing is configured, so the resolver returns nothing and set_models guesses.
    @test_logs((:warn,), match_mode = :any,
               Base.invokelatest(PormG.Models.set_models, scratch, db))

    # The guess is visible twice over: the config gains an entry keyed by the caller's own
    # absolute path, and the model binds to it. Neither name was chosen by the application.
    # The exact value is knowable here, so assert it rather than merely its shape.
    @test haskey(PormG.config, db)
    @test Base.invokelatest(getfield, scratch, :Thing).connect_key == db
    @test PormG.config[db].implicit                 # recorded on the entry (#553), not read off the key

    # An explicit reload of that same key rebuilds the entry unflagged: `existing == path`, so no
    # migrate/reuse branch runs and the fact recorded is this caller's, not the old entry's.
    Configuration.load(db; env = "test")
    @test !PormG.config[db].implicit

    # Second call, now that the folder IS configured under that key: resolves silently.
    @test_logs(min_level = Logging.Warn,
               Base.invokelatest(PormG.Models.set_models, scratch, db))
  finally
    empty!(PormG.config)
    merge!(PormG.config, saved)
    rm(root; recursive = true, force = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# Configuration.load: one folder, one entry (#550, F3)
# The generator of every path-rank ambiguity above. `load` used to write `config[path] = …`
# unconditionally, so loading the same folder under a second spelling — typically the absolute
# path minted by `set_models`' implicit load — produced TWO entries, two pools, and possibly two
# databases for one folder. `_resolve_loaded_key` could always detect that; now `load` uses it,
# so the duplicate is not created rather than merely warned about.
# ─────────────────────────────────────────────────────────────────────────────
@testset "Configuration.load never mints a second entry for one folder" begin
  saved = copy(PormG.config)
  root = mktempdir()
  try
    empty!(PormG.config)
    app = joinpath(root, "app")
    db = joinpath(app, "db")
    mkpath(db)
    write(joinpath(db, "connection.yml"),
          "default_env: test\ntest:\n  adapter: SQLite\n  database: \":memory:\"\n" *
          "  config:\n    change_db: true\n    change_data: true\n")

    # 1. The implicit shape: the folder first registered under its ABSOLUTE path, flagged the way
    #    `set_models`' implicit branch flags it (#553 — the flag, not the path shape, is the fact).
    Configuration.load(db; env = "test", implicit = true)
    @test collect(keys(PormG.config)) == [db]
    @test PormG.config[db].implicit

    # 2. The application then loads it explicitly by short name, from its own root. Before #550
    #    this added a rival entry; now it migrates, because an explicit key beats an implicit one.
    cd(app) do
      @test_logs((:warn,), match_mode = :any, Configuration.load("db"; env = "test"))
      @test collect(keys(PormG.config)) == ["db"]        # exactly one entry, and it is the explicit one
      @test !haskey(PormG.config, db)                     # the implicit entry is gone, not shadowed
      @test !PormG.config["db"].implicit                  # and the survivor is the explicit one
    end

    # 3. The reverse order must NOT demote: an absolute-path load over an existing short key
    #    keeps the short key rather than replacing it with the implicit-looking one.
    empty!(PormG.config)
    cd(app) do
      Configuration.load("db"; env = "test")
      @test_logs((:warn,), match_mode = :any, Configuration.load(db; env = "test"))
      @test collect(keys(PormG.config)) == ["db"]
    end

    # 4. `load_many` reports the key that was really registered, not the string it was handed.
    empty!(PormG.config)
    Configuration.load(db; env = "test", implicit = true)
    cd(app) do
      @test Configuration.load_many(["db"]; env = "test") == ["db"]
    end

    # 5. The reuse branch must preserve the `db_def_folder == key` invariant. The migration
    #    runner derives the advisory-lock key from that field, so writing the caller's spelling
    #    into a reused entry silently changed one folder's lock identity.
    empty!(PormG.config)
    cd(app) do
      Configuration.load("db"; env = "test")
      @test_logs((:warn,), match_mode = :any, Configuration.load(db; env = "test"))
      @test PormG.config["db"].db_def_folder == "db"
    end

    # 6. `load` reports the key it registered — the caller's spelling is not always it.
    empty!(PormG.config)
    Configuration.load(db; env = "test", implicit = true)
    cd(app) do
      @test Configuration.load("db"; env = "test") == "db"        # migrated to the explicit key
      @test Configuration.load(db; env = "test") == "db"          # reused, not re-registered
    end

    # 7. An alternate `config` dict must be consulted AND written. `load` asked the global whether
    #    the folder was loaded while writing a local dict, which threw a KeyError from its own
    #    migrate branch — the kwarg exists precisely to allow an isolated configuration.
    empty!(PormG.config)
    Configuration.load(db; env = "test")                           # global holds the abs key
    local_cfg = Dict{String,PormG.PormGSettings}()
    cd(app) do
      @test Configuration.load("db"; env = "test", config = local_cfg) == "db"
    end
    @test collect(keys(local_cfg)) == ["db"]
    @test haskey(PormG.config, db)                                 # the global is untouched

    #    …and the migrate branch itself must run against the alternate dict. Step 7 above proves
    #    the global is not consulted; this drives the branch that actually threw the KeyError,
    #    by pre-populating the LOCAL dict with the implicit absolute key.
    empty!(PormG.config)
    local_cfg2 = Dict{String,PormG.PormGSettings}()
    Configuration.load(db; env = "test", config = local_cfg2, implicit = true)
    @test collect(keys(local_cfg2)) == [db]
    cd(app) do
      @test Configuration.load("db"; env = "test", config = local_cfg2) == "db"
    end
    @test collect(keys(local_cfg2)) == ["db"]                      # migrated within the local dict
    @test isempty(PormG.config)                                    # and the global never involved

    # 8. `is_loaded` and the model-side resolver now agree, because they share one canonical
    #    path helper. Disagreement was how a check could pass against an entry queries never used.
    #    Re-seed the GLOBAL config: step 7 deliberately left it empty to prove the alternate-dict
    #    paths never touch it, and these assertions read the global through `is_loaded`.
    empty!(PormG.config)
    cd(app) do
      Configuration.load("db"; env = "test")
    end
    cd(app) do
      @test Configuration.is_loaded("db")
      @test Configuration.is_loaded(db)
      # Use a spelling that is NOT a literal key: `_resolve_loaded_key` short-circuits on
      # `haskey`, so comparing the two resolvers on an exact key never exercises the shared
      # canonicalisation at all and would pass even if one of them still used bare `abspath`.
      @test PormG.Models._resolve_connect_key("./db", PormG.config) ==
            Configuration._resolve_loaded_key("./db") == "db"
      @test PormG.Models._resolve_connect_key("db/", PormG.config) ==
            Configuration._resolve_loaded_key("db/") == "db"
    end

    # 9. Two EXPLICIT spellings of one folder — absolute first, short second — are one entry, kept
    #    under the first key (#553). Before, the absolute one was taken for the implicit load and
    #    migrated away; it was the application's own choice, so now it is reused, with the same
    #    "already loaded under a different key" warning the reverse order (step 3) always had.
    empty!(PormG.config)
    Configuration.load(db; env = "test")
    @test !PormG.config[db].implicit
    cd(app) do
      @test_logs((:warn, r"already loaded under a different key"), match_mode = :any,
                 Configuration.load("db"; env = "test"))
      @test collect(keys(PormG.config)) == [db]
      @test !haskey(PormG.config, "db")
    end
  finally
    empty!(PormG.config)
    merge!(PormG.config, saved)
    rm(root; recursive = true, force = true)
  end
end

# ─────────────────────────────────────────────────────────────────────────────
# `Configuration.load` refuses a key a dynamic connection already holds (#620)
# The mirror of `register_connection`'s "Cannot overwrite static connection". A dynamic entry is
# not a folder, but `_resolve_loaded_key` short-circuits on an exact `haskey` hit BEFORE the loop
# that skips the `dynamic_connection` sentinel — so `existing == path`, neither the migrate nor
# the reuse branch runs (both require `existing != path`), and `load` fell straight through to
# `close_pool!` + `config[key] = Settings(...)`. A tenant pool was replaced by a folder-backed
# entry and closed, with nothing said beyond the pool-close log line.
#
# The guard is keyed on `path` at the TOP of `load`, ahead of the missing-folder refusal, because
# the common multi-tenant key names no folder at all — see the "no folder" case below, where the
# old answer told the user to create one.
# ─────────────────────────────────────────────────────────────────────────────
@testset "load refuses to take over a dynamic connection's key (#620)" begin
  saved = copy(PormG.config)
  root = mktempdir()
  _yml(p) = write(p, "default_env: test\ntest:\n  adapter: SQLite\n  database: \":memory:\"\n" *
                     "  config:\n    change_db: true\n    change_data: true\n")
  try
    empty!(PormG.config)
    app = joinpath(root, "app")
    mkpath(app)
    cd(app) do
      # Registered while no `db` folder exists. `register_connection`'s own `isdir(key)` guard
      # reads the working directory at REGISTRATION time, which is exactly why it cannot cover
      # this: the folder appears afterwards, or a later `cd` lands somewhere it already exists.
      Configuration.register_connection("db", "file::memory:?cache=shared"; adapter = "SQLite")
      @test PormG.config["db"].db_def_folder == "dynamic_connection"
      pool_before = PormG.config["db"].connections

      mkpath("db")
      _yml(joinpath("db", "connection.yml"))

      err = try
        Configuration.load("db"; env = "test")
        nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      # The message is the whole user-facing deliverable here, so pin that it names the cause
      # and the escape rather than merely asserting the type.
      @test occursin("dynamic connection", err.msg)
      @test occursin("unregister_connection(\"db\")", err.msg)

      # The refusal is only half the claim: the entry it refused to overwrite must be untouched.
      # Pre-fix this is where the defect showed — `db_def_folder` became "db" and `connections`
      # was a different pool object, the original having been closed.
      @test PormG.config["db"].db_def_folder == "dynamic_connection"
      @test PormG.config["db"].connections === pool_before

      # The escape the message names actually works, and the folder then loads normally.
      Configuration.unregister_connection("db")
      @test Configuration.load("db"; env = "test") == "db"
      @test PormG.config["db"].db_def_folder == "db"

      # The guard must not widen into "load never replaces anything": a STATIC entry under the
      # same key still reloads in place, as it always has.
      @test Configuration.load("db"; env = "test") == "db"
      @test PormG.config["db"].db_def_folder == "db"
    end

    # The shape that motivated putting the guard ahead of the missing-folder refusal: a dynamic
    # key that names NO folder. The old answer was a MissingConfigurationError telling the user
    # to create a folder of that name — advice which manufactures the collision above.
    empty!(PormG.config)
    cd(app) do
      Configuration.register_connection("tenant7", "file::memory:?cache=shared"; adapter = "SQLite")
      err = try
        Configuration.load("tenant7"; env = "test")
        nothing
      catch e
        e
      end
      @test err isa PormG.InvalidConfigurationError
      @test !(err isa Configuration.MissingConfigurationError)
      @test PormG.config["tenant7"].db_def_folder == "dynamic_connection"
    end

    # The NEGATIVE half, and the assertion that pins the design: the guard covers the EXACT key
    # only. The rejected alternative fix — making `_resolve_loaded_key`'s `haskey` shortcut skip
    # the sentinel — was refused because `is_loaded`/`status`/`ping` document resolving dynamic
    # keys. Under it this `load` would start throwing, so this is what fails if anyone tries it.
    # A second entry under a different spelling is the intended outcome: a dynamic key names no
    # folder, so there is nothing for the folder to collide WITH.
    # Its own directory: `register_connection`'s `isdir(key)` guard refuses "db" once the folder
    # above exists, so this case cannot reuse `app`.
    empty!(PormG.config)
    app3 = joinpath(root, "app3")
    mkpath(app3)
    cd(app3) do
      Configuration.register_connection("db", "file::memory:?cache=shared"; adapter = "SQLite")
      mkpath("db")
      _yml(joinpath("db", "connection.yml"))
      @test Configuration.load("./db"; env = "test") == "./db"
      @test sort(collect(keys(PormG.config))) == ["./db", "db"]
      @test PormG.config["db"].db_def_folder == "dynamic_connection"   # untouched
    end
  finally
    empty!(PormG.config)
    merge!(PormG.config, saved)
    rm(root; recursive = true, force = true)
  end
end
