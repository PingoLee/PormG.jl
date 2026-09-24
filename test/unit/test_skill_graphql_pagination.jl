# ============================================================
# test/unit/test_skill_graphql_pagination.jl
#
# The agent rulesets under `.github/` carry copy-paste `gh api graphql` recipes, and the board
# skill's two most important ones -- the reconcile projection and the membership sweep in
# `pormg-board` §1 -- hardcoded `items(first:99)` and never followed the cursor (#625).
#
# GitHub caps a connection page at 100 and returns only that page. Nothing in the response says
# "truncated": no error, no warning, and 99 rows look exactly like "the first 99 of 180". Items
# come back in the board's position order, which here is insertion order, so the rows dropped were
# always the NEWEST items -- the ones a planning pass is actually about. The board crossed 99 on its
# own and kept growing; by the time #625 was fixed it held 180 items and both recipes were blind to
# 81 of them. The reconcile could not see drift in the tail, and the sweep reported hidden on-board
# issues as "on no board item", which invites an `item-edit` that overwrites a Session/Status
# another session owns.
#
# Careful reading did not catch it -- the queries sat in the skill for weeks while the board grew
# past them. So this pins the shape rather than trusting a reviewer to notice: any fenced code
# block that runs `gh api … graphql` over a connection that grows without bound must drive the
# cursor loop -- `--paginate`, a `$endCursor: String` variable, and on THAT connection both
# `first:…, after:$endCursor` and its own `pageInfo{ hasNextPage endCursor }` ahead of `nodes`.
# Every piece is load-bearing, and each gap below was measured live at 100 of 180 rows: no
# `hasNextPage`, a `pageInfo` only on the nested `fieldValues` (or after `nodes`, since gh reads
# the first one in the response), and `last:` (gh cannot page backwards).
#
# SCOPE, DELIBERATELY NARROW. Only the connections named in `GROWING_CONNECTIONS` are policed.
# `fields(first:20)` and `fieldValues(first:12)` stay unpaginated on purpose: they are bounded by
# the board's schema (14 fields, at most 5 values per item when #625 landed), not by how much work
# has been filed, and the skill says so beside the queries. A recipe that reads its query from a
# file (`-F query=@q.graphql`) is invisible here -- the rule can only check text it can see.
# ============================================================

using Test

const PAGINATION_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

# Connections whose size tracks the backlog, so any fixed page size is eventually too small.
const GROWING_CONNECTIONS = ("items", "issues", "pullRequests")

# `<connection>(<args>)` -- the argument list is captured so each connection is judged on its own
# arguments. Matching only `items(first:` missed `issues(states:OPEN, first:50)` and friends.
const CONNECTION_CALL = Regex("\\b(" * join(GROWING_CONNECTIONS, "|") * ")\\s*\\(([^)]*)\\)")

"""
Split markdown `text` into its fenced code blocks, returning `(start_line, body)` pairs.

`start_line` is the 1-based line of the opening fence, so a failure can name the spot to edit.
Both ``` and ~~~ fences count, indented or not (the skills nest recipes under list items), and a
fence closes only on its own marker. A line that opens AND closes a marker (an inline span such
as ```x```) is prose, not a fence -- treating it as one would flip the pairing and hide every
later block. An unclosed fence runs to the end of the file rather than being dropped. Known limit:
a 4-backtick fence wrapping a ``` block pairs wrongly; no ruleset uses one today.
"""
function fenced_blocks(text::AbstractString)
    blocks = Tuple{Int,String}[]
    marker = ""
    open_at = 0
    buf = String[]
    for (i, line) in enumerate(split(text, '\n'))
        s = lstrip(line)
        m = match(r"^(```|~~~)", s)
        is_fence = m !== nothing && !occursin(m.captures[1], s[4:end])
        if is_fence && open_at == 0
            marker, open_at = m.captures[1], i
        elseif is_fence && m.captures[1] == marker
            push!(blocks, (open_at, join(buf, "\n")))
            open_at = 0
            empty!(buf)
        elseif open_at != 0
            push!(buf, line)
        end
    end
    open_at != 0 && push!(blocks, (open_at, join(buf, "\n")))
    return blocks
end

