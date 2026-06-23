# PormG Test Writing Standard

Canonical conventions for `@testset` blocks across PormG unit and integration tests. The subsystem skills link here instead of restating the standard — edit it **once, here**.

## Block headers

Use a standardized header comment above every `@testset` block:

```julia
# ─────────────────────────────────────────────────────────────────────────────
# [Feature/Area]: [Specific scenario being tested]
# [1-2 sentences explaining what the test verifies, the expected SQL shape,
# and why the behavior matters to users or future maintainers]
# ─────────────────────────────────────────────────────────────────────────────
@testset "..." begin
```

## Conventions

- Heavily comment the test logic within the block.
- Prefer isolated setup with explicit cleanup over hidden shared state.
- Do not weaken model/field contracts to accommodate dirty fixtures — normalize fixtures in the import/setup layer instead.
