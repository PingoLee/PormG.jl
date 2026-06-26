# ==============================================================================
# Activate the SQL-driver extensions for the test session.
#
# Since #34, LibPQ and SQLite are WEAK dependencies of PormG (Project.toml `[weakdeps]`).
# Loading them activates ext/PormGLibPQExt.jl / ext/PormGSQLiteExt.jl, which supply the
# `backend_*` methods PormG dispatches to. Without them every DB operation raises the
# friendly "run `using LibPQ` / `using SQLite`" error.
#
# Tests run in two kinds of environment, so we load defensively:
#   • Pkg.test() / CI: the drivers are direct deps of the temp test env (`[extras]` +
#     `[targets].test`), so a plain `using` works.
#   • julia --project=. test/…: the package env lists them only as weakdeps, which cannot
#     be `using`-ed — but they ARE in the manifest, so `Base.require` by UUID loads them
#     and triggers the extension. (`Base.require` also works in the Pkg.test env.)
# ==============================================================================

for (name, uuid) in (("LibPQ",  "194296ae-ab2e-5f79-8cd4-7183a0a5a0d1"),
                      ("SQLite", "0aa819cd-b072-5ff4-a722-6bc24af294d9"))
    sym = Symbol(name)
    try
        # Direct dep of the active env (Pkg.test): `using` both loads it and binds the name.
        @eval using $sym
    catch
        # Weakdep under `--project=.`: load from the manifest and bind the name in Main so
        # that qualified references in tests (e.g. `SQLite.tables(conn)`) resolve.
        m = Base.require(Base.PkgId(Base.UUID(uuid), name))
        @eval Main const $sym = $m
    end
end
