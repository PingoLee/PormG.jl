using PormG
using Test

# Create a temporary directory for verification
test_dir = mktempdir()
println("Verifying AI skill installation in: $test_dir")

try
    # Call the new function
    PormG.install_ai_skills(test_dir)
    
    # Check if the file exists
    target_path = joinpath(test_dir, ".github", "skills", "pormg-usage", "SKILL.md")
    @test isfile(target_path)
    
    # Check content
    content = read(target_path, String)
    @test contains(content, "pormg-usage")
    @test contains(content, "PormG.jl")
    @test contains(content, "install_ai_skills") || contains(content, "Anti-Patterns")
    
    println("Verification SUCCESSFUL!")
finally
    # Cleanup
    rm(test_dir, recursive=true)
end
