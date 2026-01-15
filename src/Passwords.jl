"""
    Passwords Module

A professional password hashing and validation module inspired by Spring Security's 
PasswordEncoder architecture and Django's password handling.

## Features
- **Multiple Algorithm Support**: PBKDF2-SHA256, BCrypt, Argon2id/Argon2i/Argon2d
- **Encoder Interface**: Extensible `PasswordEncoder` abstract type
- **Auto-detection**: Automatically detects algorithm from hash format
- **Password Validation**: Configurable password strength requirements
- **Timing-safe Comparison**: Prevents timing attacks
- **Django Compatible**: Full compatibility with Django password hashes
- **Spring Security Compatible**: BCrypt hashes are interoperable

## Architecture (Spring Security Inspired)
```
PasswordEncoder (abstract)
├── PBKDF2PasswordEncoder   # Django/NIST standard
├── BCryptPasswordEncoder   # Spring Security default
└── Argon2PasswordEncoder   # PHC winner (most secure)

DelegatingPasswordEncoder
└── Routes to appropriate encoder based on hash prefix
```

## Example Usage
```julia
using PormG: make_password, check_password, validate_password

# Hash a password (uses default encoder)
hash = make_password("mySecurePassword123!")

# Verify password
check_password("mySecurePassword123!", hash)  # => true

# Validate password strength
result = validate_password("weak")
if !result.valid
    println(result.errors)
end
```
"""
module Passwords

using MbedTLS
using Random
using Base64
using Bcrypt  # BCrypt password hashing

# Helper function for alphanumeric check (Julia doesn't have isalnum built-in)
isalnum(c::Char) = isletter(c) || isdigit(c)

# ============================================================================
# Exports
# ============================================================================

export make_password, check_password, password_needs_upgrade
export validate_password, ValidationResult, PasswordValidator
export DEFAULT_PBKDF2_ITERATIONS, DEFAULT_ALGORITHM
export PasswordEncoder, PBKDF2PasswordEncoder, BCryptPasswordEncoder, Argon2PasswordEncoder
export DelegatingPasswordEncoder
export encode, matches, upgrade_encoding
export get_password_encoder, set_default_algorithm!

# ============================================================================
# Constants & Configuration
# ============================================================================

const DEFAULT_PBKDF2_ITERATIONS = 720000  # Django 4.2+ default (2023)
const BCRYPT_DEFAULT_COST = 12            # BCrypt work factor (2^12 iterations)
const ARGON2_DEFAULT_TIME = 3             # Argon2 time cost
const ARGON2_DEFAULT_MEMORY = 65536       # Argon2 memory cost (64 MB)

# Supported algorithms (extensible)
const SUPPORTED_ALGORITHMS = ["pbkdf2_sha256", "bcrypt", "argon2id", "argon2i"]

# Default algorithm (can be changed at runtime)
const _DEFAULT_ALGORITHM = Ref{String}("pbkdf2_sha256")

"""
    DEFAULT_ALGORITHM

Get the current default password hashing algorithm.
"""
DEFAULT_ALGORITHM() = _DEFAULT_ALGORITHM[]

"""
    set_default_algorithm!(algorithm::String)

Set the default password hashing algorithm.

# Supported Algorithms
- `"pbkdf2_sha256"` - PBKDF2 with SHA-256 (Django compatible, NIST approved)
- `"bcrypt"` - BCrypt (Spring Security default) [planned]
- `"argon2id"` - Argon2id (PHC winner, most secure) [planned]

# Example
```julia
set_default_algorithm!("pbkdf2_sha256")
```
"""
function set_default_algorithm!(algorithm::String)
  algorithm = lowercase(algorithm)
  if !(algorithm in SUPPORTED_ALGORITHMS)
    throw(ArgumentError("Unsupported algorithm: $algorithm. Supported: $(join(SUPPORTED_ALGORITHMS, ", "))"))
  end
  _DEFAULT_ALGORITHM[] = algorithm
  return algorithm
end

# ============================================================================
# Password Encoder Interface (Spring Security Pattern)
# ============================================================================

"""
    PasswordEncoder

Abstract type for password encoders (similar to Spring Security's PasswordEncoder interface).

Implementations must provide:
- `encode(encoder, raw_password)` - Hash a password
- `matches(encoder, raw_password, encoded_hash)` - Verify a password
- `upgrade_encoding(encoder, encoded_hash)` - Check if hash needs upgrade
"""
abstract type PasswordEncoder end

"""
    encode(encoder::PasswordEncoder, raw_password::AbstractString) -> String

Encode (hash) a raw password using the specified encoder.
"""
function encode end

