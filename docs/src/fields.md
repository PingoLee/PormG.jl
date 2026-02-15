# PormG Field Types Reference

This comprehensive guide covers all field types available in PormG, inspired by Django ORM but optimized for Julia. Each field type maps to appropriate data types in PostgreSQL or SQLite and provides validation, constraints, and formatting capabilities.

## Naming Conventions and Considerations

### Field Naming Rules
- **Use lowercase for all field names**: `username`, `email`, `created_at`
- **Use snake_case for multi-word fields**: `first_name`, `last_name`, `birth_date`
- **Never use double underscores (`__`)** in field names or table names (reserved for internal use)
- **Prefix reserved Julia keywords with underscore**: `_id`, `_type`, `_end`, `_function`

### Model Naming Rules
- **Use snake_case with capitalized first letter**: `User`, `Product`, `Order_item`
- **Use singular nouns**: `User` not `Users`, `Product` not `Products`
- **Be descriptive and clear**: `User_profile`, `Product_category`, `Order_history`

### Database Column Mapping
- **Field names automatically become lowercase** in the database
- **PormG handles the conversion**: `firstName` → `firstname` in database
- **Use `db_column` parameter** for custom database column names if needed

### Examples of Good Naming

```julia
# ✅ Good field naming
User = Models.Model(
    _id = Models.IDField(),                    # Reserved word prefixed
    username = Models.CharField(max_length=30), # Lowercase
    first_name = Models.CharField(max_length=50), # Snake_case
    email_address = Models.EmailField(),       # Descriptive
    is_active = Models.BooleanField(),         # Boolean prefix
    created_at = Models.DateTimeField(),       # Timestamp suffix
    birth_date = Models.DateField()            # Clear purpose
)

# ✅ Good model naming
User_profile = Models.Model(...)    # snake_case with capital first letter
Product_category = Models.Model(...)  # Clear relationship
Order_item = Models.Model(...)      # Descriptive compound name
```

### Examples to Avoid

```julia
# ❌ Bad naming practices
user = Models.Model(                    # Should be capitalized
    ID = Models.IDField(),              # Should be _id (reserved word)
    firstName = Models.CharField(),     # Should be first_name
    Email__Address = Models.EmailField(), # Never use __
    type = Models.CharField(),          # Reserved word without prefix
    end = Models.DateField()            # Reserved word without prefix
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
User = Models.Model(
  _id = Models.IDField(),
  username = Models.CharField(max_length=50)
)

# With GENERATED ALWAYS (stricter identity)
Order = Models.Model(
  _id = Models.IDField(generated_always=true),
  total = Models.DecimalField(max_digits=10, decimal_places=2)
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
Category = Models.Model(
    _id = Models.AutoField(),
    name = Models.CharField(max_length=100)
)

# For lookup tables with limited records
Status = Models.Model(
    _id = Models.AutoField(),
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

## Text Fields

### CharField(max_length)

**Purpose**: Variable-length strings with maximum length constraint.

**Database Type**: `VARCHAR(max_length)`

**Use Cases**: Names, titles, codes, short descriptions, enumerated values.

```julia
# Basic string fields
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=30, unique=true),
    email = Models.CharField(max_length=100, unique=true),
    first_name = Models.CharField(max_length=50),
    last_name = Models.CharField(max_length=50)
)

# Field with choices (enum-like behavior)
Order = Models.Model(
    _id = Models.IDField(),
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

# Optional field with custom database column
Product = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    sku = Models.CharField(
        max_length=50, 
        unique=true, 
        db_column="product_sku",
        verbose_name="Product SKU"
    )
)
```

**Key Parameters**:
- `max_length::Int = 250`: Maximum characters (1-255)
- `choices`: Tuple of (value, display_name) pairs
- `unique::Bool = false`: Enforce uniqueness
- `db_index::Bool = false`: Create database index

### TextField()

**Purpose**: Unlimited length text content.

**Database Type**: `TEXT`

**Use Cases**: Articles, descriptions, comments, JSON data, large text content.

```julia
Article = Models.Model(
    _id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    summary = Models.TextField(blank=true, null=true)
)

```

### EmailField()

**Purpose**: Email addresses with built-in validation.

**Database Type**: `VARCHAR` with email validation

**Use Cases**: User emails, contact information, notification addresses.

```julia
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=30),
    email = Models.EmailField(unique=true),
    backup_email = Models.EmailField(null=true, blank=true)
)

