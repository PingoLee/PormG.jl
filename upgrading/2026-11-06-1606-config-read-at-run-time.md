## A built image reads its configuration at run time: `load` refuses while one is written (#1606)

- **Version**: 0.10.0
- **PormG ref**: #1606, part of #1599 ; `src/Configuration.jl`, `src/ConnectionPool.jl`
- **Recorded**: 2026-11-06
- **Severity**: behavior change, for an app built into a sysimage or a `juliac` executable that loads
  its configuration in the code the build runs. A REPL, a script, a service on a package image and a
  package that loads in `__init__` are unaffected.

### What changed

A sysimage or a `juliac` executable saves the state of the process that built it. A `load` run in
that process put the configuration into the file, the database password in the pool's connection
string included. At run time `load` found the key and returned early, so the program served the
build machine's settings instead of the deployment's. This was measured on a `juliac` executable
whose entry script loaded at its top level: the password was in the binary (`strings`), and the key
was in `PormG.config` when `main` started.

| | before | now |
|---|---|---|
| `load` / `load_many` / `register_connection` / `register_offline` / `set_connection_resolver` / `set_before_connect_hook` while an image is written | stores the connection or the hook, which the image keeps | raises `InvalidConfigurationError` before reading or storing anything |
| a connection an image still holds when the program starts | used as is; the run-time `load` returns early | dropped, with a warning naming its key; the run-time `load` reads the deployment's file |

"While an image is written" means while Julia generates non-incremental output (a sysimage, a
`juliac` build). Precompiling a package is incremental and is not affected: a package image saves
none of PormG's state, and a package that loads in its module body loads again in its `__init__`.

The pool-monitor and worker flags an image could keep are reset at start-up too (the SQLite worker,
the reaper), so the program starts its own tasks.

### How to find the calls to migrate

A build that now fails with:

```
`PormG.Configuration.load` was called while an image (a sysimage or a `juliac` executable) is being built.
```

or a built program that logs `PormG dropped the connections this image was built with`. In the
source, look for a `load`, `load_many`, `register_connection`, `register_offline`,
`set_connection_resolver` or `set_before_connect_hook` at the top level of a `juliac` entry script, or
anywhere the build executes rather than at run time. A `set_models` / `@import_models` at the same top
level now fails with its own error, saying the models folder is not loaded: move it to `main` with the
`load`.

### Migrate your app

```julia
# ✗ before: the entry script loads while juliac compiles it
using MyApp, PormG
PormG.Configuration.load("db"; root = MyApp.ROOT, env = "prod")
function (@main)(args::Vector{String})::Cint
    MyApp.serve()
    return 0
end

# ✓ after: load, and bind the models, when the program runs
using MyApp, PormG
function (@main)(args::Vector{String})::Cint
    PormG.Configuration.load("db"; root = MyApp.ROOT, env = "prod")
    PormG.Models.set_models(MyApp.models, "db")
    MyApp.serve()
    return 0
end
```