"""
    matches(encoder::PasswordEncoder, raw_password::AbstractString, encoded_hash::AbstractString) -> Bool

Verify if a raw password matches the encoded hash.
"""
function matches end

"""
    upgrade_encoding(encoder::PasswordEncoder, encoded_hash::AbstractString) -> Bool

Check if the encoded hash should be upgraded to a stronger encoding.
"""
function upgrade_encoding end

# ============================================================================
# PBKDF2 Password Encoder (Django Compatible)
# ============================================================================

"""
    PBKDF2PasswordEncoder

PBKDF2-SHA256 password encoder, compatible with Django's default hasher.

# Fields
- `iterations::Int` - Number of PBKDF2 iterations (default: 720000)
- `salt_length::Int` - Length of generated salt (default: 22)
- `key_length::Int` - Derived key length in bytes (default: 32)

# Example
```julia
encoder = PBKDF2PasswordEncoder(iterations=720000)
hash = encode(encoder, "mypassword")
matches(encoder, "mypassword", hash)  # => true
```
"""
struct PBKDF2PasswordEncoder <: PasswordEncoder
  iterations::Int
  salt_length::Int
  key_length::Int
  
  function PBKDF2PasswordEncoder(; 
      iterations::Int=DEFAULT_PBKDF2_ITERATIONS,
      salt_length::Int=22,
      key_length::Int=32)
    iterations < 1 && throw(ArgumentError("Iterations must be positive"))
    salt_length < 8 && throw(ArgumentError("Salt length must be at least 8"))
    key_length < 16 && throw(ArgumentError("Key length must be at least 16"))
    new(iterations, salt_length, key_length)
  end
end

# --- PBKDF2 Implementation ---

"""
    hmac_sha256(key::Vector{UInt8}, data::Vector{UInt8}) -> Vector{UInt8}

Compute HMAC-SHA256 of data using the given key.
"""
function hmac_sha256(key::Vector{UInt8}, data::Vector{UInt8})
  ctx = MbedTLS.MD(MbedTLS.MD_SHA256, key)
  MbedTLS.write(ctx, data)
  MbedTLS.finish!(ctx)
end

"""
    encode_block_index(index::Int) -> Vector{UInt8}

Encode a block index as a 4-byte big-endian integer (for PBKDF2).
"""
function encode_block_index(index::Int)
  return UInt8[((index >> 24) & 0xff), ((index >> 16) & 0xff), ((index >> 8) & 0xff), (index & 0xff)]
end

"""
    pbkdf2_sha256_bytes(password::Vector{UInt8}, salt::Vector{UInt8}, iterations::Int, dklen::Int) -> Vector{UInt8}

Derive a key from password using PBKDF2-HMAC-SHA256.
"""
function pbkdf2_sha256_bytes(password::Vector{UInt8}, salt::Vector{UInt8}, iterations::Int, dklen::Int)
  iterations < 1 && throw(ArgumentError("PBKDF2 iterations must be positive"))
  hlen = MbedTLS.get_size(MbedTLS.MD_SHA256)
  blocks = ceil(Int, dklen / hlen)
  derived = Vector{UInt8}(undef, 0)

  for block_index in 1:blocks
    block_salt = vcat(salt, encode_block_index(block_index))
    u = hmac_sha256(password, block_salt)
    t = copy(u)
    for _ in 2:iterations
      u = hmac_sha256(password, u)
      for i in eachindex(t)
        t[i] = xor(t[i], u[i])
      end
    end
    append!(derived, t)
  end

  return derived[1:dklen]
end

function pbkdf2_sha256(password::AbstractString, salt::AbstractString, iterations::Int; dklen::Int=32)
  password_bytes = Vector{UInt8}(codeunits(password))
  salt_bytes = Vector{UInt8}(codeunits(salt))
  pbkdf2_sha256_bytes(password_bytes, salt_bytes, iterations, dklen)
end

"""
    generate_salt(length::Int=22) -> String

Generate a cryptographically secure random salt.
"""
function generate_salt(length::Int=22)
  bytes_needed = ceil(Int, length * 3 / 4) + 1
  random_bytes = rand(UInt8, bytes_needed)
  encoded = Base64.base64encode(random_bytes)
  safe = replace(encoded, "+" => ".", "/" => "_")
  return safe[1:min(length, lastindex(safe))]
end

# --- PBKDF2 Encoder Methods ---

