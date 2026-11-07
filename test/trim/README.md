# The `juliac --trim` fixture app

A minimal F1 application built with `juliac --trim`, the measuring stick for #1599 (a PormG app
built as a trimmed binary). It is #1616's first checkbox: the app is committed here; the CI job that
builds it on every PR is a workflow change, the maintainer's.

What it does (`main.jl`): boot with the connection built in code (`register_connection` and
`Models.set_models(models; key)`, #1606 — no `connection.yml` is read), one `Race.objects.create`,
and one `Race.objects.filter("circuitid__country" => "Monaco").list(RaceRow)`, where `RaceRow` is the
struct `list(show_query = :struct)` writes (#1632). Each step prints one line.

Not a test the suite runs: it needs Julia 1.13 and JuliaC, and today the binary stops before the
query (the walls left are in #1599's tables).

## Build and run

Julia 1.13.3 and JuliaC 0.3.12 (`pkg> app add JuliaC`, which installs `~/.julia/bin/juliac`). From
the repository root:

```
julia --project=test/trim -e 'using Pkg; Pkg.instantiate()'
julia --project=test/trim test/trim/prep.jl run          # seeds run/f1.sqlite under the JIT
julia --project=test/trim test/trim/main.jl run          # the JIT control: boot, write, 2 rows

mkdir -p build && cd build
JULIA_CPU_TARGET=native juliac --project ../test/trim --output-exe main \
  --trim=unsafe-warn --experimental ../test/trim/main.jl 2>&1 | tee build.log
cd .. && julia --project=test/trim test/trim/prep.jl run && build/main run
```

`--output-exe` takes a bare name, not a path. Pipe the build through `tee`: a redirect to a file lost
the end of the verifier report, which a spinner line overwrote (#1599 round 1). Under
`--trim=unsafe-warn` the verifier lists every dynamic call it cannot resolve ("Error #N"), and the
binary still links; a call with no compiled target then raises a catchable `MethodError` at run
time, which `main` prints with the function it missed.
