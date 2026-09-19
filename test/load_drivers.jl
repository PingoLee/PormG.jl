# ==============================================================================
# Activate the SQL-driver extensions for the test session.
#
# Since #34, LibPQ and SQLite are WEAK dependencies of PormG (Project.toml `[weakdeps]`).
# Loading them activates ext/PormGLibPQExt.jl / ext/PormGSQLiteExt.jl, which supply the
# `backend_*` methods PormG dispatches to. Without them every DB operation raises the
# friendly "run `using LibPQ` / `using SQLite`" error.
#
# TWO environments carry the drivers, and both spell the project explicitly (#624):
#   • `julia --project=. -e 'using Pkg; Pkg.test()'` — the drivers are direct deps of the
#     temp test env (`[extras]` + `[targets].test`), so a plain `using` works. This is what
#     CI runs, via julia-actions/julia-runtest.
#   • `julia --project=test/integration …` — that env lists LibPQ and SQLite in `[deps]` and
#     PormG under `[sources]`, so `using` works there too. This is the spelling for running
#     ONE test file (unit or integration) on its own.
#
# `julia --project=. test/…` is NOT one of them, however plausible it looks. The package env
# lists the drivers only as weakdeps, which cannot be `using`-ed, and `Pkg.instantiate()`
# resolves `[deps]` alone — so there is nothing for `Base.require`-by-UUID to find either.
# Measured (#624): a single `Pkg.resolve()` in a provisioned worktree, reporting nothing but
# two unrelated JLL patch bumps, deleted both driver entries from `Manifest.toml`, after which
# the command died with `ArgumentError: Package LibPQ … is required but does not seem to be
# installed`. (CI's `load-without-drivers` job is related but proves something narrower: that
# the extensions never auto-load without an explicit `using`. It never tries `Base.require`,
# so it is not evidence about what the resolved environment contains.)
#
# It can still APPEAR to work, which is the trap #624 was filed for, and there are two ways:
#   1. a `Manifest.toml` resolved before #34 still lists the drivers, and `Pkg.instantiate()`
#      only WARNS about a stale manifest rather than re-resolving it — so the fallback below
#      survives on that one artifact until something re-resolves (`Pkg.resolve()`,
#      `Pkg.update()`, `Pkg.add()`, a Julia upgrade). `Manifest.toml` is gitignored, so
#      `git status` never shows it coming.
#   2. `LOAD_PATH` ends in `@v#.#`, so a developer who has LibPQ or SQLite installed in their
#      shared default environment gets them for free here — on their machine only.
# The `Base.require` branch is kept for case 1; it is a rescue, not a supported environment,
# and the error below is what you get when it runs out.
# ==============================================================================

let failures = Pair{String,String}[]
    for (name, uuid) in (("LibPQ",  "194296ae-ab2e-5f79-8cd4-7183a0a5a0d1"),
                         ("SQLite", "0aa819cd-b072-5ff4-a722-6bc24af294d9"))
        sym = Symbol(name)
        try
            # Direct dep of the active env (Pkg.test, test/integration): `using` both loads
            # it and binds the name.
            @eval using $sym
        catch
            try
                # Pre-#34 manifest under `--project=.`: load by UUID and bind the name in
                # Main so qualified references in tests (e.g. `SQLite.tables(conn)`) resolve.
                m = Base.require(Base.PkgId(Base.UUID(uuid), name))
                @eval Main const $sym = $m
            catch e
                # Keep the cause. "Not installed in this project" and "installed but its
                # build is broken" need opposite fixes, and a bare `catch` here reported the
                # first for both — telling someone whose libpq.so is missing to change
                # project, which is advice they have already taken.
                push!(failures, name => sprint(showerror, e))
            end
        end
    end

    if !isempty(failures)
        names  = join(first.(failures), " and ")
        causes = join(("  $n could not load:\n    " *
                       replace(first(split(msg, "\nStacktrace")), "\n" => "\n    ")
                       for (n, msg) in failures), "\n\n")
        error("""
        PormG's test suite needs the SQL driver extensions, but $names could not be loaded
        from the active project ($(something(Base.active_project(), "no project"))).

        $causes

        If the cause above is "required but does not seem to be installed", this is the wrong
        project rather than a broken checkout. LibPQ and SQLite are `[weakdeps]` (#34), so the
        package environment never installs them, and `Manifest.toml` is gitignored so nothing
        local says so. Use one of the two environments that carry them:

          full unit suite   julia --project=. -e 'using Pkg; Pkg.test()'
          one test file     julia --project=test/integration <path/to/test_file.jl>

        First use of the second one in a fresh checkout or worktree needs it instantiated once:

          julia --project=test/integration -e 'using Pkg; Pkg.instantiate()'

        Anything else above — a failed precompile, a missing system libpq/libsqlite3 — is a
        real environment problem and changing project will not fix it.

        See test/load_drivers.jl for why `--project=.` cannot run a test script (#624).
        """)
    end
end