# `gh api graphql`, `gh api -X POST graphql`, and `gh api \` continued onto the next line all run
# the GraphQL endpoint; requiring the three words to be adjacent missed the last two.
runs_graphql(block::AbstractString) = occursin(r"\bgh\s+api\b", block) && occursin(r"\bgraphql\b", block)

"""
The growing connections in `block` that ask for a fixed page, as `(name, args, selection)`.

`first:` and `last:` both fix the page size. GitHub rejects a connection read with neither, so in
practice this is every growing connection a recipe touches. `selection` is the text after the
argument list -- the connection's own `{ … }` and everything that follows it.
"""
paged_connections(block::AbstractString) =
    [(m.captures[1], m.captures[2], SubString(block, m.offset + ncodeunits(m.match)))
     for m in eachmatch(CONNECTION_CALL, block)
     if occursin(r"\b(first|last)\s*:", m.captures[2])]

# The connection's OWN `pageInfo`: inside its selection and ahead of any other nested `{`. gh
# follows the first `pageInfo` it meets in the response, which keeps the query's field order -- so
# a `pageInfo` on a nested `fieldValues`, or one placed after `nodes{…}`, is the one gh reads, and
# its `hasNextPage: false` stops the loop after page one (measured: 100 of 180 rows, both shapes).
const OWN_PAGEINFO = r"^\s*\{[^{}]*?\bpageInfo\s*\{([^}]*)\}"

"""
Return the reasons `block` fails the pagination rule -- empty when it passes or does not apply.

It applies only to a block that runs GraphQL AND asks a growing connection for a fixed page. The
cursor and `pageInfo` must sit on each such connection itself; `--paginate` and the variable are
per request. Each missing piece is reported separately so the message says what to add.
"""
function pagination_problems(block::AbstractString)
    runs_graphql(block) || return String[]
    paged = paged_connections(block)
    isempty(paged) && return String[]

    problems = String[]
    for (name, args, selection) in paged
        # `--paginate` only walks forward (`first:` + `after:`). Backwards, `hasNextPage` is false
        # on the first page, so `last:100, after:\$endCursor` stops at 100 rows (measured).
        occursin(r"\blast\s*:", args) &&
            push!(problems, "$name — `last:` pages backwards: gh --paginate only follows `first:` + `after:`")
        occursin(r"after\s*:\s*\$endCursor", args) ||
            push!(problems, "$name — no `after:\$endCursor` on this connection: every page would restart at row 1")

        own = match(OWN_PAGEINFO, selection)
        if own === nothing
            push!(problems, "$name — no `pageInfo{ hasNextPage endCursor }` ahead of `nodes` on this connection: --paginate cannot follow the next page")
        else
            # gh follows the cursor only while `hasNextPage` is true, so `pageInfo{ endCursor }`
            # alone stops after page one -- the #625 truncation in a shape a bare check accepts.
            for key in ("hasNextPage", "endCursor")
                occursin(Regex("\\b$key\\b"), own.captures[1]) ||
                    push!(problems, "$name — `pageInfo` lacks `$key`: --paginate cannot follow the next page")
            end
        end
    end

    names = join(unique(first.(paged)), "/")
    occursin("--paginate", block) ||
        push!(problems, "$names — no --paginate: gh returns the first page only, silently")
    occursin(r"\$endCursor\s*:\s*String", block) ||
        push!(problems, "$names — no `\$endCursor: String` variable: --paginate has no cursor to drive")
    return problems
end

"""
Every fenced block under the agent-ruleset trees that the rule applies to, as
`(relpath, line, block)`. Kept separate from the verdict so a guard can prove it saw something.
"""
function graphql_recipes(root::AbstractString)
    found = Tuple{String,Int,String}[]
    for tree in (joinpath(root, ".github", "skills"), joinpath(root, ".github", "instructions"))
        isdir(tree) || continue
        for (dir, _, files) in walkdir(tree), f in files
            endswith(f, ".md") || continue
            path = joinpath(dir, f)
            for (line, block) in fenced_blocks(read(path, String))
                runs_graphql(block) && !isempty(paged_connections(block)) &&
                    push!(found, (relpath(path, root), line, block))
            end
        end
    end
    return found
end

unpaginated_recipes(root::AbstractString) =
    ["$path:$line — $why" for (path, line, block) in graphql_recipes(root) for why in pagination_problems(block)]

