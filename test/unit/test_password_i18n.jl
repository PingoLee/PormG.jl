using Test

import PormG.Passwords: PasswordValidator, validate

@testset "Password Validation i18n" begin
    validator_en = PasswordValidator(min_length=8)
    result_en = validate(validator_en, "short")
    @test !result_en.valid
    @test result_en.errors[1] == "Password must be at least 8 characters long"

    pt_messages = Dict(
        :min_length => "A senha deve ter pelo menos %d caracteres",
        :require_uppercase => "A senha deve conter pelo menos uma letra maiúscula",
        :require_digit => "A senha deve conter pelo menos um número",
        :common_password => "Senha muito comum"
    )

    validator_pt = PasswordValidator(
        min_length=10,
        require_uppercase=true,
        require_digit=true,
        messages=pt_messages
    )

    result_pt = validate(validator_pt, "senha")
    @test !result_pt.valid
    @test "A senha deve ter pelo menos 10 caracteres" in result_pt.errors
    @test "A senha deve conter pelo menos uma letra maiúscula" in result_pt.errors

    result_digit = validate(validator_pt, "SENHA CURTA")
    @test "A senha deve conter pelo menos um número" in result_digit.errors

    validator_common = PasswordValidator(messages=pt_messages)
    result_common = validate(validator_common, "password")
    @test "Senha muito comum" in result_common.errors
end

@testset "Partial Message Override" begin
    custom = Dict(:min_length => "Too short: %d")
    validator = PasswordValidator(min_length=8, require_digit=true, messages=custom)

    result = validate(validator, "abc")
    @test "Too short: 8" in result.errors
    @test "Password must contain at least one digit" in result.errors
end

@testset "High-level validate_password i18n" begin
    import PormG: validate_password

    custom = Dict(:min_length => "Erro: %d")
    result = validate_password("abc", min_length=12, messages=custom)

    @test !result.valid
    @test "Erro: 12" in result.errors
end