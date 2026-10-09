# `show_query = :pretty` (#48): reflow rendered SQL into one clause per line for logs and the REPL.
#
# The contract is that formatting changes WHITESPACE BETWEEN TOKENS and nothing else: a literal, a
# quoted identifier, a parameter placeholder and every operator come out byte-for-byte, so the pretty
# text executes exactly as the compact text does. That is why the formatter tokenizes instead of
# pattern-replacing — a `'… WHERE …'` literal or a `"order"` column must never gain a line break —
# and why it emits a space only where the input already had whitespace: `"Tb"."x"`, `COUNT(` and
# `$1::text` stay glued, and the only whitespace it ever adds is a line break between two tokens.
#
# The lexical rules are PostgreSQL's and SQLite's standard ones — `'…'` / `E'…'` / `$tag$…$tag$`
# literals, `"…"` identifiers, `--` / `/* */` comments, ASCII whitespace — which covers everything
# PormG renders. Backtick and `[…]` identifier quoting (accepted by SQLite for MySQL / T-SQL
# compatibility, never rendered by PormG) are not recognised.
#
# Line breaks happen only in a *block* context — the statement itself, or a parenthesis that opens a
# `SELECT`/`WITH` (a subquery, a CTE body). Every other parenthesis — a function call, an `IN` list,
# a column list, `OVER (…)` — stays on one line, whatever it contains, so `EXTRACT(YEAR FROM x)` and
# `OVER (ORDER BY …)` never break at their inner keywords.

# SQL's own whitespace, not Unicode's: PostgreSQL reads a no-break space as an identifier byte, so
# treating it as a separator would split an identifier.
_sql_isspace(c::Char) = c in (' ', '\t', '\n', '\r', '\f', '\v')
# A character an unquoted identifier can continue with (`$` too, unless it is a dollar-quote tag).
# Every non-ASCII character counts, as it does to PostgreSQL's lexer — a no-break space glued to a
# word is part of that word, so a line break must never split them. `isvalid` first: a malformed
# UTF-8 byte must become an operator token, never an exception.
_sql_isword(c::Char; dollar::Bool = true) =
  isvalid(c) && (isletter(c) || isdigit(c) || c == '_' || c >= '\x80' || (dollar && c == '$'))

