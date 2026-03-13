using Test

import PormG.Passwords: encode, matches, upgrade_encoding, PBKDF2PasswordEncoder, BCryptPasswordEncoder,
                         DelegatingPasswordEncoder, SpringSecurityPBKDF2PasswordEncoder

@testset "PBKDF2PasswordEncoder" begin
    pbkdf2 = PBKDF2PasswordEncoder()

    password = "test123!@#"
    hash = encode(pbkdf2, password)

    @test startswith(hash, "pbkdf2_sha256\$")
    @test contains(hash, "720000")
    @test matches(pbkdf2, password, hash) == true
    @test matches(pbkdf2, "wrong_password", hash) == false
    @test_throws ArgumentError encode(pbkdf2, "")

    pbkdf2_custom = PBKDF2PasswordEncoder(iterations=100000)
    hash_custom = encode(pbkdf2_custom, password)
    @test contains(hash_custom, "100000")
    @test matches(pbkdf2_custom, password, hash_custom) == true

    old_hash = "pbkdf2_sha256\$100000\$salt\$hash"
    @test matches(pbkdf2, "password", old_hash) == false
    @test upgrade_encoding(pbkdf2, old_hash) == true
end

@testset "BCryptPasswordEncoder" begin
    bcrypt = BCryptPasswordEncoder(cost=4)

    password = "test123!@#"
    hash = encode(bcrypt, password)

    @test startswith(hash, "\$2a\$")
    @test contains(hash, "04")
    @test matches(bcrypt, password, hash) == true
    @test matches(bcrypt, "wrong_password", hash) == false
    @test_throws ArgumentError encode(bcrypt, "")

    bcrypt_high = BCryptPasswordEncoder(cost=6)
    hash_high = encode(bcrypt_high, password)
    @test contains(hash_high, "06")
    @test matches(bcrypt_high, password, hash_high) == true

    @test_throws ArgumentError BCryptPasswordEncoder(cost=3)
    @test_throws ArgumentError BCryptPasswordEncoder(cost=32)

    long_password = repeat("a", 80)
    @test_logs (:warn, r"Password exceeds 72 bytes") encode(bcrypt, long_password)

    old_hash = "\$2a\$04\$somehash"
    bcrypt_new = BCryptPasswordEncoder(cost=6)
    @test upgrade_encoding(bcrypt_new, old_hash) == true
end

@testset "SpringSecurityPBKDF2PasswordEncoder" begin
    spring = SpringSecurityPBKDF2PasswordEncoder()

    password = "test123!@#"
    hash = encode(spring, password)

    @test startswith(hash, "sha256:")
    @test contains(hash, "310000")

    parts = split(hash, ':')
    @test length(parts) == 5
    @test parts[1] == "sha256"
    @test parts[3] == "32"

    @test matches(spring, password, hash) == true
    @test matches(spring, "wrong_password", hash) == false
    @test_throws ArgumentError encode(spring, "")

    spring_custom = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    hash_custom = encode(spring_custom, password)
    @test contains(hash_custom, "64000")
    @test matches(spring_custom, password, hash_custom) == true

    old_hash = "sha256:64000:32:salt:hash"
    @test upgrade_encoding(spring, old_hash) == true

    spring_hash = "sha256:64000:32:gexlBXpu2dKK1BvW2jw8+XZAo99/g9d7:aPXcE36dbNMo0ssJV0QGiX6/r4jHu8HUfvElVQB5erA="
    @test !matches(spring, "wrong_password", spring_hash)
end

@testset "DelegatingPasswordEncoder" begin
    delegating = DelegatingPasswordEncoder()

    password = "test123!@#"

    hash = encode(delegating, password)
    @test startswith(hash, "pbkdf2_sha256\$")
    @test matches(delegating, password, hash) == true

    pbkdf2 = PBKDF2PasswordEncoder()
    pbkdf2_hash = encode(pbkdf2, password)
    @test matches(delegating, password, pbkdf2_hash) == true

    bcrypt = BCryptPasswordEncoder(cost=4)
    bcrypt_hash = encode(bcrypt, password)
    @test matches(delegating, password, bcrypt_hash) == true

    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    spring_hash = encode(spring, password)
    @test matches(delegating, password, spring_hash) == true

    @test matches(delegating, "wrong", pbkdf2_hash) == false
    @test matches(delegating, "wrong", bcrypt_hash) == false

    delegating_bcrypt = DelegatingPasswordEncoder(default_algorithm="bcrypt", bcrypt_cost=4)
    hash_bcrypt = encode(delegating_bcrypt, password)
    @test startswith(hash_bcrypt, "\$2a\$")
    @test matches(delegating_bcrypt, password, hash_bcrypt) == true

    @test upgrade_encoding(delegating, pbkdf2_hash) == false

    plain_text = "password123"
    @test_logs (:warn, r"Unknown hash format") matches(delegating, plain_text, plain_text)
end

@testset "Cross-Encoder Compatibility" begin
    password = "mySecurePassword!@#"

    pbkdf2 = PBKDF2PasswordEncoder()
    bcrypt = BCryptPasswordEncoder(cost=4)
    spring = SpringSecurityPBKDF2PasswordEncoder(iterations=64000)
    delegating = DelegatingPasswordEncoder()

    pbkdf2_hash = encode(pbkdf2, password)
    bcrypt_hash = encode(bcrypt, password)
    spring_hash = encode(spring, password)

    @test matches(delegating, password, pbkdf2_hash)
    @test matches(delegating, password, bcrypt_hash)
    @test matches(delegating, password, spring_hash)
    @test !matches(delegating, "wrong", pbkdf2_hash)
    @test !matches(delegating, "wrong", bcrypt_hash)
    @test !matches(delegating, "wrong", spring_hash)
end