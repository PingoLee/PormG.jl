---
applyTo: "**"
---
# Project general coding proposals
- Build a Julia ORM inspired by Django ORM, focusing on providing a familiar, expressive, and productive interface for database operations.
- Ensure the ORM supports common database operations like filtering, ordering, and value selection.

# Project general coding standards
- Basic usage:
  ```julia
  # Basic filter by single field
  query = M.Status |> object;
  query.filter("status" => "Engine");
  df = query |> DataFrame

  1×2 DataFrame
  Row │ statusid  status  
      │ Int64?    String? 
  ─────┼───────────────────
    1 │        5  Engine
  ```


## Error handling
- Always log errors with contextual information
- Use colored output for error messages in CLI tools for better visibility