# ─────────────────────────────────────────────────────────────────────────────
# Skill GraphQL pagination: the detector itself, on synthetic recipes
# Pins that the pre-#625 shape is flagged, the fixed shape passes, each piece of the cursor loop is
# individually required, and the schema-bounded `fields(first:20)` query is left alone. Without
# this, a detector that matched nothing would make the real-tree testset below pass vacuously.
# ─────────────────────────────────────────────────────────────────────────────
@testset "detector: flags the #625 shape, passes the paginated one" begin
    # The membership-sweep query exactly as it shipped before #625: one page of 99, no cursor.
    truncated = """
    gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){ items(first:99){ nodes{ content{ ... on Issue { number } } } } } } }'
    """
    problems = pagination_problems(truncated)
    @test length(problems) == 4                       # after:, own pageInfo, --paginate, variable
    @test any(occursin("--paginate", p) for p in problems)

    # The fixed shape: --paginate drives $endCursor through after: until pageInfo says stop.
    paginated = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { user(login:"PingoLee"){ projectV2(number:7){
      items(first:100, after:\$endCursor){ pageInfo{ hasNextPage endCursor } nodes{ id } } } } }'
    """
    @test pagination_problems(paginated) == String[]

    # Each piece of the loop is required on its own. Removing one yields exactly that one message.
    no_after = replace(paginated, ", after:\$endCursor" => "")
    @test pagination_problems(no_after) ==
          ["items — no `after:\$endCursor` on this connection: every page would restart at row 1"]

    # Measured live during #625: `pageInfo{ endCursor }` without hasNextPage returned 100 of 180
    # rows -- gh stops paging -- so a bare "mentions pageInfo" check is not enough.
    no_has_next = replace(paginated, "pageInfo{ hasNextPage endCursor }" => "pageInfo{ endCursor }")
    @test pagination_problems(no_has_next) ==
          ["items — `pageInfo` lacks `hasNextPage`: --paginate cannot follow the next page"]

    # Schema-bounded connections are out of scope: the field-discovery query in §4 stays as is.
    fields_only = """
    gh api graphql -f query='{ user(login:"PingoLee"){ projectV2(number:7){ id
      fields(first:20){ nodes{ ... on ProjectV2SingleSelectField { id name } } } } } }'
    """
    @test pagination_problems(fields_only) == String[]

    # Only text that actually calls the GraphQL API is policed.
    @test pagination_problems("jq '.items(first:3)'") == String[]
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill GraphQL pagination: shapes a literal `items(first:` match would miss
# Each was a false negative in the first draft of this guard, found in review: the page-size
# argument not first, a space before the paren, `last:`, an unpaginated connection sharing a block
# with a paginated one, a cursor or pageInfo wired to the nested connection (or pageInfo placed
# after `nodes`), backwards paging, and gh's other spellings.
# ─────────────────────────────────────────────────────────────────────────────
@testset "detector: catches the non-obvious unpaginated shapes" begin
    flagged(q) = !isempty(pagination_problems(q))

    @test flagged("gh api graphql -f query='{ repository(owner:\"o\",name:\"r\"){ issues(states:OPEN, first:50){ nodes{ number } } } }'")
    @test flagged("gh api graphql -f query='{ x{ items(orderBy:{field:POSITION}, first:99){ nodes{ id } } } }'")
    @test flagged("gh api graphql -f query='{ x{ items (first:99){ nodes{ id } } } }'")
    @test flagged("gh api graphql -f query='{ x{ items(last:99){ nodes{ id } } } }'")

    # One paginated connection does not excuse another in the same block.
    mixed = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { user(login:"PingoLee"){ projectV2(number:7){
      items(first:100, after:\$endCursor){ pageInfo{ hasNextPage endCursor } nodes{ id } } } }
      repository(owner:"o",name:"r"){ issues(first:50){ nodes{ number } } } }'
    """
    @test pagination_problems(mixed) == [
        "issues — no `after:\$endCursor` on this connection: every page would restart at row 1",
        "issues — no `pageInfo{ hasNextPage endCursor }` ahead of `nodes` on this connection: --paginate cannot follow the next page",
    ]

    # The cursor AND pageInfo have to sit on the GROWING connection, not the nested per-item one.
    wrong_level = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { x{ items(first:99){
      nodes{ fieldValues(first:12, after:\$endCursor){ pageInfo{ hasNextPage endCursor } nodes{ id } } } } } }'
    """
    @test pagination_problems(wrong_level) == [
        "items — no `after:\$endCursor` on this connection: every page would restart at row 1",
        "items — no `pageInfo{ hasNextPage endCursor }` ahead of `nodes` on this connection: --paginate cannot follow the next page",
    ]

    # Found in the delta review, both measured live at 100 of 180 rows: gh reads the FIRST
    # pageInfo in the response. A cursor correctly on `items` does not help when the only
    # pageInfo is the nested one, or when `items`' own pageInfo comes after `nodes{…}`.
    own_pi_msg = ["items — no `pageInfo{ hasNextPage endCursor }` ahead of `nodes` on this connection: --paginate cannot follow the next page"]
    nested_pi = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { x{ items(first:100, after:\$endCursor){
      nodes{ id fieldValues(first:12){ pageInfo{ hasNextPage endCursor } nodes{ id } } } } } }'
    """
    @test pagination_problems(nested_pi) == own_pi_msg
    pi_after_nodes = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { x{ items(first:100, after:\$endCursor){
      nodes{ id } pageInfo{ hasNextPage endCursor } } } }'
    """
    @test pagination_problems(pi_after_nodes) == own_pi_msg

    # `last:` pages backwards, which --paginate cannot follow even with the full loop present.
    backwards = """
    gh api graphql --paginate -f query='query(\$endCursor: String) { x{
      items(last:100, after:\$endCursor){ pageInfo{ hasNextPage endCursor } nodes{ id } } } }'
    """
    @test pagination_problems(backwards) ==
          ["items — `last:` pages backwards: gh --paginate only follows `first:` + `after:`"]

    # gh's other spellings of the same call.
    @test flagged("gh api -X POST graphql -f query='{ x{ items(first:99){ nodes{ id } } } }'")
    @test flagged("gh api \\\n  graphql -f query='{ x{ items(first:99){ nodes{ id } } } }'")
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill GraphQL pagination: fence splitting
# The recipes nest under list items, so fences can be indented; ~~~ is a fence too; an inline
# ```span``` at the start of a line is prose and must not flip the pairing; and the reported line
# is the opening fence so a failure points at the block to edit.
# ─────────────────────────────────────────────────────────────────────────────
@testset "fenced_blocks: indentation, ~~~, inline spans, line numbers" begin
    md = "intro\n\n```bash\necho one\n```\n\n- step\n  ```\n  echo two\n  ```\n"
    blocks = fenced_blocks(md)
    @test length(blocks) == 2
    @test blocks[1] == (3, "echo one")
    @test blocks[2][1] == 8
    @test occursin("echo two", blocks[2][2])

    # A ~~~ fence is a block, and a ``` line inside it does not close it.
    tilde = fenced_blocks("~~~\na\n```\nb\n~~~\n")
    @test tilde == [(1, "a\n```\nb")]

    # The inline span must not open a fence -- otherwise the real block after it reads as prose.
    inline = fenced_blocks("```x``` is inline\n\n```bash\ngh api graphql\n```\n")
    @test inline == [(3, "gh api graphql")]
end

# ─────────────────────────────────────────────────────────────────────────────
# Skill GraphQL pagination: every recipe in the real rulesets drives the cursor
# The regression guard for #625. It first proves it SAW the board skill's two §1 recipes -- a guard
# whose scan finds nothing is green for the wrong reason, and a rewrite into a shape the detector
# cannot parse would otherwise slip through. A failure lists `file:line — missing piece`; the fix is
# to add the cursor loop there, never to lower the page size or exempt a growing connection.
# ─────────────────────────────────────────────────────────────────────────────
@testset "every growing-connection recipe in .github/ paginates" begin
    recipes = graphql_recipes(PAGINATION_REPO_ROOT)
    board = joinpath(".github", "skills", "pormg-board", "SKILL.md")

    # The reconcile projection and the membership sweep, at minimum.
    @test count(r -> r[1] == board, recipes) >= 2

    offenders = unpaginated_recipes(PAGINATION_REPO_ROOT)
    isempty(offenders) || @info "unpaginated gh api graphql recipes\n" * join(offenders, "\n")
    @test offenders == String[]
end
