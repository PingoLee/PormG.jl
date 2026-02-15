if !isdefined(Main, :PormG)
    include("common_setup.jl")
end

# julia -t auto  --project=. test/pg/test_password.jl

import PormG.Passwords: encode, matches, upgrade_encoding, PBKDF2PasswordEncoder, BCryptPasswordEncoder, 
                         DelegatingPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder

# ============================================================================
# Test 1: PBKDF2PasswordEncoder
# ============================================================================

@testset "PBKDF2PasswordEncoder" begin
    # Create encoder with default settings (Django 4.2+ compatible)
    pbkdf2 = PBKDF2PasswordEncoder()
    
    # Test encoding and verification
    password = "test123!@#"
    hash = encode(pbkdf2, password)
    
    # Hash should have PBKDF2 format: pbkdf2_sha256$iterations$salt$hash
    @test startswith(hash, "pbkdf2_sha256\$")
    @test contains(hash, "720000")  # Default 720000 iterations (Django 4.2+)
    
    # Correct password should verify
    @test matches(pbkdf2, password, hash) == true
    
    # Wrong password should not verify
    @test matches(pbkdf2, "wrong_password", hash) == false
    
    # Empty password should throw
    @test_throws ArgumentError encode(pbkdf2, "")
    
    # Test custom iterations
    pbkdf2_custom = PBKDF2PasswordEncoder(iterations=100000)
    hash_custom = encode(pbkdf2_custom, password)
    @test contains(hash_custom, "100000")
    @test matches(pbkdf2_custom, password, hash_custom) == true
    
    # Test upgrade detection
    old_hash = "pbkdf2_sha256\$100000\$salt\$hash"
    @test matches(pbkdf2, "password", old_hash) == false  # Won't match (invalid hash)
    @test upgrade_encoding(pbkdf2, old_hash) == true  # Should upgrade
end

# ============================================================================
# Test 2: BCryptPasswordEncoder
# ============================================================================

@testset "BCryptPasswordEncoder" begin
    # Create encoder with low cost for fast testing
    bcrypt = BCryptPasswordEncoder(cost=4)
    
    # Test encoding and verification
    password = "test123!@#"
    hash = encode(bcrypt, password)
    
    # Hash should have BCrypt format: $2a$cost$...
    @test startswith(hash, "\$2a\$")
    @test contains(hash, "04")  # Cost 4
    
    # Correct password should verify
    @test matches(bcrypt, password, hash) == true
    
    # Wrong password should not verify
    @test matches(bcrypt, "wrong_password", hash) == false
    
    # Empty password should throw
    @test_throws ArgumentError encode(bcrypt, "")
    
    # Test different costs
    bcrypt_high = BCryptPasswordEncoder(cost=6)
    hash_high = encode(bcrypt_high, password)
    @test contains(hash_high, "06")
    @test matches(bcrypt_high, password, hash_high) == true
    
    # Test cost validation
    @test_throws ArgumentError BCryptPasswordEncoder(cost=3)  # Too low
    @test_throws ArgumentError BCryptPasswordEncoder(cost=32)  # Too high
    
    # Test 72-byte limit warning (password exceeds 72 bytes)
    long_password = repeat("a", 80)
    @test_logs (:warn, r"Password exceeds 72 bytes") encode(bcrypt, long_password)
    
    # Test upgrade detection
    old_hash = "\$2a\$04\$somehash"
    bcrypt_new = BCryptPasswordEncoder(cost=6)
    @test upgrade_encoding(bcrypt_new, old_hash) == true  # Cost 4 < 6, should upgrade
end

# ============================================================================
# Test 3: Argon2PasswordEncoder (DISABLED - Will be re-enabled in future)
# ============================================================================
# NOTE: Argon2 is temporarily disabled to resolve precompilation issues.
# Uncomment and re-enable when dependency management is improved.

# @testset "Argon2PasswordEncoder" begin
#     # Argon2 requires external package which may not be available
#     argon2 = Argon2PasswordEncoder()
#     
#     # Should throw informative error
#     @test_throws ErrorException encode(argon2, "test")
#     
#     # Error message should mention installation instructions
#     try
#         encode(argon2, "test")
#     catch e
#         error_msg = string(e)
#         @test contains(error_msg, "not available")
#         @test contains(error_msg, "Argon2.jl")
#     end
# end

# ============================================================================
# Test 4: SpringSecurityPBKDF2PasswordEncoder
# ============================================================================