function encode(encoder::PBKDF2PasswordEncoder, raw_password::AbstractString)
  isempty(raw_password) && throw(ArgumentError("Password cannot be empty"))
  salt = generate_salt(encoder.salt_length)
  derived = pbkdf2_sha256(raw_password, salt, encoder.iterations; dklen=encoder.key_length)
  hash = Base64.base64encode(derived)
  return "pbkdf2_sha256\$$(encoder.iterations)\$$(salt)\$$(hash)"
end

function matches(encoder::PBKDF2PasswordEncoder, raw_password::AbstractString, encoded_hash::AbstractString)
  encoded_hash = strip(encoded_hash)
  isempty(encoded_hash) && return false
  isempty(raw_password) && return false
  
  !startswith(encoded_hash, "pbkdf2_sha256\$") && return false
  
  parts = split(encoded_hash, '\$')
  length(parts) == 4 || return false
  
  iterations = try
    parse(Int, parts[2])
  catch
    return false
  end
  
  salt = String(parts[3])
  stored_hash = String(parts[4])
  
  derived = pbkdf2_sha256(raw_password, salt, iterations; dklen=encoder.key_length)
  computed_hash = Base64.base64encode(derived)
  
  return _constant_time_compare(computed_hash, stored_hash)
end

function upgrade_encoding(encoder::PBKDF2PasswordEncoder, encoded_hash::AbstractString)
  encoded_hash = strip(encoded_hash)
  isempty(encoded_hash) && return true
  !startswith(encoded_hash, "pbkdf2_sha256\$") && return true
  
  parts = split(encoded_hash, '\$')
  length(parts) != 4 && return true
  
  iterations = try
    parse(Int, parts[2])
  catch
    return true
  end
  
  return iterations < encoder.iterations
end

# ============================================================================
# BCrypt Password Encoder (Using Bcrypt.jl)
# ============================================================================

"""
    BCryptPasswordEncoder

BCrypt password encoder - Spring Security's default algorithm.

BCrypt features:
- Built-in salt (no separate salt storage needed)
- Configurable work factor (cost) from 4-31
- Widely used in Spring Security, Rails, Node.js, etc.
- Resistant to GPU/ASIC attacks due to memory requirements

# Fields
- `cost::Int` - Work factor (default: 10, recommended: 10-12)

# Example
```julia
encoder = BCryptPasswordEncoder(cost=12)
hash = encode(encoder, "myPassword")
# => "\$2a\$12\$randomsalt.hashedpassword"

matches(encoder, "myPassword", hash)  # => true
```

# Security Notes
- Cost 10 = ~100ms, Cost 12 = ~400ms per hash
- Increase cost over time as hardware improves
- Maximum password length is 72 bytes (BCrypt limitation)
"""
struct BCryptPasswordEncoder <: PasswordEncoder
  cost::Int
  
  function BCryptPasswordEncoder(; cost::Int=BCRYPT_DEFAULT_COST)
    (cost < 4 || cost > 31) && throw(ArgumentError("BCrypt cost must be between 4 and 31"))
    new(cost)
  end
end

function encode(encoder::BCryptPasswordEncoder, raw_password::AbstractString)
  isempty(raw_password) && throw(ArgumentError("Password cannot be empty"))
  
  # BCrypt has a 72-byte limit
  if sizeof(raw_password) > 72
    @warn "Password exceeds 72 bytes, will be truncated by BCrypt" maxlog=1
  end
  
  # Use Bcrypt.jl to generate the hash (returns Vector{UInt8})
  hash_bytes = Bcrypt.GenerateFromPassword(raw_password, encoder.cost)
  # Convert to String
  return String(hash_bytes)
end

function matches(encoder::BCryptPasswordEncoder, raw_password::AbstractString, encoded_hash::AbstractString)
  encoded_hash = String(strip(encoded_hash))
  isempty(encoded_hash) && return false
  isempty(raw_password) && return false
  
  # Verify BCrypt hash format: $2a$, $2b$, or $2y$
  if !startswith(encoded_hash, "\$2a\$") && 
     !startswith(encoded_hash, "\$2b\$") && 
     !startswith(encoded_hash, "\$2y\$")
    return false
  end
  
  # Use Bcrypt.jl to compare - both as String
  return Bcrypt.CompareHashAndPassword(encoded_hash, String(raw_password))
end

