#!/usr/bin/env python3
"""Classify the juliac --trim verifier's rows into the remaining-work map (#1599 rounds 9 and 10).

Each row gets one class, first match wins, so the totals are exact and the split between classes
follows the rules below (the statement is the row's text before "Stacktrace:"; "where" is the
innermost PormG frame's file):
  A  nested scopes: the row names an unresolved #with_scope# / #_with_render_scope# body
  B  FieldPart readers: the statement names SQLField.field's union (FieldPart)
  C  other node fields: the statement names an abstract SQLType* / FilterType / AbstractPormGParam /
     bare SQLObject
  D  the statement names PormGField or the AnyField union
  E  an untyped string / repr / print / show / sprint / logging call
  F  where is the pool or the configuration (ConnectionPool, Configuration, Backend, AdvisoryLock)
     or an extension
  H  no PormG frame (Base, a driver, Serialization)
  G  an untyped (::Any) value in the statement
  I  everything else

With --layers it also prints the rows by the trim track's layers (#1599's body, 2026-11-11), in two
views:
  where  the innermost PormG file, through FILE_LAYER below. Layer 4 is the query state's own files
         (the node structs, the parameter collectors, the memos); the node renders
         (select_nodes.jl, filter_nodes.jl) are layer 5 code
  cause  the class, through CLASS_LAYER below; F splits by file (Configuration.jl is layer 1, the
         rest layer 2), G's `_decompose_period` rows are cross-cutting, and the other G and I rows
         have no owner by rule, so they are listed by where they sit

Usage: python3 -I classify.py <build.log> [--layers]
"""
import sys, re, collections

FP = 'Union{String, PormG.Kernel.SQLTypeCTE, PormG.Kernel.SQLTypeF, PormG.Kernel.SQLTypeFunction, PormG.Kernel.SQLTypeJoined, PormG.Kernel.SQLTypeText, PormG.QueryBuilder.ExistsObject, PormG.QueryBuilder.SubqueryObject}'
ANYF = 'PormG.Models.sArrayField, PormG.Models.sBigIntegerField'
NODE = re.compile(r'\b(SQLType[A-Za-z]*|FilterType|AbstractPormGParam|SQLObject)\b')
LOC = re.compile(r'^\s+@ (\S+) (.*?):(\d+)')
SHOW = re.compile(r'statement (string|repr|print|println|show|sprint|_apply_iterate|Base\.show|Base\.print)\b')

CLASSES = {
    'A': 'nested scopes', 'B': 'FieldPart readers', 'C': 'other node fields',
    'D': 'PormGField / AnyField-typed', 'E': 'untyped string/show/logging', 'F': 'pool/config',
    'G': 'untyped (Any) values', 'H': 'no PormG frame', 'I': 'other',
}
FILE_LAYER = {
    **dict.fromkeys(['Kernel.jl', 'constants.jl', 'exceptions.jl', 'column_ir.jl', 'capabilities.jl', 'Configuration.jl'], '1'),
    **dict.fromkeys(['Backend.jl', 'ConnectionPool.jl', 'AdvisoryLock.jl'], '2'),
    **dict.fromkeys(['Models.jl', 'Utils.jl', 'fields.jl', 'network_address.jl', 'pg_array.jl'], '3'),
    **dict.fromkeys(['types.jl', 'parameters.jl', 'memos.jl'], '4'),
    **dict.fromkeys(['execution_read.jl', 'typed_read.jl', 'value_repr.jl'], '6'),
    **dict.fromkeys(['execution_write.jl', 'execution_bulk.jl', 'deletion.jl'], '7'),
}
CLASS_LAYER = {'A': '5', 'B': '4', 'C': '4', 'D': '3', 'E': 'cross-cutting', 'H': 'upstream'}

def read_rows(path):
    rows = []; cur = None
    for l in open(path, errors='replace'):
        l = l.rstrip('\n')
        if re.match(r'^Error #\d+: ', l):
            if cur: rows.append(cur)
            cur = [l]
        elif cur is not None:
            if l.startswith('Trim verify finished'): rows.append(cur); cur = None
            else: cur.append(l)
    if cur: rows.append(cur)
    return rows

def statement(r):
    return '\n'.join(r[:next((i for i, x in enumerate(r) if x.startswith('Stacktrace:')), len(r))])

def innermost(r):
    """(file, the frame line above it) of the innermost PormG frame, or ('', '')."""
    for i, x in enumerate(r):
        m = LOC.match(x)
        if m and m.group(1).startswith('PormG'):
            return m.group(2), r[i - 1]
    return '', ''

def classify(r, s, f):
    if '#_with_render_scope#' in r[0] or '#with_scope#' in r[0]: return 'A'
    if FP in s: return 'B'
    if NODE.search(s): return 'C'
    if 'PormGField' in s or ANYF in s: return 'D'
    if SHOW.search(r[0]) or 'Base.show' in s: return 'E'
    if re.search(r'(ConnectionPool|Configuration|Backend|AdvisoryLock)\.jl$', f) or '/ext/' in f: return 'F'
    if not f: return 'H'
    if '::Any' in s: return 'G'
    return 'I'

def where_layer(f):
    if not f: return 'upstream'
    if '/ext/' in f: return '2'
    b = f.split('/')[-1]
    if b in FILE_LAYER: return FILE_LAYER[b]
    if '/src/models/' in f: return '3'
    if '/querybuilder/' in f or b in ('Dialect.jl', 'QueryBuilder.jl'): return '5'
    return 'other: ' + b

def cause_layer(k, f, frame):
    if k in CLASS_LAYER: return CLASS_LAYER[k]
    if k == 'F': return '1' if f.endswith('/Configuration.jl') else '2'
    if k == 'G' and '_decompose_period' in frame: return 'cross-cutting (_decompose_period)'
    return f'{k}, by where: ' + where_layer(f)

def main():
    rows = read_rows(sys.argv[1])
    c = collections.Counter(); files = collections.defaultdict(collections.Counter)
    wc = collections.Counter(); wfiles = collections.defaultdict(collections.Counter); oc = collections.Counter()
    for r in rows:
        s = statement(r); f, frame = innermost(r)
        b = f.split('/')[-1] if f else '-'
        k = classify(r, s, f)
        c[k] += 1; files[k][b] += 1
        w = where_layer(f); wc[w] += 1; wfiles[w][b] += 1
        oc[cause_layer(k, f, frame)] += 1
    print('total', len(rows))
    for k in CLASSES:
        print(f'{c[k]:5d}  {k} {CLASSES[k]}   top files: ' + ', '.join(f'{x} {n}' for x, n in files[k].most_common(4)))
    if '--layers' in sys.argv:
        print('\nby layer, where the row sits (the innermost PormG file):')
        for k, v in sorted(wc.items()):
            print(f'{v:5d}  {k}   ' + ', '.join(f'{x} {n}' for x, n in wfiles[k].most_common(5)))
        print('\nby layer, by cause (the class; G and I by where they sit):')
        for k, v in sorted(oc.items()):
            print(f'{v:5d}  {k}')

main()
