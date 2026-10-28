## A projected `Cast` to an array reads back as a `Vector`, as an `ArrayField` column does (#1439)

- **Version**: Unreleased
- **PormG ref**: #1439 ; `src/querybuilder/expression_kind.jl` (`_declared_kind`), `src/column_ir.jl` (`_ArrayElementKind`)
- **Recorded**: 2026-10-28
- **Severity**: behavior change, PostgreSQL only. A value projected through a cast to a text, boolean, date, timestamp or uuid array now reads back as a `Vector`, where LibPQ returned the `{…}` literal as a `String`. A cast to an integer, float or numeric array reads the same values as before, now as the 1-based `Vector{T}` an `ArrayField` column reads.

### What changed

A cast to an array type recorded no read type, so the value arrived as the driver handed it over. On
LibPQ that depended on the element: LibPQ parses integer, float and numeric arrays itself (into a
`Vector{Union{Missing, T}}`, or an offset-indexed array when the lower bound is not 1), and returns
every other array as its text, so `Cast(x, "varchar[]")` came back as `"{SOFT,MEDIUM}"`. Postgres.jl
returned a typed `Vector` or a `Vector{Any}`. An `ArrayField` column of the same type already read
back as a 1-based `Vector{T}` on both drivers.

A cast to a one-dimensional array of an element an `ArrayField` can declare (`varchar`, `text`,
`integer`, `bigint`, `float`, `numeric`, `boolean`, `date`, `timestamp`, `timestamptz`, `uuid`) now
reads back as the `Vector` an `ArrayField` of that element reads as, on LibPQ and on Postgres.jl. That
includes a field object (`Cast(x, ArrayField(CharField(max_length = 3)))`, #1438), an `output_field`
naming an array, and a function whose value is its operand's (`Max(Cast(x, "date[]"))`). Any other
array (`smallint[]`, `real[]`, `inet[]`, `integer[][]`) arrives as the driver hands it over, as
before. SQLite and MySQL have no arrays and refuse the cast, as before.

Examples on `Race_strategy`, whose `tyre_compounds` is an `ArrayField(CharField(max_length = 12))`,
on LibPQ:

| expression | before | now |
|---|---|---|
| `Cast("tyre_compounds", "varchar[]")` | `"{SOFT,MEDIUM}"` (`String`) | `["SOFT", "MEDIUM"]` (`Vector`) |
| `Cast(Value("{SOFT,MEDIUM}"), "text[]")` | `"{SOFT,MEDIUM}"` (`String`) | `["SOFT", "MEDIUM"]` (`Vector`) |
| `Cast("tyre_compounds", ArrayField(CharField(max_length = 3)))` | `"{SOF,MED}"` (`String`) | `["SOF", "MED"]` (`Vector`) |
| `Cast("pit_laps", "integer[]")` | `[12, 30]` (`Vector{Union{Missing, Int32}}`) | `[12, 30]` (`Vector{Int32}`) |
| `Cast(x, "smallint[]")` | as the driver returns it | unchanged |

### Who this affects

Code on LibPQ that projects a cast to a text, boolean, date, timestamp or uuid array and parses the
`{…}` text itself. Code that checks the element type of a cast to an integer, float or numeric array
(`eltype`, `isa`): the values are equal, the container is the one an `ArrayField` column reads. On
Postgres.jl, a value that came back as a `Vector{Any}` now has its element type.

### How to find the calls to migrate

```bash
grep -rnE 'Cast\(|output_field' --include=*.jl src/ test/ | grep -E '\[\]"|ArrayField\('
```

### Migrate your app

```julia
# ✗ before — the literal, parsed by hand
q = M.Race_strategy.objects
q.values("compounds" => Cast("tyre_compounds", "varchar[]"))
compounds = [split(strip(r["compounds"], ['{', '}']), ',') for r in q.list()]

# ✓ after — already a Vector
q = M.Race_strategy.objects
q.values("compounds" => Cast("tyre_compounds", "varchar[]"))
compounds = [r["compounds"] for r in q.list()]
```

To keep the text, cast to it: `Cast(Cast("tyre_compounds", "varchar[]"), "text")` reads `"{SOFT,MEDIUM}"`.