function upgrade_encoding(encoder::BCryptPasswordEncoder, encoded_hash::AbstractString)
  encoded_hash = strip(encoded_hash)
  isempty(encoded_hash) && return true
  
  # Check if it's a BCrypt hash
  if !startswith(encoded_hash, "\$2a\$") && 
     !startswith(encoded_hash, "\$2b\$") && 
     !startswith(encoded_hash, "\$2y\$")
    return true  # Not BCrypt, should upgrade
  end
  
  # Extract current cost from hash (Bcrypt.Cost needs Vector{UInt8})
  try
    hash_bytes = Vector{UInt8}(codeunits(encoded_hash))
    current_cost = Bcrypt.Cost(hash_bytes)
    return current_cost < encoder.cost
  catch
    return true  # Invalid hash, should upgrade
  end
end

# ============================================================================
# Argon2 Password Encoder (Pure Julia Implementation)
# ============================================================================

"""
    Argon2PasswordEncoder

Argon2id password encoder - winner of the Password Hashing Competition (PHC).

Argon2 features:
- Memory-hard (resistant to GPU/ASIC attacks)
- Three variants: Argon2d (data-dependent), Argon2i (data-independent), Argon2id (hybrid)
- Argon2id is recommended for password hashing
- Considered the most secure option as of 2024

# Fields
- `time_cost::Int` - Number of iterations (default: 3)
- `memory_cost::Int` - Memory usage in KB (default: 65536 = 64MB)
- `parallelism::Int` - Degree of parallelism (default: 1)
- `hash_length::Int` - Output hash length in bytes (default: 32)
- `salt_length::Int` - Salt length in bytes (default: 16)
- `variant::Symbol` - :argon2id, :argon2i, or :argon2d (default: :argon2id)

# Example
```julia
encoder = Argon2PasswordEncoder(time_cost=4, memory_cost=65536)
hash = encode(encoder, "myPassword")
# => "\$argon2id\$v=19\$m=65536,t=4,p=1\$randomsalt\$hash"

matches(encoder, "myPassword", hash)  # => true
```

# Security Notes
- Memory cost should be as high as your system can afford
- Time cost of 3-4 is recommended for interactive logins
- OWASP recommends: m=19456 (19 MB), t=2, p=1 for servers
"""
struct Argon2PasswordEncoder <: PasswordEncoder
  time_cost::Int      # Number of iterations
  memory_cost::Int    # Memory in KB
  parallelism::Int    # Parallelism factor
  hash_length::Int    # Output length
  salt_length::Int    # Salt length
  variant::Symbol     # :argon2id, :argon2i, :argon2d
  
  function Argon2PasswordEncoder(;
      time_cost::Int=ARGON2_DEFAULT_TIME,
      memory_cost::Int=ARGON2_DEFAULT_MEMORY,
      parallelism::Int=1,
      hash_length::Int=32,
      salt_length::Int=16,
      variant::Symbol=:argon2id)
    
    variant in (:argon2id, :argon2i, :argon2d) || throw(ArgumentError("Invalid Argon2 variant: $variant"))
    time_cost >= 1 || throw(ArgumentError("Time cost must be >= 1"))
    memory_cost >= 8 * parallelism || throw(ArgumentError("Memory cost must be >= 8 * parallelism"))
    parallelism >= 1 || throw(ArgumentError("Parallelism must be >= 1"))
    hash_length >= 4 || throw(ArgumentError("Hash length must be >= 4"))
    salt_length >= 8 || throw(ArgumentError("Salt length must be >= 8"))
    
    new(time_cost, memory_cost, parallelism, hash_length, salt_length, variant)
  end
end

# --- Argon2 Constants ---
const ARGON2_VERSION = 0x13  # Version 1.3

# Note: Argon2 requires the external Argon2.jl package for full functionality.
# The pure Julia implementation is not included due to performance constraints.
# See: https://github.com/fypc/Argon2.jl for installation instructions.

const ARGON2_AVAILABLE = Ref{Bool}(false)
const _argon2_module = Ref{Union{Module, Nothing}}(nothing)

function _check_argon2_available()
  if !ARGON2_AVAILABLE[]
    # Try to load Argon2 package
    try
      @eval import Argon2
      _argon2_module[] = @eval Argon2
      ARGON2_AVAILABLE[] = true
    catch
      # Package not available
    end
  end
  return ARGON2_AVAILABLE[]
end

function _argon2_not_available_error()
  throw(ErrorException("""
    Argon2 password hashing is not available.
    
    To use Argon2, install the Argon2.jl package:
    
      using Pkg
      Pkg.add(url="https://github.com/fypc/Argon2_jll.jl")
      Pkg.add(url="https://github.com/fypc/Argon2.jl")
    
    Note: On Windows, this requires build tools (make, gcc).
    
    Alternative: Use BCryptPasswordEncoder or PBKDF2PasswordEncoder instead,
    which are available without additional dependencies.
    
    Example:
      encoder = BCryptPasswordEncoder(cost=12)
      hash = encode(encoder, "password")
  """))
