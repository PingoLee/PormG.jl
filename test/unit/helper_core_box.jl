# The `Core.Box` detector, shared by test_terminal_pool_barrier.jl (#1693, src/querybuilder/) and
# test_type_ratchet.jl (#1697, the rest of src/ and ext/). One copy, so the two counts cannot drift
# apart in what they call a box.
#
# A closure that captures a local variable and reassigns it (or a local reassigned after a closure
# captured it) makes the variable a `Core.Box`: inference reads it as `Any`, every use is a dynamic
# call under the JIT, and in a `juliac --trim` image it is a verifier row or a run-time compile that
# fails (round 4 of #1600: `_close_pool_slots!`'s `in_use`). A text scan cannot see one; the lowered
# code can, because lowering writes the box as an explicit `Core.Box(…)` call. The walk covers every
# method of the given files: functions, keyword bodies, closures, and methods added to functions the
# file does not own (`Tables.columns`, a `Base` method, a keyword sorter).
#
# Included, not run on its own (the `helper_*.jl` convention): defines functions only, so including it
# twice in one module is harmless.

_core_box_isbox(@nospecialize(x)) = x === Core.Box || (x isa GlobalRef && x.mod === Core && x.name === :Box)

# The names of the variables a lowered method boxes, one entry per `Core.Box(…)` construction.
function core_boxed_vars(ci::Core.CodeInfo)
  out = Symbol[]
  for st in ci.code
    st isa Expr || continue
    rhs = st.head === :(=) ? st.args[2] : st
    (rhs isa Expr && rhs.head === :call && _core_box_isbox(rhs.args[1])) || continue
    lhs = st.head === :(=) ? st.args[1] : nothing
    push!(out, lhs isa Core.SlotNumber ? ci.slotnames[lhs.id] : Symbol("?"))
  end
  return out
end

core_boxes(ci::Core.CodeInfo) = length(core_boxed_vars(ci))

# Every method whose file `keep(file)` accepts, as `key(file) => ["name:line boxes var", …]`.
function core_box_sites(keep, key)
  sites = Dict{String,Vector{String}}()
  Base.visit(Core.methodtable) do m
    m isa Method || return
    file = string(m.file)
    keep(file) || return
    isdefined(m, :generator) && return   # an `@generated` method has no source to lower here
    vars = core_boxed_vars(Base.uncompressed_ast(m))
    isempty(vars) && return
    list = get!(sites, key(file), String[])
    for v in vars
      push!(list, "$(m.name):$(m.line) boxes $(v)")
    end
    return
  end
  foreach(sort!, values(sites))
  return sites
end

# The same walk, counted per key.
core_box_counts(keep, key) = Dict(k => length(v) for (k, v) in core_box_sites(keep, key))

# A closure that reassigns what it captures, and one that does not: the detector's own check, so a
# table cannot pass by finding nothing.
function _core_box_boxing()
  x = 1
  bump = () -> (x += 1)
  bump()
  return x
end
function _core_box_not_boxing()
  x = 1
  read_x = () -> x + 1
  return read_x()
end