# For contact forms
Contact = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=100),
    email = Models.EmailField(),
    message = Models.TextField()
)
```

### PasswordField()

**Purpose**: Secure password storage with Django-compatible PBKDF2-SHA256 hashing.

**Database Type**: `VARCHAR(128)`

**Use Cases**: User authentication, secure credential storage, Django migration compatibility.

The `PasswordField` stores hashed passwords in a format fully compatible with Django's authentication system. Passwords are **never stored in plain text** - they are automatically hashed using PBKDF2-SHA256 with a randomly generated salt and 720,000 iterations (Django 4.2+ default).

**Storage Format**:
```
pbkdf2_sha256$720000$randomsalt$base64encodedHash
```

```julia
# User model with password authentication
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=150, unique=true),
    email = Models.EmailField(unique=true),
    password = Models.PasswordField()
)
```

**Key Parameters**:
- `max_length::Int = 128`: Maximum length for stored hash (Django default)
- `blank::Bool = false`: Whether the field can be left blank
- `null::Bool = false`: Whether NULL values are allowed
- `auto_hash::Bool = true`: Whether to automatically hash passwords

#### Password Utility Functions

PormG provides Django-compatible utility functions for password management:

**`make_password(raw_password)` - Hash a password**:
```julia
import PormG.Models: make_password

# Hash a password before storing
hashed = make_password("mySecurePassword123!")
# => "pbkdf2_sha256$720000$abc123...$base64hash..."

# Custom iterations (for testing - use default in production)
hashed = make_password("password", iterations=100000)
```

**`check_password(raw, encoded)` - Verify a password**:
```julia
import PormG.Models: check_password

# Verify during login
if check_password("myPassword123", user[:password])
    println("Login successful!")
else
    println("Invalid password")
end
```

**`password_needs_upgrade(encoded)` - Check if re-hashing is needed**:
```julia
import PormG.Models: password_needs_upgrade

# After successful login, upgrade old hashes
if password_needs_upgrade(user[:password])
    user[:password] = make_password(raw_password)
    # Save user to database...
end
```

#### Complete Authentication Example (F1 Context)

```julia
import PormG.models as M
import PormG.Models: make_password, check_password
import PormG.QueryBuilder: list, bulk_insert

# Create a team manager account
hashed_password = make_password("McLaren1988!")

query = M.Team_manager.objects
query.bulk_insert(
    username = "ron_dennis",
    email = "ron@mclaren.com",
    password = hashed_password,
    team_id = 1  # McLaren
)

# Login verification
function authenticate(username::String, raw_password::String)
    query = M.Team_manager.objects
    query.filter("username" => username)
    users = query |> list
    
    isempty(users) && return nothing
    user = users[1]
    
    # Verify password with timing-attack protection
    check_password(raw_password, user[:password]) ? user : nothing
end

# Usage
user = authenticate("ron_dennis", "McLaren1988!")
if user !== nothing
    println("Welcome, $(user[:username])!")
end
```

#### Security Notes

- **Never store plain text passwords** - always use `make_password()`
- Default 720,000 iterations provides strong security (NIST-approved)
- Salts are automatically generated per-password (22 characters)
- `check_password()` uses constant-time comparison to prevent timing attacks
- Consider implementing password upgrade on login if using older hashes

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
Product = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    stock_quantity = Models.IntegerField(default=0),
    min_stock_level = Models.IntegerField(default=10)
)

# Rating systems
Review = Models.Model(
    _id = Models.IDField(),
    product = Models.ForeignKey("Product"),
    rating = Models.IntegerField(),  # 1-5 stars
    helpful_votes = Models.IntegerField(default=0)
)

# Age and demographic data
User = Models.Model(
    _id = Models.IDField(),
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
Analytics = Models.Model(
    _id = Models.IDField(),
    page_views = Models.BigIntegerField(default=0),
    unique_visitors = Models.BigIntegerField(default=0),
    bytes_transferred = Models.BigIntegerField(default=0)
)

# Timestamp storage (Unix timestamp)
Event = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=100),
    timestamp_ms = Models.BigIntegerField(),  # Milliseconds since epoch
    user_id = Models.BigIntegerField()
)
```

### FloatField()

**Purpose**: Double-precision floating-point numbers for measurements and calculations.

**Database Type**: `DOUBLE PRECISION`

```julia
# Scientific measurements
Sensor = Models.Model(
    _id = Models.IDField(),
    temperature = Models.FloatField(),  # Celsius
    humidity = Models.FloatField(),     # Percentage
    pressure = Models.FloatField()      # hPa
)

# Geographic coordinates
Location = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=100),
    latitude = Models.FloatField(),
    longitude = Models.FloatField(),
    elevation = Models.FloatField(null=true)  # Meters above sea level
)

# Financial calculations (use DecimalField for currency)
Performance = Models.Model(
    _id = Models.IDField(),
    growth_rate = Models.FloatField(),      # Percentage
    volatility = Models.FloatField(),       # Standard deviation
    beta = Models.FloatField(null=true)     # Market correlation
)
```

