"""
Unit coverage for the introspection primary-key attribute guards
(`convertSQLToModel(row::DataFrameRow)`, the PostgreSQL path).

A primary-key column is mapped to an `IDField`, which has **no** `max_length`/`max_digits`
field. Before the guard, a natural primary key (`VARCHAR(n) PRIMARY KEY`) or a numeric primary
key (`NUMERIC(p,s) PRIMARY KEY`) parsed a `max_length`/`max_digits` and then tried to assign it
onto the `IDField`, raising a `FieldError` that crashed the whole schema import.

`convertSQLToModel(row)` takes the introspected table metadata as a single `DataFrameRow`, so
this is fully hermetic — no live database. The fix adds
`&& hasfield(typeof(field), :max_length)` / `:max_digits`, so the import must succeed and the
PK must map to an `IDField`, while a normal sized column still keeps its `max_length`.
"""

using Test
using DataFrames
using PormG
using PormG.Migrations: convertSQLToModel

# One-row "introspection result" carrying the columns convertSQLToModel(row) reads. The optional
# FK/index columns are `missing`, matching a table that has none.
function _introspection_row(; table_name, columns, primary_keys)
  df = DataFrame(
    table_name              = [table_name],
    columns                 = [columns],
    primary_keys            = [primary_keys],
    foreign_keys            = [missing],
    foreign_tables          = [missing],
    referenced_primary_keys = [missing],
    index_columns           = [missing],
    index_names             = [missing],
  )
  return df[1, :]
end

@testset "Introspection PK attribute guards (convertSQLToModel)" begin

  # ───────────────────────────────────────────────────────────────────────────
  # 1. VARCHAR primary key + a normal sized column. Pre-fix: assigning max_length
  #    onto the IDField threw FieldError. Post-fix: PK → IDField (no max_length),
  #    while the normal column still keeps its max_length (guard didn't over-suppress).
  # ───────────────────────────────────────────────────────────────────────────
  @testset "VARCHAR(n) PRIMARY KEY does not crash; PK maps to IDField" begin
    row = _introspection_row(
      table_name   = "natural_key_tbl",
      columns      = "code varchar(20) NOT NULL, name varchar(100)",
      primary_keys = "code",
    )
    model = convertSQLToModel(row)   # must not throw

    @test model.fields["code"] isa PormG.Models.sIDField
    @test model.fields["code"].type == "BIGINT"
    @test !hasfield(typeof(model.fields["code"]), :max_length)   # the attribute the old code tried to set
    @test model.fields["name"].max_length == 100                 # normal column unaffected
  end

  # ───────────────────────────────────────────────────────────────────────────
  # 2. NUMERIC(p,s) primary key. Pre-fix: assigning max_digits onto the IDField threw.
  # ───────────────────────────────────────────────────────────────────────────
  @testset "NUMERIC(p,s) PRIMARY KEY does not crash (max_digits guard)" begin
    row = _introspection_row(
      table_name   = "numeric_key_tbl",
      columns      = "id numeric(10,0) NOT NULL",
      primary_keys = "id",
    )
    model = convertSQLToModel(row)   # must not throw

    @test model.fields["id"] isa PormG.Models.sIDField
    @test !hasfield(typeof(model.fields["id"]), :max_digits)
  end

end