@testset "SpringSecurityPBKDF2PasswordEncoder" begin
    # Create encoder with default settings (Spring Security 6.x compatible)
    spring = SpringSecurityPBKDF2PasswordEncoder()
    
    # Test encoding and verification
    password = "test123!@#"
    hash = encode(spring, password)
    
    # Hash should have Spring Security format: sha256:iterations:keyLength:salt:hash
    @test startswith(hash, "sha256:")
    @test contains(hash, "310000")  # Default 310000 iterations (Spring 6.x)
    
    # Verify the format has 5 parts separated by ':'
    parts = split(hash, ':')
    @test length(parts) == 5
    @test parts[1] == "sha256"
    @test parts[3] == "32"  # Default key length
    
    # Correct password should verify
    @test matches(spring, password, hash) == true
    
    # Wrong password should not verify
    @test matches(spring, "wrong_password", hash) == false
    
    # Empty password should throw
    @test_throws ArgumentError encode(spring, "")
    
    # Test custom iterations
    spring_custom = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    hash_custom = encode(spring_custom, password)
    @test contains(hash_custom, "64000")
    @test matches(spring_custom, password, hash_custom) == true
    
    # Test upgrade detection
    old_hash = "sha256:64000:32:salt:hash"
    @test upgrade_encoding(spring, old_hash) == true  # 64000 < 310000, should upgrade
    
    # Test with real Spring Security hash
    # This hash was generated by a Spring application
    spring_hash = "sha256:64000:32:gexlBXpu2dKK1BvW2jw8+XZAo99/g9d7:aPXcE36dbNMo0ssJV0QGiX6/r4jHu8HUfvElVQB5erA="
    # Note: We don't know the original password, so we just verify format detection
    @test !matches(spring, "wrong_password", spring_hash)  # Should return false, not error
end

# ============================================================================
# Test 5: DelegatingPasswordEncoder
# ============================================================================

@testset "DelegatingPasswordEncoder" begin
    # Create delegating encoder
    delegating = DelegatingPasswordEncoder()
    
    password = "test123!@#"
    
    # Test 1: Default encoding (should use PBKDF2)
    hash = encode(delegating, password)
    @test startswith(hash, "pbkdf2_sha256\$")
    @test matches(delegating, password, hash) == true
    
    # Test 2: Auto-detect PBKDF2 hash
    pbkdf2 = PBKDF2PasswordEncoder()
    pbkdf2_hash = encode(pbkdf2, password)
    @test matches(delegating, password, pbkdf2_hash) == true
    
    # Test 3: Auto-detect BCrypt hash
    bcrypt = BCryptPasswordEncoder(cost=4)
    bcrypt_hash = encode(bcrypt, password)
    @test matches(delegating, password, bcrypt_hash) == true
    
    # Test 3.5: Auto-detect Spring Security PBKDF2 hash
    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    spring_hash = encode(spring, password)
    @test matches(delegating, password, spring_hash) == true
    
    # Test 4: Wrong password with auto-detection
    @test matches(delegating, "wrong", pbkdf2_hash) == false
    @test matches(delegating, "wrong", bcrypt_hash) == false
    
    # Test 5: Custom default algorithm
    delegating_bcrypt = DelegatingPasswordEncoder(default_algorithm="bcrypt", bcrypt_cost=4)
    hash_bcrypt = encode(delegating_bcrypt, password)
    @test startswith(hash_bcrypt, "\$2a\$")
    @test matches(delegating_bcrypt, password, hash_bcrypt) == true
    
    # Test 6: Upgrade detection
    @test upgrade_encoding(delegating, pbkdf2_hash) == false  # Already using default
    
    # Test 7: Unknown hash format fallback (should warn)
    plain_text = "password123"
    @test_logs (:warn, r"Unknown hash format") matches(delegating, plain_text, plain_text)
end

# ============================================================================
# Test 5: Cross-Encoder Compatibility
# ============================================================================

@testset "Cross-Encoder Compatibility" begin
    password = "mySecurePassword!@#"
    
    # Create different encoders
    pbkdf2 = PBKDF2PasswordEncoder()
    bcrypt = BCryptPasswordEncoder(cost=4)
    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    delegating = DelegatingPasswordEncoder()
    
    # Each encoder should verify its own hash
    pbkdf2_hash = encode(pbkdf2, password)
    bcrypt_hash = encode(bcrypt, password)
    spring_hash = encode(spring, password)
    
    @test matches(pbkdf2, password, pbkdf2_hash) == true
    @test matches(bcrypt, password, bcrypt_hash) == true
    @test matches(spring, password, spring_hash) == true
    
    # Delegating should verify all formats
    @test matches(delegating, password, pbkdf2_hash) == true
    @test matches(delegating, password, bcrypt_hash) == true
    @test matches(delegating, password, spring_hash) == true
    
    # Cross-verification should fail
    @test matches(pbkdf2, password, bcrypt_hash) == false
    @test matches(bcrypt, password, pbkdf2_hash) == false
    @test matches(spring, password, bcrypt_hash) == false
end

