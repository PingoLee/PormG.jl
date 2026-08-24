# PormG Usage — Field & Model Definition Reference

Supporting file for [`SKILL.md`](SKILL.md). Read this when **defining models** or choosing a field type. For setup, querying, and aggregations see `SKILL.md`; for migrations, writes, and bulk ops see [`writing.md`](writing.md).

## Field Types Reference

| Field | DB Type (PG/SQLite) | Key Parameters |
| :--- | :--- | :--- |
| `IDField()` | `BIGINT IDENTITY` / `INTEGER PK` | `generated_always` |
| `CharField(max_length)` | `VARCHAR(n)` | `max_length`, `choices`, `default` |
| `TextField()` | `TEXT` | `null`, `blank` |
| `EmailField()` | `VARCHAR` | `max_length=254` |
| `URLField()` | `VARCHAR` | `max_length=200` |
| `SlugField()` | `VARCHAR` | `max_length=50`, defaults `db_index=true` |
| `UUIDField()` | `UUID` / `TEXT` | `auto_add=true` for auto-generation |
| `IntegerField()` | `INTEGER` | `default`, `null` |
| `BigIntegerField()` | `BIGINT` | — |
| `FloatField()` | `DOUBLE PRECISION` | rejects `Inf`, `NaN` |
| `DecimalField(...)` | `NUMERIC(p,s)` | `max_digits`, `decimal_places` |
| `BooleanField()` | `BOOLEAN` | `default` |
| `DateField()` | `DATE` | `auto_now_add`, `auto_now` |
| `DateTimeField()` | `TIMESTAMPTZ` | `auto_now_add`, `auto_now`, `type="TIMESTAMP"` |
| `TimeField()` | `TIME` | — |
| `DurationField()` | `INTERVAL` | — |
| `JSONField()` | `JSONB` / `TEXT` | accepts `Dict`, `Vector`, scalars |
| `ForeignKey(model)` | `BIGINT` + FK constraint | `on_delete`, `related_name` |
| `OneToOneField(model)` | `BIGINT` UNIQUE + FK | `on_delete` |
| `PasswordField()` | `VARCHAR(128)` | `auto_hash=true` — never stores plaintext |
| `ImageField()` | `VARCHAR` | stores file path |
| `BinaryField()` | `BYTEA` / `BLOB` | `Vector{UInt8}` in and out; `max_length` is a **byte** bound |

**Common parameters (all fields):** `null=false`, `blank=false`, `unique=false`, `default=nothing`, `db_index=false`, `db_column=nothing`, `editable=true`

**`on_delete` options:** `"CASCADE"`, `"RESTRICT"`, `"PROTECT"`, `"SET_NULL"`, `"SET_DEFAULT"`, `"DO_NOTHING"`
