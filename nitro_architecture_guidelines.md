# PormG.jl Development Guidelines for Nitro.jl Integration

As an ORM being developed alongside the **Nitro.jl** web framework, **PormG.jl** must align perfectly with Nitro's core philosophy: scaleable, strictly typed, async-first, and highly decoupled. 

This document outlines the architectural requirements for PormG.jl to be fully compatible and highly useful for Nitro.jl, alongside an analysis of its current status and suggestions for improvement.

---

## 1. Concurrency and Async-First I/O

**Nitro.jl Philosophy:**
Nitro handles every request in parallel using `Threads.@spawn`. It relies on Julia's async I/O scheduler to switch tasks when waiting for the database or network, maximizing throughput without heavy OS-level multi-processing.

**PormG.jl Requirements:**
- **Never Block the Scheduler:** Database calls must yield to the Julia scheduler while waiting for the DB response.
- **Thread-safe Connection Pooling:** The pool must safely hand out connections to hundreds of concurrent `Threads.@spawn` tasks.
- **Thread-safe Global State:** Any loaded models, registries, or caches must be protected by data races (e.g., using `ReentrantLock` or `ConcurrentDict`).

**Current Status:**
- ✅ **Excellent Start:** `ConnectionPool.jl` implements `ReentrantLock` for both PostgreSQL and SQLite pools.
- ✅ **Async Foundation:** `fetch_async` correctly utilizes `LibPQ.async_execute` and `Threads.@spawn` for SQLite, yielding to the scheduler.
- ✅ **Transaction Awareness:** `FetchTask` handles connection lifecycles well natively.

**Improvement Suggestions:**
- **Make Async Transparent:** Ensure the standard `QueryBuilder` API (`list`, `inspect_query`, etc.) automatically routes through the async-yielding execution path so users don't have to manually deal with `FetchTask` unless doing advanced parallel queries.
- **Stress-Test Locks:** Ensure that the locks in `ConnectionPool.jl` do not become a bottleneck under high contention (e.g., thousands of simultaneous requests). Consider lock-free data structures or partitioned pools if contention is high.

---

## 2. Type Stability and Performance

**Nitro.jl Philosophy:**
Type stability is crucial for high-throughput HTTP handling. Nitro actively avoids `Any` types in internal request pipelines and specifies using `Nullable{T}` over `Union{T, Missing}` for internal consistency.

**PormG.jl Requirements:**
- **Strictly Typed Returns:** ORM queries must return strictly typed structs representing models, rather than `Dict{String, Any}` or generic `Tables.rowtable` containing `Any`.
- **Avoid Dynamic Dispatch:** Minimize the reliance on `Any` when building queries. The query builder should use parametrized types.

**Current Status:**
- ⚠️ **Needs Attention:** The current `fetch()` implementation naturally returns `Tables.rowtable` or `DataFrame` rows, which can easily introduce type instability if not mapped to a concrete `Model` struct immediately.
- ⚠️ **Nullable vs Missing:** Standard Julia databases return `Missing` for NULLs. PormG needs a deliberate strategy to handle this map, specifically respecting the project preference to wrap types carefully if needed.

**Improvement Suggestions:**
- **Strongly Typed Models:** Ensure the `Models.Model(...)` definitions generate concrete Julia `struct` types under the hood. When a query is finalized (e.g., `list(query)`), map the raw DB row directly into `Vector{YourModel}` as close to the driver layer as possible.
- **QueryBuilder Type Enforcement:** Enforce strict typing on `PormGParam` and parameter bindings to avoid `Vector{Any}` allocations where possible.

---

## 3. Strict Decoupling

**Nitro.jl Philosophy:**
Nitro.jl is database-agnostic. PormG.jl is treated as a **Weak Dependency**. The core web server logic in `Nitro.jl/src/` will NEVER import PormG. Integration happens exclusively in `Nitro.jl/ext/NitroPormGExt/`.

**PormG.jl Requirements:**
- **Zero Web Knowledge:** PormG.jl must never import HTTP headers, route components, request objects, or JSON serialization packages specifically targeting Nitro. 
- **Standalone:** It must function completely independently in a REPL, background script, or alternative framework.

**Current Status:**
- ✅ **Clean:** Looking at `PormG.jl`, it remains focused on SQL dialect generation, migrations, and pooling. It does not import Genie or Nitro web components directly in its core.

**Improvement Suggestions:**
- **Keep it Pure:** Continue this trend. Do not add convenience methods like `render_to_response(query)`. If Nitro needs special JSON serialization for PormG models (e.g., nested relations), extend `JSON3` definitions within Nitro's `NitroPormGExt`, NOT in PormG.

---

## 4. Ergonomics (Django-Style)

**Nitro.jl Philosophy:**
Ergonomics matter. Nitro enforces Django-style routing (`urlpatterns`). PormG similarly advertises a Django-inspired approach to querying (e.g., `Model.objects.filter(...)`).

**PormG.jl Requirements:**
- **Chaining:** Querysets must be lazily evaluated and fully chainable.
- **Intuitive Migrations:** Define models in code, auto-generate migrations (schema diffing).

**Current Status:**
- ✅ **Syntax:** The `filter("name"=>"Alice").order_by("-age")` syntax is very close to the Django feel.
- 🚧 **Migrations:** `Migrations.jl` exists, but robust schema diffing in Julia is generally an ongoing challenge.

**Improvement Suggestions:**
- **Lazy Evaluation:** Ensure that calling `.filter()` or `.order_by()` simply clones and mutates a `QuerySet` struct without executing the query. Execution should ONLY happen upon iteration, `.list()`, `.first()`, or `.count()`.
- **Relation Navigation:** A massive part of Django's power is `Model.objects.filter(related__field="value")`. Implementing auto-joining via double-underscore (`__`) or similar semantics will make it exceptionally powerful for Nitro.jl developers.

---

## Summary Action Plan for PormG.jl

1. **Verify Map to Strongly Typed Structs:** Audit the result mappings in `QueryBuilder.jl` to ensure queries yield strictly typed collections (e.g., `Vector{User}`) instead of untyped tables, optimizing for Nitro's type-stability requirement.
2. **Double-check Transaction isolation:** Ensure `get_tx_connection()` is completely task-local (`task_local_storage()`) so that concurrent Nitro `@spawn` HTTP requests do not accidentally share active transactions.
3. **Write Unit Tests alongside `Threads.@spawn`:** Create test cases in PormG that intentionally fire 10,000 parallel `Threads.@spawn` queries to identify any hidden race conditions in `ConnectionPool.jl` or memory-leak behaviors.