### DecimalField(max_digits, decimal_places)

**Purpose**: Precise decimal numbers for financial and monetary data.

**Database Type**: `NUMERIC(max_digits, decimal_places)`

**Use Cases**: Currency, financial calculations, precise measurements.

```julia
# Financial data
Order = Models.Model(
    _id = Models.IDField(),
    subtotal = Models.DecimalField(max_digits=10, decimal_places=2),
    tax_amount = Models.DecimalField(max_digits=8, decimal_places=2),
    total_amount = Models.DecimalField(max_digits=10, decimal_places=2),
    discount_rate = Models.DecimalField(max_digits=5, decimal_places=4)  # 0.1234 = 12.34%
)

# Product pricing
Product = Models.Model(
    _id = Models.IDField(),
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

```julia
# Personal information
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=30),
    birth_date = Models.DateField(null=true),
    registration_date = Models.DateField()
)

# Event scheduling
Event = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    event_date = Models.DateField(),
    registration_deadline = Models.DateField(null=true)
)

# Business records
Invoice = Models.Model(
    _id = Models.IDField(),
    invoice_number = Models.CharField(max_length=50),
    issue_date = Models.DateField(),
    due_date = Models.DateField(),
    paid_date = Models.DateField(null=true)
)
```

### DateTimeField()

**Purpose**: Date and time with timezone support.

**Database Type**: `TIMESTAMP WITH TIME ZONE`

**Use Cases**: Timestamps, logs, audit trails, precise timing.

```julia
# Audit and logging
AuditLog = Models.Model(
    _id = Models.IDField(),
    user = Models.ForeignKey("User"),
    action = Models.CharField(max_length=100),
    timestamp = Models.DateTimeField(),
    ip_address = Models.CharField(max_length=45)
)

# Content management
Article = Models.Model(
    _id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    created_at = Models.DateTimeField(),
    updated_at = Models.DateTimeField(),
    published_at = Models.DateTimeField(null=true)
)

# E-commerce
Order = Models.Model(
    _id = Models.IDField(),
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
# Business hours
Store = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=100),
    opening_time = Models.TimeField(),
    closing_time = Models.TimeField()
)

# Scheduling
Appointment = Models.Model(
    _id = Models.IDField(),
    date = Models.DateField(),
    start_time = Models.TimeField(),
    end_time = Models.TimeField(),
    patient = Models.ForeignKey("Patient")
)

# Sports and timing
Race = Models.Model(
    _id = Models.IDField(),
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
Task = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    estimated_duration = Models.DurationField(),
    actual_duration = Models.DurationField(null=true)
)

# Media content
Video = Models.Model(
    _id = Models.IDField(),
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
# User preferences and flags
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=30),
    is_active = Models.BooleanField(default=true),
    is_staff = Models.BooleanField(default=false),
    is_superuser = Models.BooleanField(default=false),
    email_notifications = Models.BooleanField(default=true),
    newsletter_subscription = Models.BooleanField(default=false)
)

# Content moderation
Article = Models.Model(
    _id = Models.IDField(),
    title = Models.CharField(max_length=200),
    content = Models.TextField(),
    is_published = Models.BooleanField(default=false),
    is_featured = Models.BooleanField(default=false),
    allow_comments = Models.BooleanField(default=true)
)

