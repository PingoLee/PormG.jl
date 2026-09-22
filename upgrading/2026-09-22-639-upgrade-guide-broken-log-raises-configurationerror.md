## `upgrade_guide` reports a broken change log as `InvalidConfigurationError`, not `ArgumentError` (#639)

- **Version**: Unreleased
- **Recorded**: 2026-09-22
- **PormG ref**: #639; `src/tools.jl` (`_upgrading_dir`, `_upgrading_files`)
- **Severity**: behavior change — the same failure now raises a different type

### What changed

`upgrade_guide` refuses to run when the `upgrading/` log bundled with the install is missing or
holds no entry files, so that a log trimmed by a sparse checkout, an rsync filter or a Docker layer
cannot print *"nothing to port"* and look like being up to date. Those refusals used to be
`ArgumentError`, so the `catch e isa PormGError` that the *Errors* page of the docs recommends
did not catch them. They are now `InvalidConfigurationError` (`<: ConfigurationError <: PormGError`):
nothing the caller passed is wrong, the install is.

**Unchanged:** calling `upgrade_guide()` without `from` still raises `ArgumentError`. That one is a
mistake in the call itself, and PormG keeps `ArgumentError` for Julia-level API misuse.

The messages are unchanged, so code that matches on the text keeps working.

### How to find the calls to migrate

Only code that catches `ArgumentError` around `upgrade_guide` to detect a missing log is affected.
List every `ArgumentError` in a file that calls it — whole files, because a `try` body can put the
`catch` any distance from the call — and check each hit:

```bash
grep -rln 'upgrade_guide' --include=*.jl . | xargs -r grep -n 'ArgumentError'
```

A hit that handles a *missing `from`* needs no change; that one is still `ArgumentError`.

### Migrate your app

```julia
# ✗ before
try
    PormG.upgrade_guide(from = v"0.6.0")
catch e
    e isa ArgumentError || rethrow()
    @warn "PormG's upgrade log is not installed" exception = e
end

# ✓ after
try
    PormG.upgrade_guide(from = v"0.6.0")
catch e
    e isa PormG.ConfigurationError || rethrow()
    @warn "PormG's upgrade log is not installed" exception = e
end
```
