## Read a caught `PormGError` with `error_message`, not `e.msg` (#261)

- **Version**: 0.4.0
- **PormG ref**: issue #261 ; `src/exceptions.jl` (`error_message`, `PoolError`), `src/Kernel.jl`
  and `src/PormG.jl` (exports), `src/ConnectionPool.jl` (reparenting), `docs/src/api.md`
- **Recorded**: 2026-07-29
- **Severity**: **corrective** — no PormG behavior changed, so nothing that worked before stops
  working. It is logged here rather than treated as an additive feature (which this file excludes)
  because **apps that followed #239's advice may already carry a latent bug**: #239 told you to
  `catch PormGError`, and the natural next line, `e.msg`, throws a `FieldError` on four of the
  sixteen subtypes. Fixing that is a real app edit, which is what this entry exists to prompt.

### What changed

**1. `error_message(e)` is the uniform way to read any PormG error.**

#239 told you to `catch PormGError`. The obvious next line is `e.msg` — and that works for 12 of
the 16 concrete subtypes, then throws a `FieldError` on the four built from structured fields:
`DoesNotExist`, `MultipleObjectsReturned`, `PoolTimeoutError`, `PoolConnectError`. Those four
carry richer data (`model_name`, `adapter`, `pool_size`, `attempts`, …) instead of a flat string,
which is better design — there was just no uniform way to get text out of them.

`error_message` is defined through `showerror`, which every subtype implements, so it also stays
correct for subtypes added later. It never returns less than `e.msg` did: for most subtypes it is
exactly that field, and for the few with their own `showerror` it returns the richer rendering.

**2. `PoolError` is the new abstract umbrella over `PoolTimeoutError` / `PoolConnectError`.**

Matching `ConfigurationError` and `MigrationError`. `catch PoolError` now handles pool saturation
and connect failure without naming both; catching either concrete type still works unchanged.

### How to find the calls to migrate

```
rg -n '\.msg' <app> | rg -i 'catch|err|exception'
```

Look for anything reading `.msg` off a **caught** PormG error. A site that catches a specific
`msg`-carrying subtype (`FilterError`, `QueryBuildError`, …) is fine as-is; the risk is a site that
catches the broad `PormGError` and then reads `.msg`, because that path can now receive one of the
four structured types.

### Migrate your app

```julia
# ✗ before — throws FieldError if `e` is a pool/cardinality error
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=e.msg
    rethrow()
end

# ✓ after — one accessor, every subtype
try
    M.Result.objects.filter("driverid__surname" => "Senna").update("points" => 25)
catch e
    e isa PormGError && @error "write failed" msg=error_message(e) type=typeof(e)
    rethrow()
end
```

And, optionally, collapse a two-branch pool catch:

```julia
# ✗ before
catch e
    (e isa PoolTimeoutError || e isa PoolConnectError) && back_off()

# ✓ after
catch e
    e isa PoolError && back_off()
```
