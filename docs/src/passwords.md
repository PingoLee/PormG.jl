# Password Handling

PormG provides a robust, extensible, and Django-compatible password hashing system. Inspired by Spring Security's architecture and Django's security model, this module ensures that sensitive credentials in your database are handled with industry-standard cryptographic practices.

## Overview

Passwords should never be stored in plain text. PormG facilitates:
- **Hashing**: Transform plain text passwords into secure hashes.
- **Verification**: Match a raw password against its stored hash.
- **Upgrading**: Automatically detect and update old hashes to stronger algorithms or higher work factors as hardware evolves.
- **Validation**: Enforce complexity rules (length, character variety).

## Basic Usage

For most use cases, the convenience functions `make_password` and `check_password` are sufficient.

```julia
using PormG

# Hash a password
# Uses the default algorithm (PBKDF2-SHA256 with 720,000 iterations)
hash = make_password("mypassword123")
# Output example: "pbkdf2_sha256$720000$salt$hash..."

# Verify a password
is_valid = check_password("mypassword123", hash) # true
```

## Domain Example: F1 Driver Portal

In PormG, we focus on the Formula 1 domain. Imagine we are building a private portal for drivers to see their performance telemetry. We need to store their access passwords securely.

```julia
import PormG.models as M
using PormG

# 1. A new Driver (e.g., Ayrton Senna) sets their password
raw_password = "Champion_1988!"
hashed_pw = make_password(raw_password)

# 2. Later, when the Driver attempts to log in:
login_attempt = "Champion_1988!"
# 'current_stored_hash' would typically be fetched from your database
current_stored_hash = hashed_pw 

if check_password(login_attempt, current_stored_hash)
    println("Welcome, Ayrton Senna!")
else
    println("Invalid credentials.")
end
```

## Supported Algorithms

PormG supports multiple hashing algorithms through its `PasswordEncoder` interface.

| Algorithm | Encoder | Notes |
| :--- | :--- | :--- |
| **PBKDF2-SHA256** | `PBKDF2PasswordEncoder` | **Default**. Highly compatible with **Django**. |
| **Spring PBKDF2** | `SpringSecurityPBKDF2PasswordEncoder` | Compatible with **Spring Security**. |
| **BCrypt** | `BCryptPasswordEncoder` | Standard for CPU-bound hashing. |
| **Argon2** | `Argon2PasswordEncoder` | PHC winner. Most secure against GPU/ASIC attacks. (Requires `Argon2.jl`). |

### Changing the Default Algorithm

You can change the default algorithm globally. All subsequent calls to `make_password` will use this setting.

```julia
import PormG.Passwords: set_default_algorithm!

set_default_algorithm!("bcrypt")
new_hash = make_password("secure_pass") # Now uses BCrypt
```

## Advanced Configuration: Custom Encoders

If you need specific work factors (e.g., more iterations for PBKDF2 or a higher cost for BCrypt), you can initialize and use specific encoders directly.

```julia
import PormG.Passwords: PBKDF2PasswordEncoder, BCryptPasswordEncoder, encode, matches

# Higher security PBKDF2 (1 million iterations)
secure_pbkdf2 = PBKDF2PasswordEncoder(iterations=1_000_000)
hash = encode(secure_pbkdf2, "pass123")

# Fast BCrypt for testing (Cost 4)
testing_bcrypt = BCryptPasswordEncoder(cost=4)
hash_bcrypt = encode(testing_bcrypt, "pass123")
```

## Password Validation

To ensure security policies, you can use the `validate_password` utility. This prevents users from choosing dangerously weak passwords.

```julia
using PormG

# Validate a simple password
result = validate_password("weak")

if !result.valid
    for err in result.errors
        println("Validation error: ", err)
    end
end

# Example Policy: Min length 10
result = validate_password("Formula1!", min_length=10) # Fails length check
```

## Internationalization (i18n)

You can customize the error messages returned by the validator to support multiple languages or specific wording requirements. This is done by passing a `messages` dictionary to the `PasswordValidator` or using it through `validate_password` (if supported) or by creating a custom validator instance.

### Customizing Messages

The following keys are supported in the `messages` dictionary:
- `:min_length`: Use `%d` for the length value.
- `:max_length`: Use `%d` for the length value.
- `:require_uppercase`
- `:require_lowercase`
- `:require_digit`
- `:require_special`
- `:common_password`

```julia
using PormG: PasswordValidator, validate

# Define Portuguese messages
pt_messages = Dict(
    :min_length => "A senha deve ter pelo menos %d caracteres",
    :require_digit => "A senha deve conter pelo menos um número",
    :require_uppercase => "A senha deve conter pelo menos uma letra maiúscula"
)

# Initialize validator with custom messages
validator = PasswordValidator(
    min_length=10, 
    messages=pt_messages
)

# Validate a password using the validator object
result = validate(validator, "senha")

# OR use the high-level API directly
using PormG: validate_password
result = validate_password("senha", min_length=10, messages=pt_messages)

if !result.valid
    # errors will contain: ["A senha deve ter pelo menos 10 caracteres", ...]
    println(result.errors) 
end
```

## Upgrading Hashes

As hardware becomes more powerful, old hashes become easier to crack. PormG allows you to detect when a hash should be recalculated with stronger settings.

```julia
using PormG

# Check if a hash needs to be re-hashed
# This returns true if the current default algorithm or work factor is stronger than the hash's
if password_needs_upgrade(stored_hash)
    # Re-hash the raw password and save it
    new_hash = make_password(raw_password)
    # TODO: Update your database record here
end
```

## Django Compatibility

PormG is designed to be a drop-in replacement for Django's password handling in Julia. It uses the exact same storage format:
`pbkdf2_sha256$<iterations>$<salt>$<hash>`

## Spring Security Compatibility

PormG also supports Spring Security's PBKDF2 password format, enabling integrations with Java/Spring applications:

**Spring Security Hash Format:**
`sha256:<iterations>:<keyLength>:<base64_salt>:<base64_hash>`

**Example:**
```julia
import PormG.Passwords: SpringSecurityPBKDF2PasswordEncoder, matches, DelegatingPasswordEncoder

# Hash from a Spring Security application
spring_hash = "sha256:64000:32:gexlBXpu2dKK1BvW2jw8+XZAo99/g9d7:aPXcE36dbNMo0ssJV0QGiX6/r4jHu8HUfvElVQB5erA="

# Option 1: Use the specific encoder
spring_encoder = SpringSecurityPBKDF2PasswordEncoder()
is_valid = matches(spring_encoder, "user_password", spring_hash)

# Option 2: Auto-detection with DelegatingPasswordEncoder (recommended)
delegating = DelegatingPasswordEncoder()
is_valid = matches(delegating, "user_password", spring_hash)  # Auto-detects Spring format!

# Option 3: High-level API (uses auto-detection internally)
using PormG: check_password
is_valid = check_password("user_password", spring_hash)
```