# System settings
Configuration = Models.Model(
    _id = Models.IDField(),
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

**Use Cases**: Photo uploads, galleries, avatars, product images.

```julia
# User profiles
User_profile = Models.Model(
    _id = Models.IDField(),
    user = Models.OneToOneField("User"),
    avatar = Models.ImageField(null=true, blank=true),
    cover_photo = Models.ImageField(null=true, blank=true)
)

# Product catalog
Product = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    main_image = Models.ImageField(),
    thumbnail = Models.ImageField(null=true)
)

# Gallery system
Photo = Models.Model(
    _id = Models.IDField(),
    title = Models.CharField(max_length=200),
    image = Models.ImageField(),
    caption = Models.TextField(blank=true),
    upload_date = Models.DateTimeField()
)
```

### BinaryField()

**Purpose**: Binary data storage for files and encrypted content.

**Database Type**: `BYTEA`

**Use Cases**: File storage, encrypted data, binary documents.

```julia
# Document storage
Document = Models.Model(
    _id = Models.IDField(),
    name = Models.CharField(max_length=200),
    file_data = Models.BinaryField(),
    mime_type = Models.CharField(max_length=100),
    file_size = Models.IntegerField()
)

# Encryption and security
SecureData = Models.Model(
    _id = Models.IDField(),
    user = Models.ForeignKey("User"),
    encrypted_content = Models.BinaryField(),
    encryption_key_hash = Models.CharField(max_length=64)
)
```

---

## Relationship Fields

### ForeignKey(to_model)

**Purpose**: Many-to-one relationships linking records to a single target record.

**Database Type**: `BIGINT` with foreign key constraint

**Use Cases**: Categories, users, parent-child relationships.

```julia
# Blog system
Article = Models.Model(
    _id = Models.IDField(),
    title = Models.CharField(max_length=200),
    author = Models.ForeignKey("User", on_delete="CASCADE"),
    category = Models.ForeignKey("Category", on_delete="PROTECT"),
    content = Models.TextField()
)

# E-commerce
Order = Models.Model(
    _id = Models.IDField(),
    customer = Models.ForeignKey("User", on_delete="PROTECT"),
    shipping_address = Models.ForeignKey("Address", on_delete="SET_NULL", null=true),
    total_amount = Models.DecimalField(max_digits=10, decimal_places=2)
)

Order_item = Models.Model(
    _id = Models.IDField(),
    order = Models.ForeignKey("Order", on_delete="CASCADE"),
    product = Models.ForeignKey("Product", on_delete="PROTECT"),
    quantity = Models.IntegerField(),
    unit_price = Models.DecimalField(max_digits=8, decimal_places=2)
)

# Multiple ForeignKeys to same model (requires related_name)
Message = Models.Model(
    _id = Models.IDField(),
    sender = Models.ForeignKey("User", on_delete="CASCADE", related_name="sent_messages"),
    recipient = Models.ForeignKey("User", on_delete="CASCADE", related_name="received_messages"),
    content = Models.TextField(),
    sent_at = Models.DateTimeField()
)
```

**On Delete Options**:
- `CASCADE`: Delete this record when target is deleted
- `RESTRICT`: Prevent deletion of target if this record exists
- `SET_NULL`: Set field to NULL (requires `null=true`)
- `SET_DEFAULT`: Set to default value
- `PROTECT`: Raise error to prevent deletion
- `DO_NOTHING`: No action (may cause integrity errors)

### OneToOneField(to_model)

**Purpose**: Strict one-to-one relationships where each record corresponds to exactly one target record.

**Database Type**: `BIGINT` with unique foreign key constraint

**Use Cases**: User profiles, settings, model extensions.

```julia
# User profile extension
User_profile = Models.Model(
    _id = Models.IDField(),
    user = Models.OneToOneField("User", on_delete="CASCADE"),
    bio = Models.TextField(blank=true),
    birth_date = Models.DateField(null=true),
    website = Models.CharField(max_length=200, blank=true),
    location = Models.CharField(max_length=100, blank=true)
)

# Employee details
Employee_profile = Models.Model(
    _id = Models.IDField(),
    user = Models.OneToOneField("User", on_delete="CASCADE"),
    employee_id = Models.CharField(max_length=20, unique=true),
    department = Models.ForeignKey("Department"),
    hire_date = Models.DateField(),
    salary = Models.DecimalField(max_digits=10, decimal_places=2)
)

# Settings and preferences
User_settings = Models.Model(
    _id = Models.IDField(),
    user = Models.OneToOneField("User", on_delete="CASCADE"),
    theme = Models.CharField(max_length=20, default="light"),
    language = Models.CharField(max_length=10, default="en"),
    notifications_enabled = Models.BooleanField(default=true)
)
```

---

## Common Field Options

All field types support these common parameters:

### Validation Options
- `null::Bool = false`: Allow NULL values in database
- `blank::Bool = false`: Allow empty values in forms  
- `unique::Bool = false`: Enforce uniqueness constraint
- `default`: Set default value for new records

### Database Options
- `db_index::Bool = false`: Create database index for faster queries
- `db_column::Union{String, Nothing} = nothing`: Custom database column name
- `db_constraint::Bool = true`: Create database constraints (for relationships)

### Example with All Common Options
```julia
Product = Models.Model(
    _id = Models.IDField(),
    
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
        "Category",
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
author = Models.ForeignKey("User", on_delete="CASCADE")  # Must reference valid User

# One-to-one validation
profile = Models.OneToOneField("User_profile")  # Must be unique relationship
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
User = Models.Model(
    _id = Models.IDField(),
    username = Models.CharField(max_length=30),
    email = Models.CharField(max_length=100)
)

# Version 2: Safe additions
User = Models.Model(
    _id = Models.IDField(),
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


---

This comprehensive guide covers all field types available in PormG. For specific implementation details and advanced usage, refer to the source code in `src/Models.jl` and the test examples in the `test/` directory.