# Token kinds: :ws, :word, :str (a '…' literal or $tag$…$tag$ body), :ident ("…"), :param ($n, ?, ?n),
# :lparen, :rparen, :comma, :semi, :comment, :op (any other single character).
function _sql_tokens(sql::AbstractString)
  cs = collect(sql)
  n = length(cs)
  toks = Tuple{Symbol, String}[]
  i = 1
  # Index just past a run closed by `q`, where a doubled `q` is an escaped one ('' / "").
  close_quoted(j, q) = begin
    k = j + 1
    while k <= n
      if cs[k] == q
        (k < n && cs[k + 1] == q) ? (k += 2; continue) : return k + 1
      end
      k += 1
    end
    return n + 1  # unterminated: the rest is the literal, verbatim
  end
  while i <= n
    c = cs[i]
    if !isvalid(c)
      push!(toks, (:op, string(c))); i += 1
    elseif _sql_isspace(c)
      j = i
      while j <= n && _sql_isspace(cs[j]); j += 1; end
      push!(toks, (:ws, String(cs[i:j-1]))); i = j
    elseif c == '\'' && !isempty(toks) && toks[end] in ((:word, "E"), (:word, "e"))
      # An E'…' escape string, where a backslash escapes the next character — `\'` included.
      j = i + 1
      while j <= n
        if cs[j] == '\\'
          j += 2
        elseif cs[j] == '\''
          (j < n && cs[j + 1] == '\'') ? (j += 2) : break
        else
          j += 1
        end
      end
      j = min(j + 1, n + 1)
      push!(toks, (:str, String(cs[i:j-1]))); i = j
    elseif c == '\''
      j = close_quoted(i, '\''); push!(toks, (:str, String(cs[i:j-1]))); i = j
    elseif c == '"'
      j = close_quoted(i, '"'); push!(toks, (:ident, String(cs[i:j-1]))); i = j
    elseif c == '-' && i < n && cs[i + 1] == '-'
      j = i
      while j <= n && cs[j] != '\n'; j += 1; end
      push!(toks, (:comment, String(cs[i:j-1]))); i = j
    elseif c == '/' && i < n && cs[i + 1] == '*'
      j = i + 2
      while j < n && !(cs[j] == '*' && cs[j + 1] == '/'); j += 1; end
      j = min(j + 2, n + 1)
      push!(toks, (:comment, String(cs[i:j-1]))); i = j
    elseif c == '$' && i < n && isdigit(cs[i + 1])
      j = i + 1
      while j <= n && isdigit(cs[j]); j += 1; end
      push!(toks, (:param, String(cs[i:j-1]))); i = j
    elseif c == '$'
      # A dollar-quoted body, `$$…$$` or `$tag$…$tag$`; a lone `$` is an operator character.
      j = i + 1
      while j <= n && _sql_isword(cs[j]; dollar = false); j += 1; end
      if j <= n && cs[j] == '$' && (j == i + 1 || !isdigit(cs[i + 1]))
        tag = cs[i:j]
        k = j + 1
        stop = n + 1
        while k + length(tag) - 1 <= n
          if cs[k:k + length(tag) - 1] == tag
            stop = k + length(tag); break
          end
          k += 1
        end
        push!(toks, (:str, String(cs[i:stop-1]))); i = stop
      else
        push!(toks, (:op, "\$")); i += 1
      end
    elseif c == '?'
      j = i + 1
      while j <= n && isdigit(cs[j]); j += 1; end
      push!(toks, (:param, String(cs[i:j-1]))); i = j
    elseif isletter(c) || c == '_' || c >= '\x80'
      j = i
      while j <= n && _sql_isword(cs[j]); j += 1; end
      push!(toks, (:word, String(cs[i:j-1]))); i = j
    elseif isdigit(c)
      j = i
      while j <= n && (isdigit(cs[j]) || cs[j] == '.'); j += 1; end
      push!(toks, (:word, String(cs[i:j-1]))); i = j
    elseif c == '('
      push!(toks, (:lparen, "(")); i += 1
    elseif c == ')'
      push!(toks, (:rparen, ")")); i += 1
    elseif c == ','
      push!(toks, (:comma, ",")); i += 1
    elseif c == ';'
      push!(toks, (:semi, ";")); i += 1
    else
      push!(toks, (:op, string(c))); i += 1
    end
  end
  return toks
end

# One parenthesis level. Only a `block` frame breaks lines; `open_indent` is the indent of the line the
# `(` sat on, where its `)` returns to.
mutable struct _SqlFrame
  block::Bool
  base::Int
  open_indent::Int
  clause::Symbol
  case_depth::Int
  between::Bool
  items_pending::Bool
end
_SqlFrame(block, base, open_indent) = _SqlFrame(block, base, open_indent, :none, 0, false, false)

const _SQL_JOIN_PREFIXES = ("LEFT", "RIGHT", "FULL", "INNER", "CROSS", "NATURAL", "OUTER")

# The clause a block-level word opens, or `nothing` when it continues the current one. `prev`/`next`
# are the neighbouring significant tokens, upper-cased, which is what tells `IS DISTINCT FROM` from a
# FROM clause, `LEFT(` from `LEFT JOIN`, and `FOR UPDATE` / `DO UPDATE` from an UPDATE statement.
function _sql_clause_start(up::String, prev::String, next::String)
  prev == "." && return nothing   # a qualified name: `Tb.from` is a column, not a clause
  statement_start = prev in ("", "(", ")", ";")
  up == "SELECT" && return :select
  up == "FROM" && return prev in ("DISTINCT", "DELETE") ? nothing : :from
  up == "WHERE" && return :where
  up in ("GROUP", "ORDER") && next == "BY" && return :group
  up == "HAVING" && return :having
  up in ("LIMIT", "OFFSET") && return :limit
  up in ("UNION", "INTERSECT", "EXCEPT") && return :union
  # Not after `)`: `TIMESTAMP(3) WITH TIME ZONE` is a type, not a CTE list.
  up == "WITH" && prev in ("", "(", ";") && return :with
  up == "VALUES" && return :values
  up == "SET" && return :set
  up == "RETURNING" && return :returning
  up in ("INSERT", "UPDATE", "DELETE", "COPY") && statement_start && return :dml
  up in _SQL_JOIN_PREFIXES && up != "OUTER" && next != "(" && return :join
  up == "JOIN" && !(prev in _SQL_JOIN_PREFIXES) && return :join
  up == "ON" && next == "CONFLICT" && return :conflict
  up == "FOR" && next in ("UPDATE", "SHARE", "NO", "KEY") && return :lock
  return nothing