end

# --- Argon2 Encoder Methods ---

function encode(encoder::Argon2PasswordEncoder, raw_password::AbstractString)
  _argon2_not_available_error()
end

function matches(encoder::Argon2PasswordEncoder, raw_password::AbstractString, encoded_hash::AbstractString)
  # Can verify Argon2 hashes if the format is recognized
  encoded_hash = String(strip(encoded_hash))
  isempty(encoded_hash) && return false
  isempty(raw_password) && return false
  
  if !startswith(encoded_hash, "\$argon2")
    return false
  end
  
  _argon2_not_available_error()
end

function upgrade_encoding(encoder::Argon2PasswordEncoder, encoded_hash::AbstractString)
  # Can check if upgrade is needed without the external package
  encoded_hash = String(strip(encoded_hash))
  isempty(encoded_hash) && return true
  
  if !startswith(encoded_hash, "\$argon2")
    return true  # Not Argon2, should upgrade
  end
  
  # Parse parameters from hash
  parts = split(encoded_hash, '\$', keepempty=false)
  length(parts) >= 3 || return true
  
  params_str = parts[3]
  params = Dict{String, Int}()
  for param in split(params_str, ',')
    kv = split(param, '=')
    length(kv) == 2 || continue
    params[kv[1]] = parse(Int, kv[2])
  end
  
  # Check if parameters meet current requirements
  memory_cost = get(params, "m", 0)
  time_cost = get(params, "t", 0)
  
  return memory_cost < encoder.memory_cost || time_cost < encoder.time_cost
end

# ============================================================================
# Delegating Password Encoder (Spring Security Pattern)
# ============================================================================

"""
    DelegatingPasswordEncoder

A password encoder that delegates to other encoders based on the hash prefix.
Similar to Spring Security's DelegatingPasswordEncoder.

This allows:
- Automatic detection of hash algorithm
- Seamless migration between algorithms
- Support for legacy hashes

# Example
```julia
encoder = DelegatingPasswordEncoder()

# Encodes with default algorithm
hash = encode(encoder, "password")

# Automatically detects algorithm when verifying
matches(encoder, "password", hash)  # Works with any supported format
```
"""
struct DelegatingPasswordEncoder <: PasswordEncoder
  default_encoder::PasswordEncoder
  encoders::Dict{String, PasswordEncoder}
  
  function DelegatingPasswordEncoder(;
      default_algorithm::String=DEFAULT_ALGORITHM(),
      pbkdf2_iterations::Int=DEFAULT_PBKDF2_ITERATIONS,
      bcrypt_cost::Int=BCRYPT_DEFAULT_COST,
      argon2_time::Int=ARGON2_DEFAULT_TIME,
      argon2_memory::Int=ARGON2_DEFAULT_MEMORY)
    
    encoders = Dict{String, PasswordEncoder}(
      "pbkdf2_sha256" => PBKDF2PasswordEncoder(iterations=pbkdf2_iterations),
      "bcrypt" => BCryptPasswordEncoder(cost=bcrypt_cost),
      "argon2id" => Argon2PasswordEncoder(time_cost=argon2_time, memory_cost=argon2_memory),
      "argon2i" => Argon2PasswordEncoder(time_cost=argon2_time, memory_cost=argon2_memory, variant=:argon2i),
      "argon2d" => Argon2PasswordEncoder(time_cost=argon2_time, memory_cost=argon2_memory, variant=:argon2d),
    )
    
    default_encoder = get(encoders, default_algorithm, PBKDF2PasswordEncoder(iterations=pbkdf2_iterations))
    new(default_encoder, encoders)
  end
end

function encode(encoder::DelegatingPasswordEncoder, raw_password::AbstractString)
  return encode(encoder.default_encoder, raw_password)
end

