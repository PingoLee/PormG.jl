# Methods a trimmed image needs from upstream packages at start, rooted at the entry's top level (#1599): a
# `Base.Experimental.entrypoint` keeps a method in the image (a `precompile` statement does not) and does nothing
# under the JIT. A JLL built with LazyJLLWrappers (Libiconv_jll 1.18.1, through YAML's StringEncodings) sets each
# product path in its `__init__` with `string(...)` over an untyped lazy value, which a trimmed image has no code for:
# the binary stopped at `InitError(:Libiconv_jll, MissingCodeError(string(::LazyLibraryPath)))` before `main`.
Base.Experimental.entrypoint(string, (Base.Libc.Libdl.LazyLibraryPath,))
let id = Base.PkgId(Base.UUID("21706172-204c-4d4f-5420-656854206f44"), "LazyJLLWrappers")
    # Rooted only when a dependency loads it: an older JLL build does not.
    haskey(Base.loaded_modules, id) &&
        Base.Experimental.entrypoint(string, (getglobal(Base.loaded_modules[id], :LazyArtifactDir),))
end
