## Julia 1.13 is the minimum: `julia = "1.12"` → `julia = "1.13"`

- **Version**: 0.9.0
- **PormG ref**: `Project.toml` (`[compat] julia`), `.github/workflows/CI.yml`
- **Recorded**: 2026-10-20
- **Severity**: breaking, for an environment on Julia 1.12 only. No call returns a different value.

### What changed

PormG's `[compat]` floor for Julia moves from 1.12 to 1.13, and CI tests Julia 1.13 only: the
unit suite on Linux and Windows, the load-without-drivers check, and the floor resolve of every
other `[compat]` range. Julia 1.12 is no longer tested, so it is no longer claimed.

Nothing in PormG's API changes. On Julia 1.13 an upgrade is a version bump and nothing else. On
Julia 1.12 the package manager cannot resolve a PormG release from this train onward and keeps the
last version released for 1.12.

### How to find the calls to migrate

There are no calls. Check the Julia the environment runs (`VERSION` in its REPL, or the
`julia_version` line at the top of its `Manifest.toml`), and the Julia its CI and deployment images
install.

### Migrate your app

```julia
# ✗ before: Julia 1.12 — `Pkg.update()` stays on the last PormG release that allows 1.12
julia> VERSION
v"1.12.7"

# ✓ after: run Julia 1.13 or newer, then update
julia> VERSION
v"1.13.1"

julia> using Pkg; Pkg.update("PormG")
```
