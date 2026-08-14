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

### AutoField()

**Purpose**: Auto-incrementing 32-bit integer primary key.

**Database Type**:
- **PostgreSQL**: `INTEGER` with `SERIAL`
- **SQLite**: `INTEGER PRIMARY KEY AUTOINCREMENT`

**Use Cases**: Small to medium applications, legacy compatibility, storage efficiency.

```julia
# Basic usage
Part_category = Models.Model(
    id = Models.AutoField(),
    name = Models.CharField(max_length=100)
)

# For lookup tables with limited records
Status = Models.Model(
    id = Models.AutoField(),
    name = Models.CharField(max_length=20),
    description = Models.TextField()
)
```

**Range**: -2,147,483,648 to 2,147,483,647

**IDField vs AutoField Comparison**:
| Feature | AutoField | IDField |
|---------|-----------|---------|
| **Storage** | 4 bytes | 8 bytes |
| **Max Records** | ~2 billion | ~9 quintillion |
| **PostgreSQL Type** | INTEGER SERIAL | BIGINT IDENTITY |
| **Best For** | Small/medium apps | Large-scale apps |

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

---

## Text Fields

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

**Database Type**: `NUMERIC(max_digits, decimal_places)`

**Use Cases**: Currency, financial calculations, precise measurements.

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
- `max_digits::Int`: Total number of digits
- `decimal_places::Int`: Number of decimal places

---

## Date and Time Fields

### DateField()

**Purpose**: Calendar dates without time information.

**Database Type**: `DATE`

**Format**: YYYY-MM-DD

**Current Contract**:
- Accepts `Date` directly.
- Also accepts `DateTime` and `ZonedDateTime`, coercing them to the calendar date before SQL generation.
- Accepts `YYYY-MM-DD` strings.
- This means `DateField` is currently permissive; it does not yet reject datetime values automatically.

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
- **SQLite note**: SQLite stores datetime values as text, but PormG reconstructs `ZonedDateTime` / `DateTime` values on read so the high-level contract matches PostgreSQL.

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
  (`octet_length` on PostgreSQL, `length` on SQLite). `nothing` means unbounded.
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

!!! note "Migrating a column created by an earlier PormG"
    Earlier versions rendered `BinaryField` as `TEXT` on both backends. The next `makemigrations`
    after upgrading proposes a type change — `ALTER … TYPE bytea USING convert_to(…, 'UTF8')` on
    PostgreSQL, a table rebuild with `CAST(… AS BLOB)` on SQLite — which reinterprets the existing
    text as its UTF-8 bytes. If the column actually held *encoded* text (hex, Base64), substitute
    `decode(col, 'hex')` / `decode(col, 'base64')` in the generated plan before applying it. See
    [`UPGRADING.md`](https://github.com/PingoLee/PormG.jl/blob/main/UPGRADING.md).

---

## Structured Data Fields

### JSONField()

**Purpose**: Storing semi-structured data using JSON formatting.

**Database Type**: 
- **PostgreSQL**: `JSONB` (binary storage, fast querying, allows indexing)
- **SQLite**: `TEXT` (stores as a JSON string)

**Use Cases**: Configuration settings, variable data payloads, complex metadata.

**Handling**: In Julia, this field accepts and returns `Dict` or `Vector` types, automatically handling the serialization/deserialization.

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

# Multiple ForeignKeys to same model (requires related_name)
Team_radio = Models.Model(
    id = Models.IDField(),
    sender = Models.ForeignKey("Team_member", on_delete="CASCADE", related_name="sent_messages"),
    recipient = Models.ForeignKey("Team_member", on_delete="CASCADE", related_name="received_messages"),
    content = Models.TextField(),
    sent_at = Models.DateTimeField()
)
```

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

### ManyToManyField(to_model)

**Purpose**: Many-to-many relationships through a join table, without adding a column to either related model table.

When `through` is not supplied, PormG migrations synthesize a join table with two foreign keys and a composite unique index. The relation can be traversed in filters and projections with the same double-underscore syntax used by `ForeignKey` joins.

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

Use `through=Existing_model` when the relationship table has extra fields, such as the season when a driver was added to a collection. In that case PormG treats the through model as a normal model and does not auto-generate a join table — including its `db_table`, if it declares one, which then names the join table in every query and mutator. The field-level `db_table` below applies to the auto-generated table only and is ignored when `through` is given.

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
