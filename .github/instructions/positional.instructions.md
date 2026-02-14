# Task: Refactor QueryBuilder Parameter Handling (Contextual Buckets Strategy)

**Context:**
I am working on `PormG.jl`, a Julia ORM inspired by Django. Currently, the query builder generates PostgreSQL parameters (numbered `$1`, `$2`...) sequentially using a global counter. I need to implement support for MySQL/MariaDB which uses purely positional parameters (`?`).

**The Problem:**
Code execution order does not always match SQL string order.
- *Execution:* `Filter` (WHERE) is processed *before* `Join` logic to determine necessary joins.
- *SQL Output:* `JOIN` clauses appear *before* `WHERE` clauses.
For PostgreSQL (`$N`), this order doesn't matter. For MySQL (`?`), this breaks the query because the first parameter injected (from WHERE) would be placed in the JOIN slot in the final SQL.

**The Goal:**
Refactor `src/querybuilder/parameters.jl` (and related files) to implement a **"Contextual Bucket"** strategy using Multiple Dispatch.

**Requirements:**

1.  **Abstract Base Type:**
    Define an abstract type `AbstractPormGParam`.

2.  **PostgreSQL Implementation (Keep mostly as is):**
    - Struct `PormGPostgresParam <: AbstractPormGParam`.
    - Logic: Stores a single linear vector of values and a counter.
    - `add_parameter!`: Pushes to vector, increments count, returns `"$N"`. Ignores context.

3.  **MySQL/SQLite Implementation (The New Bucket Strategy):**
    - Struct `PormGPositionalParam <: AbstractPormGParam`.
    - **Fields:** distinct vectors for each SQL section: `cte_params`, `select_params`, `join_params`, `where_params`, `having_params`.
    - **State:** A field `current_context::Symbol` (default to `:where` or similar).
    - `add_parameter!`:
        - Checks `current_context`.
        - Pushes the value into the corresponding vector (e.g., if `:join`, push to `join_params`).
        - Returns `"?"`.
    - `set_context!(params, context::Symbol)`: Updates the `current_context`.

4.  **Helper Functions:**
    - `get_final_parameters(p::PormGPostgresParam)`: Returns the single vector.
    - `get_final_parameters(p::PormGPositionalParam)`: Returns the concatenation of vectors in standard SQL order: `vcat(p.cte_params, p.select_params, p.join_params, p.where_params, p.having_params)`.

5.  **Handling Subqueries & CTEs:**
    - Subqueries must allow injecting parameters into the *parent's* current bucket. Since `add_parameter!` handles the push logic based on the parent's state, this should work automatically if the parent's parameter object is passed down.

**Implementation Plan:**
Please rewrite/update `src/querybuilder/parameters.jl` with these structs and functions. Ensure the existing `PormGPostgresParam` logic remains compatible with the current codebase but fits this new abstract interface.