end

"""
    _format_sql(sql::AbstractString) -> String

Reflow rendered SQL into one clause per line (`show_query = :pretty`, #48). Only whitespace between
tokens changes, so the result executes exactly as `sql` does.
"""
function _format_sql(sql::AbstractString)::String
  toks = _sql_tokens(sql)
  sig = findall(t -> t[1] !== :ws, toks)
  isempty(sig) && return ""
  upper_of(k) = (k < 1 || k > length(sig)) ? "" :
    (t = toks[sig[k]]; t[1] === :word ? uppercase(t[2]) : t[2])

  io = IOBuffer()
  stack = _SqlFrame[_SqlFrame(true, 0, 0)]
  cur_indent = 0
  pending_break = nothing   # Union{Nothing, Int}: break before the next token, at this indent
  wrote_any = false

  emit(text, gap::Bool, brk) = begin
    if wrote_any && brk !== nothing
      print(io, '\n', "  "^brk); cur_indent = brk
    elseif wrote_any && gap
      print(io, ' ')
    end
    print(io, text); wrote_any = true
  end

  for k in eachindex(sig)
    idx = sig[k]
    kind, text = toks[idx]
    gap = idx > 1 && toks[idx - 1][1] === :ws
    frame = stack[end]
    up = kind === :word ? uppercase(text) : text
    prev, next = upper_of(k - 1), upper_of(k + 1)
    brk = pending_break; pending_break = nothing

    # The first item of a SELECT/SET list goes on its own line, after any DISTINCT / ALL.
    if frame.block && frame.items_pending && !(kind === :word && up in ("DISTINCT", "ALL"))
      if kind === :word && up == "ON" && prev == "DISTINCT"
        frame.items_pending = false   # DISTINCT ON (…) keeps its list on the SELECT line
      else
        brk = frame.base + 1; frame.items_pending = false
      end
    end

    if kind === :lparen
      emit(text, gap, brk)
      if next in ("SELECT", "WITH")
        push!(stack, _SqlFrame(true, cur_indent + 1, cur_indent))
        pending_break = cur_indent + 1
      else
        push!(stack, _SqlFrame(false, frame.base, cur_indent))
      end
    elseif kind === :rparen && length(stack) > 1
      closed = pop!(stack)
      emit(text, gap, closed.block ? closed.open_indent : brk)
    elseif kind === :comma
      emit(text, gap, brk)
      if frame.block && frame.case_depth == 0
        frame.clause in (:select, :set) && (pending_break = frame.base + 1)
        frame.clause === :with && (pending_break = frame.base)
      end
    elseif kind === :semi
      emit(text, gap, brk)
      frame.block && (pending_break = frame.base)
    elseif kind === :comment
      emit(text, gap, brk)
      pending_break = cur_indent   # a `--` comment runs to the end of its line
    elseif kind === :word && frame.block
      clause = frame.case_depth == 0 ? _sql_clause_start(up, prev, next) : nothing
      if clause !== nothing
        emit(text, gap, frame.base)
        frame.clause = clause
        frame.between = false
        frame.items_pending = clause in (:select, :set)
      elseif up in ("AND", "OR") && frame.case_depth == 0
        if up == "AND" && frame.between
          frame.between = false
          emit(text, gap, brk)
        elseif frame.clause in (:where, :having, :join, :on)
          emit(text, gap, frame.base + 1)
        else
          emit(text, gap, brk)
        end
      else
        up == "CASE" && (frame.case_depth += 1)
        up == "END" && frame.case_depth > 0 && (frame.case_depth -= 1)
        up == "BETWEEN" && (frame.between = true)
        up == "ON" && frame.clause === :join && (frame.clause = :on)
        emit(text, gap, brk)
      end
    elseif kind === :str && k > 1 && toks[sig[k - 1]][1] === :str && gap && occursin('\n', toks[idx - 1][2])
      # `'foo'`, a newline, `'bar'` is ONE literal in PostgreSQL — continuation needs the newline,
      # and a space there is a syntax error — so the line break is kept.
      emit(text, gap, something(brk, cur_indent))
    else
      emit(text, gap, brk)
    end
  end
  return String(take!(io))
end