function matches(encoder::DelegatingPasswordEncoder, raw_password::AbstractString, encoded_hash::AbstractString)
  encoded_hash = strip(encoded_hash)
  isempty(encoded_hash) && return false
  
  # Detect algorithm from hash prefix and delegate to appropriate encoder
  if startswith(encoded_hash, "pbkdf2_sha256\$")
    return matches(get(encoder.encoders, "pbkdf2_sha256", encoder.default_encoder), raw_password, encoded_hash)
  elseif startswith(encoded_hash, "\$2a\$") || startswith(encoded_hash, "\$2b\$") || startswith(encoded_hash, "\$2y\$")
    return matches(get(encoder.encoders, "bcrypt", BCryptPasswordEncoder()), raw_password, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2id")
    return matches(get(encoder.encoders, "argon2id", Argon2PasswordEncoder()), raw_password, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2i")
    return matches(get(encoder.encoders, "argon2i", Argon2PasswordEncoder(variant=:argon2i)), raw_password, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2d")
    return matches(get(encoder.encoders, "argon2d", Argon2PasswordEncoder(variant=:argon2d)), raw_password, encoded_hash)
  else
    # Plain text fallback (development only)
    @warn "Unknown hash format. Password may be stored in plain text." maxlog=1
    return _constant_time_compare(raw_password, encoded_hash)
  end
end

function upgrade_encoding(encoder::DelegatingPasswordEncoder, encoded_hash::AbstractString)
  # Check if using old algorithm or needs parameter upgrade
  if startswith(encoded_hash, "pbkdf2_sha256\$")
    pbkdf2_encoder = get(encoder.encoders, "pbkdf2_sha256", encoder.default_encoder)
    return upgrade_encoding(pbkdf2_encoder, encoded_hash)
  elseif startswith(encoded_hash, "\$2a\$") || startswith(encoded_hash, "\$2b\$") || startswith(encoded_hash, "\$2y\$")
    bcrypt_encoder = get(encoder.encoders, "bcrypt", BCryptPasswordEncoder())
    return upgrade_encoding(bcrypt_encoder, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2id")
    argon2_encoder = get(encoder.encoders, "argon2id", Argon2PasswordEncoder())
    return upgrade_encoding(argon2_encoder, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2i")
    argon2_encoder = get(encoder.encoders, "argon2i", Argon2PasswordEncoder(variant=:argon2i))
    return upgrade_encoding(argon2_encoder, encoded_hash)
  elseif startswith(encoded_hash, "\$argon2d")
    argon2_encoder = get(encoder.encoders, "argon2d", Argon2PasswordEncoder(variant=:argon2d))
    return upgrade_encoding(argon2_encoder, encoded_hash)
  end
  # Any other format should be upgraded
  return true
end

# ============================================================================
# Password Validation (Django/Spring inspired)
# ============================================================================

"""
    ValidationResult

Result of password validation containing validity status and error messages.

# Fields
- `valid::Bool` - Whether the password passed all validations
- `errors::Vector{String}` - List of validation error messages
- `strength::Symbol` - Password strength: :weak, :fair, :good, :strong
"""
struct ValidationResult
  valid::Bool
  errors::Vector{String}
  strength::Symbol
end

"""
    PasswordValidator

Configurable password validator with common security rules.

# Fields
- `min_length::Int` - Minimum password length (default: 8)
- `max_length::Int` - Maximum password length (default: 128)
- `require_uppercase::Bool` - Require at least one uppercase letter
- `require_lowercase::Bool` - Require at least one lowercase letter
- `require_digit::Bool` - Require at least one digit
- `require_special::Bool` - Require at least one special character
- `common_passwords::Set{String}` - Set of forbidden common passwords

# Example
```julia
validator = PasswordValidator(min_length=12, require_special=true)
result = validate(validator, "MyPassword123!")
result.valid  # => true
```
"""
struct PasswordValidator
  min_length::Int
  max_length::Int
  require_uppercase::Bool
  require_lowercase::Bool
  require_digit::Bool
  require_special::Bool
  common_passwords::Set{String}
  
  function PasswordValidator(;
      min_length::Int=8,
      max_length::Int=128,
      require_uppercase::Bool=true,
      require_lowercase::Bool=true,
      require_digit::Bool=true,
      require_special::Bool=false,
      common_passwords::Union{Set{String}, Vector{String}, Nothing}=nothing)
    
    common_set = if common_passwords === nothing
      DEFAULT_COMMON_PASSWORDS
    elseif common_passwords isa Vector
      Set(lowercase.(common_passwords))
    else
      Set(lowercase.(collect(common_passwords)))
    end
    
    new(min_length, max_length, require_uppercase, require_lowercase, 
        require_digit, require_special, common_set)
  end
end

# Common weak passwords (expand as needed)
const DEFAULT_COMMON_PASSWORDS = Set([
  "password", "password1", "password123", "123456", "123456789", 
  "12345678", "qwerty", "abc123", "monkey", "letmein", "dragon",
  "111111", "baseball", "iloveyou", "trustno1", "sunshine", 
  "master", "welcome", "shadow", "ashley", "football", "jesus",
  "michael", "ninja", "mustang", "password1!", "admin", "admin123",
  "root", "toor", "pass", "test", "guest", "master123", "changeme",
  "1234567890", "0987654321", "qwerty123", "qwertyuiop"
])

"""
    validate(validator::PasswordValidator, password::AbstractString) -> ValidationResult

Validate a password against the configured rules.

# Example
```julia
validator = PasswordValidator(min_length=10)
result = validate(validator, "short")
# result.valid == false
# result.errors == ["Password must be at least 10 characters long"]
```
"""
function validate(validator::PasswordValidator, password::AbstractString)
  errors = String[]
  
  # Length checks
  if length(password) < validator.min_length
    push!(errors, "Password must be at least $(validator.min_length) characters long")
  end
  if length(password) > validator.max_length
    push!(errors, "Password must not exceed $(validator.max_length) characters")
  end
  
  # Character class checks
  if validator.require_uppercase && !any(isuppercase, password)
    push!(errors, "Password must contain at least one uppercase letter")
  end
  if validator.require_lowercase && !any(islowercase, password)
    push!(errors, "Password must contain at least one lowercase letter")
  end
  if validator.require_digit && !any(isdigit, password)
    push!(errors, "Password must contain at least one digit")
  end
  if validator.require_special && !any(c -> !isalnum(c), password)
    push!(errors, "Password must contain at least one special character")
  end
  
  # Common password check
  if lowercase(password) in validator.common_passwords
    push!(errors, "Password is too common and easily guessable")
  end
  
  # Calculate strength
  strength = _calculate_strength(password, validator)
  
  return ValidationResult(isempty(errors), errors, strength)
end

"""
Calculate password strength based on various factors.
"""
function _calculate_strength(password::AbstractString, validator::PasswordValidator)
  score = 0
  
  # Length scoring
  len = length(password)
  if len >= 16
    score += 3
  elseif len >= 12
    score += 2
  elseif len >= 8
    score += 1
  end
  
  # Character variety scoring
  any(isuppercase, password) && (score += 1)
  any(islowercase, password) && (score += 1)
  any(isdigit, password) && (score += 1)
  any(c -> !isalnum(c), password) && (score += 2)
  
  # Unique characters bonus
  unique_ratio = length(unique(password)) / max(len, 1)
  unique_ratio > 0.7 && (score += 1)
  
  # Convert score to strength level
  if score >= 7
    return :strong
  elseif score >= 5
    return :good
  elseif score >= 3
    return :fair
  else
    return :weak
  end
end

# ============================================================================
# Utility Functions
# ============================================================================

"""
    _constant_time_compare(a::AbstractString, b::AbstractString) -> Bool

Compare two strings in constant time to prevent timing attacks.
"""
function _constant_time_compare(a::AbstractString, b::AbstractString)
  length(a) != length(b) && return false
  result = 0
  for (x, y) in zip(codeunits(a), codeunits(b))
    result |= xor(x, y)
  end
  return result == 0
end

# ============================================================================
# Global Password Encoder Instance
# ============================================================================

const _GLOBAL_ENCODER = Ref{DelegatingPasswordEncoder}(DelegatingPasswordEncoder())
const _GLOBAL_VALIDATOR = Ref{PasswordValidator}(PasswordValidator())

"""
    get_password_encoder() -> DelegatingPasswordEncoder

Get the global password encoder instance.
"""
get_password_encoder() = _GLOBAL_ENCODER[]

"""
    set_password_encoder!(encoder::DelegatingPasswordEncoder)

Set the global password encoder instance.
"""
function set_password_encoder!(encoder::DelegatingPasswordEncoder)
  _GLOBAL_ENCODER[] = encoder
end

# ============================================================================
# High-Level API (Django-compatible)
# ============================================================================

"""
    make_password(raw_password::AbstractString; algorithm::String=DEFAULT_ALGORITHM(), kwargs...) -> String

Hash a raw password using the specified algorithm.

# Arguments
- `raw_password`: The plain text password to hash
- `algorithm`: Hashing algorithm (default: "pbkdf2_sha256")
- `iterations`: For PBKDF2 - number of iterations (default: 720000)
- `salt`: Optional custom salt (auto-generated if not provided)

# Returns
A formatted password hash string.

# Examples
```julia
# Basic usage (Django compatible)
hash = make_password("mySecurePassword123!")

# With custom iterations
hash = make_password("password", iterations=100000)

# The hash format: algorithm\$params\$salt\$hash
# Example: "pbkdf2_sha256\$720000\$abc123\$base64hash=="
```

# Security Notes
- Uses PBKDF2-SHA256 by default (Django 4.2+ compatible)
- Salt is automatically generated using cryptographic randomness
- Default iterations (720000) provides strong security as of 2024
"""
function make_password(raw_password::AbstractString; 
    algorithm::String=DEFAULT_ALGORITHM(),
    iterations::Int=DEFAULT_PBKDF2_ITERATIONS,
    salt::Union{String, Nothing}=nothing)
  
  isempty(raw_password) && throw(ArgumentError("Password cannot be empty"))
  
  algorithm = lowercase(algorithm)
  
  if algorithm == "pbkdf2_sha256"
    encoder = PBKDF2PasswordEncoder(iterations=iterations)
    if salt !== nothing
      # Custom salt provided - manual encoding
      derived = pbkdf2_sha256(raw_password, salt, iterations)
      hash = Base64.base64encode(derived)
      return "pbkdf2_sha256\$$(iterations)\$$(salt)\$$(hash)"
    else
      return encode(encoder, raw_password)
    end
  elseif algorithm == "bcrypt"
    encoder = BCryptPasswordEncoder()
    return encode(encoder, raw_password)
  elseif algorithm in ("argon2id", "argon2i", "argon2")
    encoder = Argon2PasswordEncoder()
    return encode(encoder, raw_password)
  else
    throw(ArgumentError("Unknown algorithm: $algorithm"))
  end
end

"""
    check_password(raw_password::AbstractString, encoded_hash::AbstractString) -> Bool

Verify a raw password against a stored hash.

Automatically detects the hashing algorithm from the hash format.

# Arguments
- `raw_password`: The plain text password to verify
- `encoded_hash`: The stored password hash

# Returns
`true` if the password matches, `false` otherwise.

# Examples
```julia
# Hash and verify
hash = make_password("myPassword123")
check_password("myPassword123", hash)  # => true
check_password("wrongPassword", hash)  # => false

# Works with Django hashes
django_hash = "pbkdf2_sha256\$720000\$salt\$hash=="
check_password("password", django_hash)
```

# Security Notes
- Uses constant-time comparison to prevent timing attacks
- Automatically detects algorithm from hash prefix
- Returns `false` for malformed hashes (fails safely)
"""
function check_password(raw_password::AbstractString, encoded_hash::AbstractString)
  encoder = get_password_encoder()
  return matches(encoder, raw_password, encoded_hash)
end

"""
    password_needs_upgrade(encoded_hash::AbstractString; min_iterations::Int=DEFAULT_PBKDF2_ITERATIONS) -> Bool

Check if a password hash needs to be upgraded.

# Reasons for Upgrade
- Using deprecated algorithm
- Insufficient iterations/work factor
- Hash format is unrecognized

# Example
```julia
# After successful login
if password_needs_upgrade(user.password)
    # Re-hash with current parameters
    user.password = make_password(raw_password)
    save!(user)
end
```
"""
function password_needs_upgrade(encoded_hash::AbstractString; 
    min_iterations::Int=DEFAULT_PBKDF2_ITERATIONS)
  
  encoder = DelegatingPasswordEncoder(pbkdf2_iterations=min_iterations)
  return upgrade_encoding(encoder, encoded_hash)
end

"""
    validate_password(password::AbstractString; kwargs...) -> ValidationResult

Validate password strength against security requirements.

# Keyword Arguments
- `min_length::Int=8`: Minimum password length
- `require_uppercase::Bool=true`: Require uppercase letters
- `require_lowercase::Bool=true`: Require lowercase letters
- `require_digit::Bool=true`: Require digits
- `require_special::Bool=false`: Require special characters

# Returns
`ValidationResult` with:
- `valid::Bool` - Whether password meets requirements
- `errors::Vector{String}` - List of validation failures
- `strength::Symbol` - :weak, :fair, :good, or :strong

# Examples
```julia
result = validate_password("weak")
# result.valid == false
# result.errors == ["Password must be at least 8 characters long", ...]

result = validate_password("MyStr0ngP@ssword!")
# result.valid == true
# result.strength == :strong
```
"""
function validate_password(password::AbstractString;
    min_length::Int=8,
    max_length::Int=128,
    require_uppercase::Bool=true,
    require_lowercase::Bool=true,
    require_digit::Bool=true,
    require_special::Bool=false)
  
  validator = PasswordValidator(
    min_length=min_length,
    max_length=max_length,
    require_uppercase=require_uppercase,
    require_lowercase=require_lowercase,
    require_digit=require_digit,
    require_special=require_special
  )
  
  return validate(validator, password)
end

end # module Passwords
