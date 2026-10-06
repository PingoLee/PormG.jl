# PormG Field Types Reference

This comprehensive guide covers all field types available in PormG, inspired by Django ORM but optimized for Julia. Each field type maps to appropriate data types in PostgreSQL or SQLite and provides validation, constraints, and formatting capabilities.

## Naming Conventions and Considerations

### Field Naming Rules
- **Recommended house style: lowercase snake_case** — `username`, `email`, `created_at`, `first_name`.
  PormG's own models and examples follow this, and it is the convention to prefer for new schemas.
- **Field-name case is preserved, not folded.** Whatever case you declare is the field's identity
  *and* its database column. A field declared `driverId` registers as `driverId` and maps to the
  column `"driverId"`. This is what lets PormG faithfully target mixed-case / uppercase columns in
  existing (e.g. legacy Django) schemas. Field lookups are **case-sensitive** — query a field by the
  exact case you declared it.
- **Never use double underscores (`__`)** in field names or table names — `__` is the lookup
  separator (`driverid__surname`), so a field spelled with one would be unaddressable.
- **A field name may not start with an underscore.** `_end = CharField()` raises `ModelDefinitionError`.
  Name a column that is a Julia keyword — or that genuinely begins with an underscore — with
  [`db_column`](#Database-Column-Mapping) instead:
  ```julia
  end_ = Models.CharField(db_column = "end")     # field `end_` → column "end"
  id2  = Models.CharField(db_column = "_id")     # field `id2`  → column "_id"
  ```
  A single leading underscore used to be an escape hatch that PormG silently stripped (`_end`
  declared the column `end`). It was retired in #317: it encoded the Julia identity and the SQL
  identity in one string, where `db_column` states them separately and composes with `db_table`.
  `id` needs nothing special — it is an ordinary Julia identifier.

### Model Naming Rules
- **Use snake_case with capitalized first letter**: `Driver`, `Constructor`, `Pit_stop`
- **Use singular nouns**: `Driver` not `Drivers`, `Circuit` not `Circuits`
- **Be descriptive and clear**: `Driver_profile`, `Part_category`, `Race_result`

### Database Column Mapping
- **By default, column names follow the field name verbatim, with case preserved**: a field declared
  `firstName` becomes the column `"firstName"`; declare `first_name` to get `first_name`.
- **The house style is lowercase snake_case** — prefer it for new schemas; reserve mixed-case
  declarations for faithfully mapping existing columns you don't control.
- **`db_column` maps a field to a differently-named column** and is authoritative across DDL,
  queries, and migrations (#50) — e.g. `chassis = CharField(db_column="chassis_code")` keeps the field
  `chassis` but targets the column `"chassis_code"`. Supported on all field types except `ManyToManyField`;
  see [Schema Conventions](schema_conventions.md).
- **`db_table` is the same idea one level up** — a *model* option, not a field one, mapping a model to
  a differently-named (and, unlike a model name, arbitrarily-cased) table: `Models.Model("driver_profile",
  db_table = "Driver_Profile_Legacy", …)`. Also authoritative across DDL, queries, and migrations (#59);
  see [Pinning an explicit table name](schema_conventions.md#Pinning-an-explicit-table-name-with-db_table).

### Examples of Good Naming

```julia
# ✅ Good field naming
Team_member = Models.Model(
    id = Models.IDField(),                      # Plain identifier — no prefix needed
    username = Models.CharField(max_length=30), # Lowercase
    first_name = Models.CharField(max_length=50), # Snake_case
    email_address = Models.EmailField(),        # Descriptive
    is_active = Models.BooleanField(),          # Boolean prefix
    created_at = Models.DateTimeField(),        # Timestamp suffix
    birth_date = Models.DateField()             # Clear purpose
)

# ✅ Good model naming
Driver_profile = Models.Model(...)    # snake_case with capital first letter
Part_category = Models.Model(...)     # Clear relationship
Race_result = Models.Model(...)       # Descriptive compound name
```

### Examples to Avoid

```julia
# ❌ Bad naming practices
driver = Models.Model(                  # Should be capitalized
    ID = Models.IDField(),              # Should be id — house style is lowercase
    firstName = Models.CharField(),     # Should be first_name
    Nationality__Code = Models.CharField(), # Never use __ (the lookup separator)
    _end = Models.DateField(),          # Retired escape hatch — raises ModelDefinitionError
    end = Models.DateField()            # Julia syntax error: `end` is a keyword
)

# ✅ the reserved-word column, said properly
driver = Models.Model("driver",
    id   = Models.IDField(),
    end_ = Models.DateField(db_column = "end")   # field `end_` → column "end"
)
```


---

## Primary Key Fields

### IDField()

**Purpose**: Auto-incrementing 64-bit integer primary key.

**Database Type**: 
- **PostgreSQL**: `BIGINT` with `GENERATED AS IDENTITY`
- **SQLite**: `INTEGER PRIMARY KEY AUTOINCREMENT`

**Use Cases**: Large-scale applications, future-proof primary keys, modern PostgreSQL features.

```julia
# Basic usage (most common)
Driver = Models.Model(
  id = Models.IDField(),
  surname = Models.CharField(max_length=50)
)

# With GENERATED ALWAYS (stricter identity)
Result = Models.Model(
  id = Models.IDField(generated_always=true),
  points = Models.DecimalField(max_digits=10, decimal_places=2)
)
```

**Key Parameters**:
- `generated_always::Bool = false`: Use GENERATED ALWAYS AS IDENTITY (stricter mode)
- `primary_key::Bool = true`: Always true for IDField
- `auto_increment::Bool = true`: Always true for IDField

**Range**: -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807

### AutoField() — retired

`AutoField` was removed in favour of `IDField`. Calling `Models.AutoField()` raises
`FieldValidationError` naming the replacement.

It was documented as a 32-bit `INTEGER SERIAL` key and never was one: the DDL renderer had no branch
for it, so it emitted a **`TEXT`** column on both backends with no sequence, identity or
`AUTOINCREMENT` behind it. A model keyed on it had a text primary key the database never populated, and
`makemigrations` could never converge. An app that supplied its own key values would have worked;
one that relied on the documented auto-increment never did.

Use `IDField` for every auto-incrementing integer key:

```julia
Part_category = Models.Model(
    id   = Models.IDField(),
    name = Models.CharField(max_length=100)
)
```

`IDField` is BIGINT rather than INTEGER. An existing PostgreSQL column that really is `integer` is
**not** re-typed — PormG compares the field's declared type, not the rendered width. It is not quite
"nothing changes", though: a key column that is not a PostgreSQL IDENTITY column attracts an
`ADD GENERATED BY DEFAULT AS IDENTITY` (a pre-existing `:generated` mismatch, not introduced by the
retirement), and a column a real `AutoField` created is `text`. PostgreSQL refuses that as an
identity column, so the migration errors — noisy but safe. **SQLite does not refuse it**: it rebuilds
the table into `INTEGER PRIMARY KEY AUTOINCREMENT`, which aborts on a non-numeric key and silently
renumbers a zero-padded one (`'0042'` becomes `42`). Re-type such a column by hand. Run `dry_run()`
before `migrate()`; the
[Upgrading guide](https://pingolee.github.io/PormG.jl/dev/upgrading/) has the details.

!!! info "Why not simply fix it?"
    Repairing it would have bought a four-byte-narrower key on one backend — SQLite's
    `INTEGER PRIMARY KEY` is a 64-bit rowid alias, so the two were already physically identical
    there — while keeping a second integer key type that introspection cannot tell apart from
    `IDField`, which is its own class of never-converging migration. See the *Upgrading* guide.

---

## UUID Fields

### UUIDField()

**Purpose**: For storing Universally Unique Identifiers (UUIDs).

**Database Type**: 
- **PostgreSQL**: `UUID` (Native type)
- **SQLite**: `TEXT`

**Use Cases**: Distributed systems, secure primary keys, session tokens, unique object identifiers.

```julia
# UUID as a primary key
Api_session = Models.Model(
  id = Models.UUIDField(primary_key=true, auto_add=true),
  team_member_id = Models.ForeignKey("Team_member")
)

# UUID as a unique token
Access_token = Models.Model(
  id = Models.IDField(),
  team_member = Models.ForeignKey("Team_member"),
  token = Models.UUIDField(unique=true, auto_add=true),
  created_at = Models.DateTimeField(auto_now_add=true)
)
```

**Key Parameters**:
- `auto_add::Bool = false`: If true, automatically generates a `uuid4()` on the application side when creating a new record without a provided value.
- `primary_key::Bool = false`: Can be used as a primary key.
- `default::Union{String, Nothing} = nothing`: A default UUID string.
- `unique::Bool = false`: Enforce uniqueness.

**Querying**: equality and `@in` take a whole UUID in any case (`"550E8400-…"` matches
`"550e8400-…"`); a malformed one raises `FilterError`. The pattern lookups (`@contains`, `@startswith`,
`@endswith`, their `i`/`n` variants and `@regex`) take a **fragment** and match it against the UUID's
lowercase, hyphenated text, the form both engines store or print. On PostgreSQL the column is read as
`CAST(token AS text)`.

```julia
# Tokens issued from the same prefix, hyphen included.
Access_token.objects.filter("token__@startswith" => "550e8400-e29b").values("id").list()

# The text is lowercase: an uppercase fragment needs the case-insensitive form.
Access_token.objects.filter("token__@icontains" => "E29B").values("id").list()
```

The fragment is matched as written, hyphens included: `"550e8400e29b"` does not match. This is what
Django does on PostgreSQL; its hyphen-insensitive form is only for databases that store a UUID as 32 hex
digits, which PormG never does.

---

## Network Address Fields

Two fields hold IP addresses, as PostgreSQL's native network types. The first is Django's field of
the same name, so a Django project imports into it unchanged; the second follows django-netfields.

| Field | Holds | PostgreSQL | SQLite |
|---|---|---|---|
| `GenericIPAddressField()` | one host address, IPv4 or IPv6 | `inet` | not supported |
| `CIDRField()` | one network in CIDR notation | `cidr` | not supported |

**PostgreSQL only.** SQLite has no type that stores an address with these semantics: it cannot
compare by network, and it would store each spelling of an address as different text. PormG refuses
rather than emulates: on SQLite, `makemigrations` raises `BackendCapabilityError` for a model that
declares either field. To keep a model on SQLite, declare the column as a `CharField` or `TextField`;
it then holds whatever text you write.

Both fields read back as a `String`. On write they accept a `String` or a `Sockets.IPv4` /
`Sockets.IPv6`. PormG validates the value before it reaches the server, and writes it in the text
PostgreSQL prints for it. IPv6 is compressed and lower-cased, and an IPv4-mapped address keeps its
dotted tail:

| You write | Stored and read back as |
|---|---|
| `"2001:0DB8:0000:0000:0000:0000:0000:0001"` | `"2001:db8::1"` |
| `"0:0:0:0:0:ffff:a00:1"` | `"::ffff:10.0.0.1"` |
| `" 10.0.0.1 "` | `"10.0.0.1"` |
| `"10.20.0.0/16"` (in a `CIDRField`) | `"10.20.0.0/16"` |
| `"10.20.0.1"` (in a `CIDRField`) | `"10.20.0.1/32"` |

The normalization matters for `default=`. PostgreSQL stores a column default in its printed form, so
a declared default is normalized the same way and compares equal to it. Otherwise the next
`makemigrations` would plan a default change.

PormG's parser is **stricter than PostgreSQL's**. It refuses the classful short forms (`"10.1"`), an
octet with a leading zero (`"010.0.0.1"`), an IPv6 zone id (`"fe80::1%eth0"`) and an empty string.
Store `nothing` in a `null = true` field instead of an empty string.

### GenericIPAddressField()

**Purpose**: One IPv4 or IPv6 host address: the address a pit-wall client connected from, or the IP
of a timing relay.

```julia
Pit_wall_session = Models.Model("pit_wall_session",
  id         = Models.IDField(),
  team       = Models.CharField(max_length = 100),
  client_ip  = Models.GenericIPAddressField(),
  relay_ip   = Models.GenericIPAddressField(protocol = "IPv4", null = true),
  mapped_ip  = Models.GenericIPAddressField(unpack_ipv4 = true, null = true),
  garage_lan = Models.CIDRField(null = true),
)
```

**Key Parameters**:
- `protocol::String = "both"`: `"both"`, `"IPv4"` or `"IPv6"`, in any case. A write of the other
  family raises `InvalidValueError`. An IPv4-mapped value (`::ffff:10.0.0.1`) counts as IPv6.
- `unpack_ipv4::Bool = false`: store an IPv4-mapped address as plain IPv4 (`::ffff:10.0.0.1` becomes
  `10.0.0.1`), as Django does. It is only allowed with `protocol = "both"`; any other combination
  raises `FieldValidationError` when the model is defined.
- `default`: normalized like a written value. An invalid default raises `FieldValidationError` when
  the model is defined.

**A host, not a network.** A value with a `/prefix` (`"10.0.0.0/8"`) raises `InvalidValueError`,
which is Django's rule. Store a network in a `CIDRField`. A PostgreSQL `inet` column can hold a
masked value that some other client wrote; PormG still reads it back as a `String`, but cannot write
it through this field.

### CIDRField()

**Purpose**: One network in CIDR notation, for example the subnet a team's garage equipment sits on.

The value is always stored with its prefix. A value without one is a full-width network, so
`"10.20.0.1"` is stored as `"10.20.0.1/32"`. A value with bits set to the right of its mask raises
`InvalidValueError`, as PostgreSQL refuses it: `"10.20.0.1/16"` is a host inside `10.20.0.0/16`, not a
network, and the message names `10.20.0.0/16`.

### Querying network fields

```julia
# Equality and @in compare natively, so any spelling of the address matches.
M.Pit_wall_session.objects.
  filter("client_ip" => "2001:0DB8::0001").
  values("team", "client_ip").
  list()

M.Pit_wall_session.objects.
  filter("garage_lan__@in" => ["10.20.0.0/16", "10.21.0.0/16"]).
  values("team").
  list()

# Pattern lookups read the printed text: HOST(column) for inet, the text of a cidr.
M.Pit_wall_session.objects.
  filter("client_ip__@startswith" => "10.20.").
  values("team").
  list()
```

- **Pattern lookups** (`@contains`, `@startswith`, `@endswith`, their `i`/`n` variants, and `@regex`)
  take a fragment of the text, such as `"10.20."` or `"/16"`. The fragment is bound as plain text, not
  validated as an address.
- **Ordering lookups** (`@gt`, `@gte`, `@lt`, `@lte`, `@range`) and `order_by` compare by network, as
  PostgreSQL does: `10.0.0.9` comes before `10.0.0.10`.
- A filter value may be a `Sockets.IPv4` / `Sockets.IPv6` too; a value that is not a valid address
  raises `FilterError`.
- A **projection alias** over a network column filters the same way. A pattern lookup on
  `"top_ip" => Max("client_ip")` reads `HOST(MAX(…))`, and the fragment is bound as text.
- `Value(ip"…")` binds on PostgreSQL as an `inet`, in the text PostgreSQL prints for it
  (`::ffff:10.0.0.1`). On SQLite it raises `InvalidValueError`.

```julia
# The highest address each team used, kept only when it is on the 10.20.x.x garage network.
M.Pit_wall_session.objects.
  values("team", "top_ip" => Max("client_ip")).
  filter("top_ip__@startswith" => "10.20.").
  list()
```

### Network containment lookups

These lookups use PostgreSQL's network operators, the main reason to store an address as `inet`
rather than text. The names follow django-netfields. The `net_` prefix keeps them apart from
`@contains`, which is a text match.

| Lookup | PostgreSQL | True when the column… |
|---|---|---|
| `@net_contained` | `col << value` | is inside the network, and not equal to it |
| `@net_contained_or_equal` | `col <<= value` | is inside the network, or equal to it |
| `@net_contains` | `col >> value` | contains the value, and is not equal to it |
| `@net_contains_or_equals` | `col >>= value` | contains the value, or is equal to it |
| `@net_overlaps` | `col && value` | contains the value, or is inside it |
| `@family` | `family(col) = value` | is IPv4 (`4`) or IPv6 (`6`) |
| `@prefixlen` | `masklen(col) = value` | has this prefix length (`/16` is `16`) |

```julia
# The pit-wall clients connected from inside the 10.20.0.0/16 garage subnet.
M.Pit_wall_session.objects.
  filter("client_ip__@net_contained" => "10.20.0.0/16").
  values("team", "client_ip").
  list()

# The sessions whose garage network holds a given relay address.
M.Pit_wall_session.objects.
  filter("garage_lan__@net_contains" => "10.20.0.9").
  values("team").
  list()

# A column on the right: each client inside its own team's garage network.
M.Pit_wall_session.objects.
  filter("client_ip__@net_contained" => F("garage_lan")).
  values("team", "client_ip").
  list()
```

- The **value of the five containment lookups** is one address or network, as a `String` or a
  `Sockets.IPv4` / `Sockets.IPv6`. It may carry a prefix, and its host bits may be set:
  `"10.20.0.9/16"` means the network `10.20.0.0/16`, as it does in PostgreSQL. It works on a
  `GenericIPAddressField` and a `CIDRField` alike. A value that is not an address raises
  `FilterError`.
- A **column on the right** (`F("garage_lan")`) is compared directly.
- `@family` takes `4` or `6`, and `@prefixlen` a whole number from `0` to `128`. Anything else raises
  `FilterError`.
- These lookups work on a network column only: the model's own, one reached through a relation
  (`"session__client_ip__@net_contained"`), or a CTE or `cjoin_on` column over one. On any other
  column, on a projection alias, or with a list of values, they raise `FilterError`.
- **PostgreSQL only.** On SQLite, a lookup that is otherwise valid raises `BackendCapabilityError`,
  as the fields themselves do. The value checks above come first, so an invalid one still raises
  `FilterError` there.

---

## Array Fields

`ArrayField` holds a one-dimensional PostgreSQL array of another field's values. It is Django's
`ArrayField`, from `django.contrib.postgres.fields`.

| Field | Holds | PostgreSQL | SQLite |
|---|---|---|---|
| `ArrayField(base_field)` | a list of `base_field` values | the base type followed by `[]`, e.g. `integer[]` | not supported |

**PostgreSQL only.** SQLite has no array type, and PormG does not emulate one: on SQLite,
`makemigrations` raises `BackendCapabilityError` for a model that declares an `ArrayField`. To keep
a model on SQLite, put the elements in a related model with a `ForeignKey` per element.

### ArrayField(base_field)

**Purpose**: A short list of values that belongs to one row, such as the tyre compounds a team
brought to a race or the laps it pitted on.

```julia
Race_strategy = Models.Model("race_strategy",
  id             = Models.IDField(),
  raceid         = Models.ForeignKey("Race"),
  team           = Models.CharField(max_length = 100),
  tyre_compounds = Models.ArrayField(Models.CharField(max_length = 12); size = 6),
  pit_laps       = Models.ArrayField(Models.IntegerField(), default = Int[]),
  stint_targets  = Models.ArrayField(Models.DecimalField(max_digits = 7, decimal_places = 3), null = true),
)
```

**The element field** describes one element. It may be a `CharField`, `TextField`, `SlugField`,
`EmailField`, `URLField`, `IntegerField`, `BigIntegerField`, `FloatField`, `DecimalField`,
`BooleanField`, `DateField`, `DateTimeField` or `UUIDField`. Other types, and a nested
`ArrayField`, raise `FieldValidationError` when the model is defined.

It takes only `null` and its type modifiers (`max_length`, `max_digits`, `decimal_places`, `type`).
`null = true` allows a NULL **element**; without it a `nothing` or `missing` element is refused. A
column keyword (`unique`, `db_index`, `default`, `db_column`, …) belongs on the `ArrayField` itself,
and on the element field it raises `FieldValidationError`.

**Key Parameters**:
- `size::Union{Int, Nothing} = nothing`: the most elements a value may have. PormG checks it on every
  write. PostgreSQL neither enforces nor keeps a declared array size, so it is not part of the schema
  and changing it plans no migration.
- `null::Bool = false`: whether the whole column may be NULL. Elements follow the element field's `null`.
- `default`: a `Vector` or a `Tuple`. `default = Int[]` is Django's `default = list`. It is stored as
  PostgreSQL array text (`"{}"`, `"{1,2}"`), so there is no shared mutable vector between rows.
  A function is refused.

**Values.** Write a `Vector` (or a `Tuple`). Each element is validated as the element field
validates a value, so `ArrayField(CharField(max_length = 12))` refuses `["INTERMEDIATE!"]` with
`CharField`'s `max_length` message, naming the element. PostgreSQL's own array text (`"{1,2}"`) is
accepted too. A `default=` is held to the same element rules when the model is defined. In an
equality filter, pass a `Vector`, and write a NULL element there as `missing`.

A read returns a `Vector{T}`, where `T` is what a scalar read of the element field returns, on both
PostgreSQL drivers:

| Element field | Read back as |
|---|---|
| `CharField`, `TextField`, `SlugField`, `EmailField`, `URLField`, `UUIDField` | `Vector{String}` (a UUID as its lowercase text) |
| `IntegerField` / `BigIntegerField` | `Vector{Int32}` / `Vector{Int64}` |
| `FloatField` | `Vector{Float64}` |
| `DecimalField` | `Vector{Decimal}` |
| `BooleanField` | `Vector{Bool}` |
| `DateField` | `Vector{Date}` |
| `DateTimeField` | `Vector{ZonedDateTime}` in UTC (`Vector{DateTime}` for `type = "TIMESTAMP"`) |

A NULL element reads as `missing`, and the vector is then `Vector{Union{Missing, T}}`. Every array
reads 1-based, including one another client stored with a different lower bound.

### Querying array fields

```julia
# Equality compares the whole array, order included. The vector binds as ONE value.
M.Race_strategy.objects.
  filter("tyre_compounds" => ["SOFT", "MEDIUM"]).
  values("team").
  list()

# A strategy with no pit stop recorded yet.
M.Race_strategy.objects.
  filter("pit_laps" => Int[]).
  values("team").
  list()

M.Race_strategy.objects.
  filter("stint_targets__@isnull" => true).
  count()
```

- **Equality** compares the whole array, and `@isnull` the whole column. A vector on any other
  column still needs an operator (`"surname__@in" => [...]`).
- A membership list of whole arrays (`"pit_laps__@in" => [[12], [12, 30]]`) raises `FilterError`;
  combine the equalities with `Qor`.

#### Containment, overlap and length

```julia
# Teams that brought both dry compounds, in any order and among any others.
M.Race_strategy.objects.
  filter("tyre_compounds__@acontains" => ["SOFT", "HARD"]).
  values("team").
  list()

# Teams that brought nothing but slicks.
M.Race_strategy.objects.
  filter("tyre_compounds__@contained_by" => ["SOFT", "MEDIUM", "HARD"]).
  values("team").
  list()

# Teams that pitted on lap 12 or lap 30.
M.Race_strategy.objects.
  filter("pit_laps__@overlap" => [12, 30]).
  values("team").
  list()

# Two-stop strategies or longer. `@len` chains like `@year` does.
M.Race_strategy.objects.
  filter("pit_laps__@len__@gte" => 2).
  values("team", "stops" => "pit_laps__@len").
  list()
```

| Lookup | PostgreSQL | Matches when the array… | Django |
|---|---|---|---|
| `@acontains` | `@>` | holds every given element | `contains` |
| `@contained_by` | `<@` | holds only given elements | `contained_by` |
| `@overlap` | `&&` | holds at least one given element | `overlap` |
| `@len` | `cardinality(…)` | has that many elements (a transform: compare it) | `len` |

- Array containment is spelled `@acontains`, because `@contains` is a `LIKE` on every other field. JSON
  containment is `@jcontains` for the same reason. A pattern lookup on an `ArrayField`
  (`"tyre_compounds__@contains" => "SOFT"`) raises `FilterError` instead of matching the array's text.
- The value is a `Vector`, even for one element (`["SOFT"]`): a single value raises `FilterError`.
  Each element is checked by the element field. `size` does not apply, so `@contained_by` and
  `@overlap` may name more elements than the column holds.
- An element cannot be NULL (`missing` or `nothing`) and raises `FilterError`. PostgreSQL compares
  elements with `=`, so a NULL element never matches. Test the whole column with `@isnull` instead.
- An empty list is allowed, with PostgreSQL's meaning: every array contains it, and nothing overlaps it.
- `@len` is `0` for an empty array and NULL for a NULL one. On a column that is not an `ArrayField` it
  raises `FilterError`.
- The other side must be a list of values: another column (`F("…")`) raises `FilterError`.

#### Index and slice

```julia
# The compound each team started on: the first element, index 0.
M.Race_strategy.objects.
  filter("tyre_compounds__0" => "SOFT").
  values("team").
  list()

# The first two pit stops were on laps 12 and 30, in that order.
M.Race_strategy.objects.
  filter("pit_laps__0_2" => [12, 30]).
  values("team", "tyre_compounds__0").
  list()
```

- `field__n` is the element at index `n`, **0-based** as in Django and as a JSON path's array index
  (`payload__0`). It is compared, projected and ordered as one element: its value is checked by the
  element field, and the element's own lookups apply (`"tyre_compounds__0__@icontains" => "soft"`).
- `field__a_b` is the slice from index `a` up to, not including, `b` (Python's `[a:b]`). It is an
  array, so it takes equality and the array lookups, including `@len`.
- An index past the end is NULL in PostgreSQL, so `=` never matches it. `"pit_laps__5__@isnull" =>
  true` matches every row whose sixth element is NULL: an array shorter than six, a NULL array, and
  an array whose sixth element is itself NULL. A slice past the end is the empty array.
- One segment only. Another segment after an index or a slice, a segment that is not an index or a
  slice, an empty slice (`2_2`) or a reversed one (`2_1`) raises `QueryBuildError`.
- `__n` renders PostgreSQL's subscript `n + 1`, which is absolute. Arrays PormG writes start at
  subscript 1, so `__0` is their first element. An array another client stored with a different
  lower bound (`'[0:2]={…}'`) reads back 1-based, but there `__0` is the element at subscript 1, the
  second one.

### Arrays in bulk writes and migrations

`bulk_insert`, `bulk_update` and `bulk_copy` all take array columns. A `DataFrame` cell holds the
`Vector`; rows may have different lengths, and a `nothing` cell is a NULL array. An `ArrayField`
cannot be a `match_on` key of `bulk_update`, nor the key `returning=` matches rows by.

`makemigrations` reads an `integer[]` or `character varying(12)[]` column back as an `ArrayField`
(it used to be a warned `TextField`), and `inspectdb` writes one. Changing the element field is a
type change: an element that only widens (`IntegerField` → `BigIntegerField`, a longer `max_length`)
is a plain `ALTER`; any other change converts each element through its text, and the rows whose
values the new element type cannot read are counted before anything runs. See
[Lossy Column Changes](migrations/workflow.md#Lossy-Column-Changes).

---

## Text Fields

**A text value is a string, an integer, a date or a time.** An integer of any width (`1`,
`Int32(1)`, `UInt8(1)`) is written as its base-10 text, and a date or a time as its ISO text. A
float or a `Decimal` has no single text: `1.5` and `1.50` are the same number, and Julia prints
`1e10` as `"1.0e10"`. Neither has a `Bool`, although Julia counts it as an integer: `true` could be
`"true"`, `"1"` or `"t"`, and before this was refused the two engines each picked a different one.
Each of these raises `InvalidValueError` on a write and `FilterError` in a filter,
instead of comparing against a text that matches nothing. Pass the text you mean. A text field's
`default = true` is refused the same way, as a `FieldValidationError` when the model is defined.

```julia
M.Result.objects.filter("positiontext" => 1)      # compared as "1"
M.Result.objects.filter("positiontext" => "1")    # the same
M.Result.objects.filter("positiontext" => 1.0)    # FilterError: pass the text, "1"
M.Result.objects.filter("positiontext" => true)   # FilterError: pass the text the column holds
```

`max_length` counts the characters of the text that is written, whatever the value was: `12345` in a
`CharField(max_length = 3)` is five characters and raises `InvalidValueError`, exactly as `"12345"`
does, and so does a date (`"2020-01-01"` is ten).

### CharField(max_length)

**Purpose**: Variable-length strings with maximum length constraint.

**Database Type**: `VARCHAR(max_length)`

**Use Cases**: Names, titles, codes, short descriptions, enumerated values.

```julia
# Basic string fields
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30, unique=true),
    email = Models.CharField(max_length=100, unique=true),
    first_name = Models.CharField(max_length=50),
    last_name = Models.CharField(max_length=50)
)

# Field with choices (enum-like behavior)
Store_order = Models.Model(
    id = Models.IDField(),
    status = Models.CharField(
        max_length=20,
        choices=(
            ("pending", "Pending"),
            ("processing", "Processing"),
            ("shipped", "Shipped"),
            ("delivered", "Delivered"),
            ("cancelled", "Cancelled")
        ),
        default="pending"
    )
)

# Field with a human-readable label (the column name follows the field name: "part_number")
Part = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    part_number = Models.CharField(
        max_length=50, 
        unique=true, 
        verbose_name="Part Number"
    )
)
```

**Key Parameters**:
- `max_length::Int = 250`: Maximum characters (1 or greater; the backend sets the real ceiling)
- `choices`: Tuple of (value, display_name) pairs
- `unique::Bool = false`: Enforce uniqueness
- `db_index::Bool = false`: Create database index

### TextField()

**Purpose**: Unlimited length text content.

**Database Type**: `TEXT`

**Use Cases**: Articles, descriptions, comments, JSON data, large text content.

```julia
Race_report = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    summary = Models.TextField(blank=true, null=true)
)

```

### EmailField()

**Purpose**: Email addresses with built-in validation.

**Database Type**: `VARCHAR` with email validation

**Use Cases**: Team-member and driver emails, contact information, notification addresses.

```julia
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    email = Models.EmailField(unique=true),
    backup_email = Models.EmailField(null=true, blank=true)
)

# For contact forms
Team_contact = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    email = Models.EmailField(),
    message = Models.TextField()
)
```

### URLField(max_length=200)

**Purpose**: For storing website addresses and URIs with character length validation.

**Database Type**: `VARCHAR(max_length)`

**Use Cases**: Profile links, social media URLs, external references.

```julia
Driver_profile = Models.Model(
    id = Models.IDField(),
    website = Models.URLField(max_length=500, null=true, blank=true),
    instagram_profile = Models.URLField(unique=true)
)
```

### SlugField(max_length=50)

**Purpose**: Compressed strings typically used to build SEO-friendly URLs.

**Database Type**: `VARCHAR(max_length)`

**Use Cases**: Race-report slugs, part identifiers in URLs.

**Best Practice**: `SlugField` defaults to `db_index=true` as it is almost always used in `filter()` operations for routing.

```julia
Press_release = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    slug = Models.SlugField(unique=true)
)
```

### PasswordField()

**Purpose**: Django-compatible storage for password hashes.

**Database Type**: `VARCHAR(128)`

**Use Cases**: Persisting password hashes in tables that share a Django `auth`-style schema.

`PasswordField` is a `VARCHAR(128)` column sized to hold a Django-format password hash. It is a **storage type only** — PormG does not hash, verify, or otherwise transform the value. Hash the password in your application, store the finished string here, and read it back to verify. This keeps hashing policy in your app while the column stays wire-compatible with Django's authentication tables.

**Expected storage format** (Django PBKDF2-SHA256):
```
pbkdf2_sha256$720000$randomsalt$base64encodedHash
```

!!! warning
    Never assign a plain-text password to a `PasswordField` — the column stores whatever string it is given, verbatim. Hash the password in your application **before** saving.

```julia
# Team member account with password authentication
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=150, unique=true),
    email = Models.EmailField(unique=true),
    password = Models.PasswordField()
)
```

**Key Parameters**:
- `max_length::Int = 128`: Column width for the stored hash (Django default)
- `blank::Bool = false`: Whether the field can be left blank
- `null::Bool = false`: Whether NULL values are allowed

#### Hashing lives in your application

PormG ships no password hashing or verification. Generate the Django-format hash in your
application (or a dedicated auth package) and assign the resulting string to the
`PasswordField`; verify by re-hashing the candidate and comparing. Because the stored format
matches Django's (`pbkdf2_sha256$…`), a table written this way stays readable by Django's own
authentication code and vice versa.

#### Django Migration

If migrating from Django, password hashes are **fully compatible**. Users can continue logging in without any password reset required.

---

## Numeric Fields

**Numeric strings are base 10.** Every numeric field also takes its value as a string, such as
`"44"` for `laps` or `"12.5"` for `points` read from a CSV. The string must be written in base 10:
an optional sign, digits, at most one `.`, and an optional exponent (`"1.2e3"`). A `0x`, `0b` or `0o`
prefix (`"0x10"`) raises `InvalidValueError` on a write and `FilterError` in a filter, as Django's
`int(str)` / `Decimal(str)` refuse it. PormG never converts these strings: pass the number, or its
base-10 text.

The same rule applies when you declare a field. A string `default=` on a numeric field, such as
`IntegerField(default = "0")`, and a string width, such as `CharField(max_length = "100")`, must
also be base 10. `IntegerField(default = "0x10")` and `CharField(max_length = "0x10")` raise
`FieldValidationError`. A string float default must also be finite, so `FloatField(default = "Inf")`
raises, just as `FloatField(default = Inf)` does.

### IntegerField()

**Purpose**: 32-bit signed integers for counts, quantities, and ratings.

**Database Type**: `INTEGER`

**Range**: -2,147,483,648 to 2,147,483,647

```julia
# Basic numeric data
Part = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    stock_quantity = Models.IntegerField(default=0),
    min_stock_level = Models.IntegerField(default=10)
)

# Rating systems
Fan_review = Models.Model(
    id = Models.IDField(),
    race = Models.ForeignKey("Race"),
    rating = Models.IntegerField(),  # 1-5 stars
    helpful_votes = Models.IntegerField(default=0)
)

# Age and demographic data
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    age = Models.IntegerField(null=true, blank=true),
    login_count = Models.IntegerField(default=0)
)
```

### BigIntegerField()

**Purpose**: 64-bit signed integers for large numbers and timestamps.

**Database Type**: `BIGINT`

**Range**: -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807

```julia
# Large counters and metrics
Season_analytics = Models.Model(
    id = Models.IDField(),
    page_views = Models.BigIntegerField(default=0),
    unique_visitors = Models.BigIntegerField(default=0),
    bytes_transferred = Models.BigIntegerField(default=0)
)

# Timestamp storage (Unix timestamp)
Timing_event = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    timestamp_ms = Models.BigIntegerField(),  # Milliseconds since epoch
    driver_id = Models.BigIntegerField()
)
```

### FloatField()

**Purpose**: Double-precision floating-point numbers for measurements and calculations.

**Database Type**: `DOUBLE PRECISION`

```julia
# Telemetry measurements
Car_sensor = Models.Model(
    id = Models.IDField(),
    temperature = Models.FloatField(),  # Celsius
    humidity = Models.FloatField(),     # Percentage
    pressure = Models.FloatField()      # hPa
)

# Geographic coordinates
Circuit = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    latitude = Models.FloatField(),
    longitude = Models.FloatField(),
    elevation = Models.FloatField(null=true)  # Meters above sea level
)

# Derived performance metrics (use DecimalField for currency)
Car_performance = Models.Model(
    id = Models.IDField(),
    pace_delta = Models.FloatField(),       # Seconds vs pole
    tyre_deg_rate = Models.FloatField(),    # Seconds lost per lap
    fuel_effect = Models.FloatField(null=true)  # Seconds per 10 kg
)
```

### DecimalField(max_digits, decimal_places)

**Purpose**: Precise decimal numbers for financial and monetary data.

**Database Type**: `decimal(max_digits, decimal_places)` on PostgreSQL (`numeric`, exact at any
width); `DECIMAL(max_digits, decimal_places)` on SQLite.

**Use Cases**: Currency, financial calculations, precise measurements.

!!! warning "SQLite: `max_digits` is at most 15"
    SQLite has no exact decimal type. Its `NUMERIC` affinity stores a decimal as an `Int64` or a
    `Float64` as it is written, and a `Float64` keeps only fifteen significant digits exactly — so a
    wider column would round or truncate values with no error. `makemigrations` therefore raises
    `BackendCapabilityError` for a `DecimalField` with `max_digits` above 15 on a SQLite connection,
    and every column it does create holds its values exactly — and reads back as a
    `Decimals.Decimal`, as on PostgreSQL, rather than the `Int64`/`Float64` SQLite stored. PostgreSQL
    accepts any width. See
    [PostgreSQL ↔ SQLite divergences](postgres.md#PostgreSQL-SQLite-divergences).

```julia
# Financial data
Sponsor_invoice = Models.Model(
    id = Models.IDField(),
    subtotal = Models.DecimalField(max_digits=10, decimal_places=2),
    tax_amount = Models.DecimalField(max_digits=8, decimal_places=2),
    total_amount = Models.DecimalField(max_digits=10, decimal_places=2),
    discount_rate = Models.DecimalField(max_digits=5, decimal_places=4)  # 0.1234 = 12.34%
)

# Merchandise pricing
Merchandise = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    unit_price = Models.DecimalField(max_digits=8, decimal_places=2),
    wholesale_price = Models.DecimalField(max_digits=8, decimal_places=2),
    weight = Models.DecimalField(max_digits=6, decimal_places=3)  # Kilograms
)
```

**Key Parameters**:
- `max_digits::Int`: Total number of digits (at most 15 on SQLite — see above)
- `decimal_places::Int`: Number of decimal places

**Write validation**: every write (`create`, `update`, `get_or_create`, `update_or_create`,
`bulk_insert`, `bulk_update`, `bulk_copy`)
checks a value against the three widths the column has, the way Django's `DecimalValidator` does.
A value that exceeds one raises `InvalidValueError` naming the field, before any SQL, on both engines:

- at most `max_digits` digits in total;
- at most `decimal_places` digits after the point (a value is never rounded to fit);
- at most `max_digits - decimal_places` digits **before** the point. `DecimalField(max_digits=5,
  decimal_places=2)` holds `999.99` and refuses `1000`.

Leading zeros are not digits: `DecimalField(max_digits=2, decimal_places=2)` accepts `0.55`, as
PostgreSQL's `numeric(2, 2)` does.

---

## Date and Time Fields

### DateField()

**Purpose**: Calendar dates without time information.

**Database Type**: `DATE`

**Format**: YYYY-MM-DD

**Current Contract**:
- Accepts `Date` directly.
- Also accepts `DateTime` and `ZonedDateTime`, coercing them to the calendar date. A `ZonedDateTime`
  yields its *local* calendar date.
- Accepts `YYYY-MM-DD` strings.
- This means `DateField` is permissive about the *input* spelling; it does not reject datetime
  values automatically. It is not permissive about what it *stores* — every accepted spelling lands
  on a `Date`.

The same four spellings hold for `default=`, which stores a `Date` for each of them:

```julia
Models.DateField(default = Date(2024, 7, 28))              # Date("2024-07-28")
Models.DateField(default = "2024-07-28")                   # Date("2024-07-28")
Models.DateField(default = DateTime(2024, 7, 28, 10, 30))  # Date("2024-07-28") — time dropped
Models.DateField(default = ZonedDateTime(2024, 7, 28, tz"UTC"))  # Date("2024-07-28")
```

A default that is not one of those — a malformed date string, an impossible calendar date such as
`"2023-02-29"`, or a number — is refused with `FieldValidationError`. Until PormG 0.7 three of the
four spellings above raised a bare `MethodError` instead, because `default=` reused the field's SQL
formatter (which returns a string) as its converter.

```julia
# Personal information
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    birth_date = Models.DateField(null=true),
    registration_date = Models.DateField()
)

# Event scheduling
Grand_prix = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    event_date = Models.DateField(),
    registration_deadline = Models.DateField(null=true)
)

# Business records
Sponsor_contract = Models.Model(
    id = Models.IDField(),
    contract_number = Models.CharField(max_length=50),
    issue_date = Models.DateField(),
    due_date = Models.DateField(),
    paid_date = Models.DateField(null=true)
)
```

### DateTimeField()

**Purpose**: Date and time with timezone support.

**Database Type**: `TIMESTAMP WITH TIME ZONE`

**Use Cases**: Timestamps, logs, audit trails, precise timing.

**Current Contract**:
- `default` values are normalized to `Union{ZonedDateTime, DateTime, Nothing}`.
- **Canonicalized to UTC (issue #79):** every `DateTimeField` value — written, bound, or used as a filter value — is canonicalized to one UTC ISO-8601 string, `yyyy-mm-ddTHH:MM:SS.sss+00:00` (millisecond precision, `+00:00` offset). This mirrors Django `USE_TZ` / Rails / SQLAlchemy and makes SQLite's lexicographic TEXT comparison agree with PostgreSQL's `timestamptz` instant comparison: equality and range filters return the **same rows on both backends** regardless of how the input instant is spelled (`Z` vs `+00:00`, `.0`/`.000`/no-subsecond, or a non-UTC offset such as `-03:00`/`+05:30`).
- Passing `ZonedDateTime` preserves the instant (converted to UTC for storage) and is the recommended path for shared Django/PostgreSQL tables.
- Passing a plain Julia `DateTime` is interpreted as `UTC`.
- Internal `auto_now` and `auto_now_add` timestamps are generated in `settings.time_zone` and then canonicalized to UTC on serialization — the same instant, stored in the UTC spelling.
- The same semantics are exercised on both PostgreSQL and SQLite integration backends, including `bulk_insert` and `bulk_update` paths for `DateTimeField` values.
- If your Django app uses `USE_TZ=True` with a non-UTC active timezone, you should treat plain `DateTime` as a deliberate UTC input and use `ZonedDateTime` for local civil times.

#### TIMESTAMPTZ vs TIMESTAMP
By default, `DateTimeField` uses `TIMESTAMPTZ`. 
- **TIMESTAMPTZ** (Recommended): Stores values in UTC internally and converts them to your session's timezone upon retrieval. This ensures consistency across different geographical regions.
- **TIMESTAMP**: Stores the exact date and time provided without any timezone conversion. You can switch to this by passing `type="TIMESTAMP"`.

#### Naive vs Aware Inputs
- **Aware input**: `ZonedDateTime(2026, 3, 13, 9, 0, tz"America/Sao_Paulo")` keeps the source timezone semantics explicit.
- **Naive input**: `DateTime(2026, 3, 13, 9, 0)` is currently serialized as `UTC`, not as `settings.time_zone`.
- **Interop rule**: if the upstream system thinks in a local timezone, convert to `ZonedDateTime` before `create`, `update`, `bulk_insert`, or `bulk_update`.
- **SQLite note**: SQLite stores datetime values as text, but PormG reconstructs `ZonedDateTime` / `DateTime` values on read so the high-level contract matches PostgreSQL. This applies to every read terminal — `list()`, `first()`, `get()` and `query |> DataFrame` alike.

```julia
# Audit and logging
Race_audit_log = Models.Model(
    id = Models.IDField(),
    team_member = Models.ForeignKey("Team_member"),
    action = Models.CharField(max_length=100),
    timestamp = Models.DateTimeField(),
    ip_address = Models.CharField(max_length=45)
)

# Content management
Race_report = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    created_at = Models.DateTimeField(),
    updated_at = Models.DateTimeField(),
    published_at = Models.DateTimeField(null=true)
)

# Team store
Store_order = Models.Model(
    id = Models.IDField(),
    created_at = Models.DateTimeField(),
    shipped_at = Models.DateTimeField(null=true),
    delivered_at = Models.DateTimeField(null=true)
)
```

### TimeField()

**Purpose**: Time of day without date information.

**Database Type**: `TIME`

**Format**: HH:MM:SS

```julia
# Facility hours
Team_store = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    opening_time = Models.TimeField(),
    closing_time = Models.TimeField()
)

# Scheduling
Garage_booking = Models.Model(
    id = Models.IDField(),
    date = Models.DateField(),
    start_time = Models.TimeField(),
    end_time = Models.TimeField(),
    driver = Models.ForeignKey("Driver")
)

# Sports and timing
Race = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=100),
    start_time = Models.TimeField(),
    best_lap_time = Models.TimeField(null=true)
)
```

### DurationField()

**Purpose**: Time intervals and durations.

**Database Type**: `INTERVAL`

**Use Cases**: Elapsed time, durations, time spans.

```julia
# Task tracking
Pit_task = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    estimated_duration = Models.DurationField(),
    actual_duration = Models.DurationField(null=true)
)

# Media content
Onboard_video = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    duration = Models.DurationField(),
    encoding_time = Models.DurationField(null=true)
)
```

**Accepts**: a `Dates.Period` or `Dates.CompoundPeriod` of weeks down to nanoseconds, or a string
in one of three forms — `HH:MM:SS(.sss)`, `M:SS(.sss)` or bare seconds `SS(.sss)`. A string is
written in the same canonical `HH:MM:SS` form as the period it spells, so a field past its range
is carried into the next one: `"125:30"` is stored as `"02:05:30"`, `"90"` as `"00:01:30"`, and
`"01:75:00"` as `"02:15:00"`. Hours are never carried into days. Months and years are refused,
because they have no fixed length. Before #891 a string was stored as it was spelled (`1:27:30`,
`00:00:90`, `00:125:30`), so on SQLite a row written then can still hold that spelling. The upgrade
guide's #891 entry shows how to re-save those rows.

**Reads back as**: a `Dates.CompoundPeriod` — on PostgreSQL (either driver) and on SQLite alike, so
code can dispatch on it. That holds for the column read through a query: `list()`, `DataFrame`, and
the column in `values(...)`, including a whole-second value like a `23 seconds` pit stop, which one
PostgreSQL driver would otherwise hand back as a bare `Second(23)`.

```julia
lap = M.Lap_times.objects.filter("raceid" => 1, "driverid" => 1, "lap" => 1).values("time").list(:dict)[1]
lap[:time] isa Dates.CompoundPeriod                            # true on every engine
lap[:time] == Dates.Minute(1) + Dates.Second(49) + Dates.Millisecond(88)   # 1:49.088
```

The same holds for the row a write hands back (`create()`, `update_or_create`, `get_or_create`),
and for a function that returns one of the column's own values: `Max("time")` and `Min("time")`,
the window value functions `Lag`, `Lead`, `FirstValue`, `LastValue` and `NthValue`, and
`Coalesce`, `Greatest`, `Least` or `NullIf` over `time` (#824). It also holds for a `Joined(...)`
handle on the column, for a `CTE(...)` column whose body projects it, and for a `Subquery(...)`
that projects it (#888). A computed value is not
the column, so it is still whatever the engine delivered: text on SQLite, and a bare `Period` or a
`CompoundPeriod` on PostgreSQL. That covers a `CTE(...)` column the body computes, and a `Coalesce`
whose arguments are of different types. The computed intervals PormG types are the difference of two
timestamps, `F("start_at") - F("date")`, and interval arithmetic — `F("time") * 2`,
`F("time") + (F("start_at") - F("date"))`, a difference plus a duration — and `Max`/`Min` over
either (#894). `Sum("time")` and `Avg("time")` are typed too, and so are `Greatest`, `Least` and
`Coalesce` over intervals of either kind (#900), and arithmetic on any of these
(`Sum("time") / Count("lap")`, #907). Each reads back as a `CompoundPeriod` on both engines
(see *Subtracting two dates* in the F-expressions guide).

On **SQLite** a duration is stored as text (`00:01:49.088`), and hours are never folded into days.
That text sorts wrongly at 100 hours and above (`"100:00:00"` sorts before `"99:00:00"`) and for
negative durations. So PormG reads it as milliseconds wherever the column is **ordered**, which
agrees with PostgreSQL:
- `order_by("time")`
- `<` or `>` against a duration or another `DurationField` (`"time__@gt" => Minute(2)`,
  `F("time") > Minute(2)`)
- `@range`
- `Max`/`Min`, `Sum`/`Avg`, and `Greatest`/`Least`/`Coalesce` over durations, duration literals and
  timestamp differences, also inside arithmetic (`Sum("time") - Max("time")`, #907)
- inside arithmetic, or against a timestamp difference (`(F("time") * 2) > Minute(3)`)

That reading rounds each side to the nearest **millisecond**, the precision of a timestamp there,
while PostgreSQL keeps microseconds. So two durations less than a millisecond apart can order the
same on SQLite when PostgreSQL tells them apart. `==` and `@in` compare the stored text, which is
exact for every value written in the canonical form (see *Accepts* above).

The **components** inside it are the engine's own, though: the same lap time can arrive as minutes,
seconds and milliseconds from one engine and as hours through nanoseconds from another. Compare
durations with `==`, which compares the total length, and never with `===` — a `CompoundPeriod`
holds a vector, so two equal reads are not `===` even from the same engine.

---

## Boolean Fields

### BooleanField()

**Purpose**: True/false values for flags and binary states.

**Database Type**: `BOOLEAN`

```julia
# Team member preferences and flags
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    is_active = Models.BooleanField(default=true),
    is_staff = Models.BooleanField(default=false),
    is_superuser = Models.BooleanField(default=false),
    email_notifications = Models.BooleanField(default=true),
    newsletter_subscription = Models.BooleanField(default=false)
)

# Content moderation
Race_report = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    is_published = Models.BooleanField(default=false),
    is_featured = Models.BooleanField(default=false),
    allow_comments = Models.BooleanField(default=true)
)

# System settings
System_setting = Models.Model(
    id = Models.IDField(),
    maintenance_mode = Models.BooleanField(default=false),
    registration_enabled = Models.BooleanField(default=true),
    debug_mode = Models.BooleanField(default=false)
)
```

---

## Binary and File Fields

### ImageField()

**Purpose**: Image file paths and metadata.

**Database Type**: `VARCHAR` (stores file path)

**Use Cases**: Race photos, galleries, driver avatars, car images.

```julia
# Driver profiles
Driver_profile = Models.Model(
    id = Models.IDField(),
    driver = Models.OneToOneField("Driver"),
    avatar = Models.ImageField(null=true, blank=true),
    cover_photo = Models.ImageField(null=true, blank=true)
)

# Merchandise catalog
Merchandise = Models.Model(
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    main_image = Models.ImageField(),
    thumbnail = Models.ImageField(null=true)
)

# Gallery system
Race_photo = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    image = Models.ImageField(),
    caption = Models.TextField(blank=true),
    upload_date = Models.DateTimeField()
)
```

### BinaryField()

**Purpose**: Raw binary data — images, compressed blobs, encrypted content.

**Database Type**: 
- **PostgreSQL**: `BYTEA`
- **SQLite**: `BLOB`

**Use Cases**: File storage, encrypted data, binary documents.

**Handling**: Raw bytes in, raw bytes out — write a `Vector{UInt8}` and read a `Vector{UInt8}` back.
Arbitrary byte sequences round-trip intact, including `0x00` and payloads that are not valid UTF-8.
An `AbstractString` is also accepted on write and stored as its **UTF-8 code units**; to store the
*decoded* bytes of an encoded string, decode it yourself with `hex2bytes(s)` or `base64decode(s)`.

**Key Parameters**:
- `max_length::Union{Int, Nothing} = nothing`: maximum payload size in **bytes**, not characters.
  Enforced before the query is built *and* by a `CHECK` constraint in the schema
  (`octet_length` on PostgreSQL, `length` on SQLite). `nothing` means unbounded. The largest
  accepted bound is `1073741824` (1 GiB, PostgreSQL's limit for one `bytea` value); a larger one
  raises `FieldValidationError`, since it would constrain nothing.
- `default::Union{Vector{UInt8}, Nothing} = nothing`: rendered into the DDL as a byte literal
  (`'\xdeadbeef'::bytea` / `X'deadbeef'`). Must be a `Vector{UInt8}` — a `String` raises
  `FieldValidationError` rather than guessing between its code units and a decoded encoding.

```julia
# Document storage
Technical_document = Models.Model("technical_document",
    id = Models.IDField(),
    name = Models.CharField(max_length=200),
    file_data = Models.BinaryField(max_length=5_000_000),   # ≤ 5 MB
    mime_type = Models.CharField(max_length=100),
    file_size = Models.IntegerField()
)

Technical_document.objects.create(
    "name"      => "2024 Monza aero package",
    "file_data" => read("aero.pdf"),        # Vector{UInt8}
    "mime_type" => "application/pdf",
    "file_size" => filesize("aero.pdf")
)

row = Technical_document.objects.filter("name" => "2024 Monza aero package").
    values("file_data").list() |> first
write("roundtrip.pdf", row[:file_data])     # Vector{UInt8}, byte-identical

# Encryption and security
Encrypted_telemetry = Models.Model("encrypted_telemetry",
    id = Models.IDField(),
    team_member = Models.ForeignKey("Team_member"),
    encrypted_content = Models.BinaryField(),
    encryption_key_hash = Models.CharField(max_length=64)
)
```

**Filtering on bytes.** A payload compares as one value, byte for byte, and a list of payloads is a
membership filter:

```julia
# Equality — one blob, one bound parameter
Technical_document.objects.filter("file_data" => read("aero.pdf"))

# Membership — a list of payloads
Technical_document.objects.filter("file_data__@in" => [read("aero.pdf"), read("floor.pdf")])
```

Mind the difference in the value's *shape*: `filter("file_data" => bytes)` takes a `Vector{UInt8}`
and `filter("file_data__@in" => [a, b])` takes a vector **of** them. Passing a flat `Vector{UInt8}`
to `@in` reads it as a list of small integers and is refused, and passing a `Vector{UInt8}` to a
non-binary field is refused as an operator-less vector value.

!!! note "Migrating a column created by an earlier PormG"
    Earlier versions rendered `BinaryField` as `TEXT` on both backends. The next `makemigrations`
    after upgrading proposes a type change — `ALTER … TYPE bytea USING convert_to(…, 'UTF8')` on
    PostgreSQL, a table rebuild with `CAST(… AS BLOB)` on SQLite — which reinterprets the existing
    text as its UTF-8 bytes. If the column actually held *encoded* text (hex, Base64), substitute
    `decode(col, 'hex')` / `decode(col, 'base64')` in the generated plan before applying it. See
    [the change log](https://github.com/PingoLee/PormG.jl/tree/main/upgrading).

---

## Structured Data Fields

### JSONField()

**Purpose**: Storing semi-structured data using JSON formatting.

**Database Type**: 
- **PostgreSQL**: `JSONB` (binary storage, fast querying, allows indexing)
- **SQLite**: `TEXT` (stores as a JSON string)

**Use Cases**: Configuration settings, variable data payloads, complex metadata.

**Handling**: In Julia, this field accepts and returns `Dict` or `Vector` types, automatically handling the serialization/deserialization.

**NUL characters**: a value containing a NUL (`'\0'`) anywhere — a string value, a key, a nested element, or a JSON string carrying the escape `\u0000` — raises `InvalidValueError` before the statement is sent, on every backend (a `default=` carrying one raises `FieldValidationError` when the model is defined). PostgreSQL `jsonb` cannot store that escape, so SQLite refuses it too and the engines stay aligned. The literal text `\u0000` (a backslash followed by `u0000`) is ordinary data and is stored as written.

```julia
Car_setup = Models.Model(
    id = Models.IDField(),
    settings = Models.JSONField(),
    metadata = Models.JSONField(null=true, blank=true)
)

# Example usage:
Car_setup.objects.create("settings" => Dict("front_wing"=>5, "tyre_pressure"=>21.5))
```

---

## Relationship Fields

### ForeignKey(to_model)

**Purpose**: Many-to-one relationships linking records to a single target record.

**Database Type**: `BIGINT` with foreign key constraint

**Use Cases**: Categories, users, parent-child relationships.

**FK Value Contract**:
- ForeignKey fields accept scalar primary-key values, including `0`, when that key exists in the referenced table.
- Use `nothing` or `missing` to write SQL `NULL` on nullable FK columns.

```julia
# Press room
Race_report = Models.Model(
    id = Models.IDField(),
    title = Models.CharField(max_length=200),
    author = Models.ForeignKey("Team_member", on_delete="CASCADE"),
    category = Models.ForeignKey("Report_category", on_delete="PROTECT"),
    content = Models.TextField()
)

# Team store
Store_order = Models.Model(
    id = Models.IDField(),
    customer = Models.ForeignKey("Fan", on_delete="PROTECT"),
    shipping_address = Models.ForeignKey("Shipping_address", on_delete="SET_NULL", null=true),
    total_amount = Models.DecimalField(max_digits=10, decimal_places=2)
)

Order_line = Models.Model(
    id = Models.IDField(),
    order = Models.ForeignKey("Store_order", on_delete="CASCADE"),
    product = Models.ForeignKey("Merchandise", on_delete="PROTECT"),
    quantity = Models.IntegerField(),
    unit_price = Models.DecimalField(max_digits=8, decimal_places=2)
)

# Multiple ForeignKeys to the same model — related_name is optional, but recommended.
# Without it PormG derives one per field: `team_radio_sender` and `team_radio_recipient`.
Team_radio = Models.Model(
    id = Models.IDField(),
    sender = Models.ForeignKey("Team_member", on_delete="CASCADE", related_name="sent_messages"),
    recipient = Models.ForeignKey("Team_member", on_delete="CASCADE", related_name="received_messages"),
    content = Models.TextField(),
    sent_at = Models.DateTimeField()
)
```

A `related_name` may not contain `__` or `@`, nor end with `_`: `__` is the lookup-path separator,
`@` opens an operator suffix, and traversing an accessor appends the separator to it — so any of the
three registers a name that can then never be written as a lookup-path segment. The same rule
applies to a name PormG *derives* for you — see
[Naming Reverse Relations](read/values_and_joins.md#Naming-Reverse-Relations).

**On Delete Options**:
- `CASCADE`: Delete this record when target is deleted
- `RESTRICT`: Prevent deletion of target if this record exists
- `SET_NULL`: Set field to NULL (requires `null=true`)
- `SET_DEFAULT`: Set to the field's default value (requires `default=`)
- `PROTECT`: Raise error to prevent deletion
- `DO_NOTHING`: No action (may cause integrity errors)

Omitting `on_delete` is also valid and is the default — PormG then emits no statement for the
relation and the column renders `ON DELETE NO ACTION`, so the dependent row is **not** cascaded.

The two "requires" above are enforced, not advisory: registering a model with `SET_NULL` on a
`null=false` field, or `SET_DEFAULT` with no `default`, raises `ModelDefinitionError` — and every
such contradiction in the module is reported in that one error, naming each offending model, field
and fix, so a schema carrying several of them is fixed in a single pass.

### OneToOneField(to_model)

**Purpose**: Strict one-to-one relationships where each record corresponds to exactly one target record.

**Database Type**: `BIGINT` with unique foreign key constraint

**Use Cases**: Driver profiles, settings, model extensions.

```julia
# Driver profile extension
Driver_profile = Models.Model(
    id = Models.IDField(),
    driver = Models.OneToOneField("Driver", on_delete="CASCADE"),
    bio = Models.TextField(blank=true),
    birth_date = Models.DateField(null=true),
    website = Models.CharField(max_length=200, blank=true),
    location = Models.CharField(max_length=100, blank=true)
)

# Staff details
Staff_profile = Models.Model(
    id = Models.IDField(),
    team_member = Models.OneToOneField("Team_member", on_delete="CASCADE"),
    staff_id = Models.CharField(max_length=20, unique=true),
    department = Models.ForeignKey("Constructor"),
    hire_date = Models.DateField(),
    salary = Models.DecimalField(max_digits=10, decimal_places=2)
)

# Settings and preferences
Team_member_settings = Models.Model(
    id = Models.IDField(),
    team_member = Models.OneToOneField("Team_member", on_delete="CASCADE"),
    theme = Models.CharField(max_length=20, default="light"),
    language = Models.CharField(max_length=10, default="en"),
    notifications_enabled = Models.BooleanField(default=true)
)
```

!!! note "On a fetched row, a one-to-one behaves exactly like a `ForeignKey`"
    A `OneToOneField` **is** a foreign key carrying a `UNIQUE` constraint, and every row-level
    rule is the same one (#418). It must be projected up front — reading an unprojected
    `row.team_member` raises `LazyTraversalError`, not a lazy load.
    `values("team_member__username")` traverses it like any other relation,
    `row.team_member__username = "senna"` is assignable, and `save()` writes that change to the
    **`Team_member`** table. Changing the key itself and a projected `team_member__*` column in the
    *same* `save()` is refused, because the projected update would filter on the key value already
    on the row — save the key change first.

### ManyToManyField(to_model)

**Purpose**: Many-to-many relationships through a join table, without adding a column to either related model table.

When `through` is not supplied, PormG migrations synthesize a join table with two foreign keys and a composite unique index. The relation can be traversed in filters and projections with the same double-underscore syntax used by `ForeignKey` joins.

The field may also target the model that declares it (pass the model name as a string). Both join columns are then prefixed `from_` / `to_`, since one table cannot carry the same column twice — see [Self-Referential Relationships](many_to_many.md#Self-Referential-Relationships).

```julia
Driver_collection = Models.Model("driver_collections",
    id = Models.IDField(),
    label = Models.CharField(max_length=120),
    drivers = Models.ManyToManyField(Driver, related_name="collections")
)

query = Driver_collection.objects
query.filter("drivers__nationality" => "Brazilian")
query.values("label", "drivers__surname")
rows = query.list()

driver_query = Driver.objects
driver_query.filter("collections__label" => "World champions")
driver_query.values("forename", "surname")
champions = driver_query.list()
```

For write operations, bind the relation to a source primary key and use the relation manager:

```julia
collection_id = 1
senna_id = 102
prost_id = 117

manager = Driver_collection.drivers(collection_id)
manager.add(senna_id, prost_id)  # returns nothing
manager.remove(prost_id)         # returns nothing
manager.set([senna_id])          # returns (added=X, removed=Y)
driver_rows = manager.all().values("surname", "nationality").list()
```

Use `through=Existing_model` when the relationship table has extra fields, such as the season when a driver was added to a collection. In that case PormG treats the through model as a normal model and does not auto-generate a join table — including its `db_table`, if it declares one, which then names the join table in every query and mutator, and its two foreign keys' `db_column`, which name the join **columns** (#377). The field-level `db_table` below applies to the auto-generated table only and is ignored when `through` is given.

!!! warning
    **Django-Style Strict Mutators**: If the custom `through` model contains any extra fields beyond the relationship foreign keys, direct manager mutator operations (`add`, `remove`, `clear`, and `set`) will raise a `QueryBuildError`. Create or delete custom through model objects directly using the through model's objects manager instead.

---

## Common Field Options

All field types support these common parameters:

### Validation Options
- `null::Bool = false`: Allow NULL values in database
- `blank::Bool = false`: Allow empty values in forms  
- `unique::Bool = false`: Enforce uniqueness constraint on this single column. For uniqueness spanning **two or more** columns, use a model-level `UniqueConstraint` — see [Composite Uniqueness](models.md#Composite-Uniqueness-(unique_together)).
- `default`: Set default value for new records. PormG applies it only where the write supplies no value for the field; a field passed explicitly — including as `nothing`/`missing` — is honored as written. See [Defaults and Auto Values](write/bulk.md#Defaults-and-Auto-Values) for the `DataFrame` form of the same rule.

### Database Options
- `db_index::Bool = false`: Create a database index on this single column, for faster queries. To index **two or more** columns together, use a model-level `Index` — see [Composite Indexes](models.md#Composite-Indexes-(Meta.indexes)).
- `db_column::Union{String, Nothing} = nothing`: Maps this field to a differently-named physical column; **authoritative** across DDL, queries, and migrations (#50). Defaults to the field name (see [Schema Conventions](schema_conventions.md))
- `db_constraint::Bool = true`: Create database constraints (for relationships)

### Example with All Common Options
```julia
Merchandise = Models.Model(
    id = Models.IDField(),
    
    # CharField with full options
    name = Models.CharField(
        max_length=200,
        unique=true,
        db_index=true  
    ),
    
    # Optional field with default
    status = Models.CharField(
        max_length=20,
        choices=(("active", "Active"), ("inactive", "Inactive"))
    ),
    
    # Nullable relationship
    category = Models.ForeignKey(
        "Merchandise_category",
        on_delete="SET_NULL",
        null=true,
        blank=true
    )
)
```

---

## Field Validation

PormG provides automatic validation for all field types:

### Type Validation
```julia
# Integer fields validate numeric input
quantity = Models.IntegerField()  # Only accepts integers
price = Models.DecimalField(max_digits=8, decimal_places=2)  # Precise decimal

# String fields validate length
name = Models.CharField(max_length=50)  # Max 50 characters
description = Models.TextField()  # Unlimited length

# Date fields validate format
birth_date = Models.DateField()  # Must be valid date
created_at = Models.DateTimeField()  # Must be valid datetime
```

### Constraint Validation
```julia
# Uniqueness validation
email = Models.EmailField(unique=true)  # Must be unique across all records

# Choice validation
status = Models.CharField(
    max_length=20,
    choices=(("active", "Active"), ("inactive", "Inactive"))
)  # Must be one of the choices

# Null validation
required_field = Models.CharField(max_length=100)  # Cannot be NULL
optional_field = Models.CharField(max_length=100, null=true)  # Can be NULL
```

### Relationship Validation
```julia
# Foreign key validation
author = Models.ForeignKey("Team_member", on_delete="CASCADE")  # Must reference valid Team_member

# One-to-one validation
profile = Models.OneToOneField("Driver_profile")  # Must be unique relationship
```

---

## Migration Considerations

### Safe Changes
These changes can be made without data loss:
- Adding new fields with `null=true` or `default` values
- Increasing `max_length` on CharField
- Changing `blank` from `false` to `true`
- Adding database indexes
- Changing `on_delete` behavior

### Careful Changes
These changes require data validation:
- Decreasing `max_length` on CharField
- Changing `null` from `true` to `false`
- Adding `unique=true` to existing fields
- Changing field types (e.g., CharField to IntegerField)

### Example Migration-Safe Model Evolution
```julia
# Version 1: Initial model
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    email = Models.CharField(max_length=100)
)

# Version 2: Safe additions
Team_member = Models.Model(
    id = Models.IDField(),
    username = Models.CharField(max_length=30),
    email = Models.CharField(max_length=150, unique=true),  # Increased length, added unique
    first_name = Models.CharField(max_length=50, blank=true),  # New optional field
    last_name = Models.CharField(max_length=50, blank=true),   # New optional field
    is_active = Models.BooleanField(default=true),            # New field with default
    created_at = Models.DateTimeField(null=true)              # New nullable field
)
```

---

## Best Practices

### Choosing the Right Field Type
1. **Use IDField for primary keys** in new applications
2. **Use CharField for short text** with known maximum length
3. **Use TextField for long content** like articles or descriptions
4. **Use DecimalField for money** and precise calculations
5. **Use IntegerField for counts** and small numbers
6. **Use BigIntegerField for large numbers** and timestamps
7. **Use DateTimeField for timestamps** and audit trails
8. **Use ForeignKey for relationships** between models

### Performance Considerations
1. **Add indexes** (`db_index=true`) on frequently queried fields
2. **Use appropriate field types** to minimize storage
3. **Consider nullable fields** for optional data
4. **Use choices** for enumerated values instead of separate tables
5. **Avoid BinaryField** for large files; use file paths instead
6. **Use UUIDField for distributed identity** to avoid primary key collisions across systems
7. **Use JSONField for flexible metadata** that does not require a rigid relational schema


---

This comprehensive guide covers all field types available in PormG. For specific implementation details and advanced usage, refer to the source code in `src/Models.jl` and the test examples in the `test/` directory.
