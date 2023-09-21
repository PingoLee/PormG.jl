using PormG
using YAML

workdir = pwd()
testdir = mktempdir()
cd(testdir)

PormG.Generator.newconfig()
    @test isdir(joinpath(testdir, SearchLight.DB_PATH)) == true
    @test isfile(joinpath(testdir, SearchLight.DB_PATH, SearchLight.SEARCHLIGHT_DB_CONFIG_FILE_NAME)) == true