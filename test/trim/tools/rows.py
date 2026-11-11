#!/usr/bin/env python3
"""Count the juliac --trim verifier's rows in a build log saved through `tee` (#1599).

One row = one "Error #N:" block, up to the next one. The verifier prints its warnings as
"Error #N:" too, on their own counter, interleaved with the errors': a row that continues the error
counter is an error, any other a warning. The totals are checked against the summary line
("Trim verify finished with E errors, W warnings.").

Counts:
  total, Error, Warning  the rows
  qb                     the innermost frame in PormG or a PormG submodule (not an extension) has its
                         file in src/querybuilder/, or is src/Dialect.jl or src/value_repr.jl
  abstract               the statement (the text before "Stacktrace:") names SQLType*,
                         AbstractPormGParam, a bare SQLObject or FilterType
  with_scope*            rows naming the scope helper (#1711, #1728, #1733): with_scope_body counts
                         the keyword body #with_scope#N in the statement or in frame [1]

Usage: python3 -I rows.py <build.log> [--list-with-scope]
"""
import re, sys, collections

HEAD = re.compile(r'^(Error|Warning) #(\d+): ')
LOC = re.compile(r'^\s+@ (\S+) (.*?):(\d+)')
ABSTRACT = re.compile(r'\b(SQLType[A-Za-z]*|AbstractPormGParam|SQLObject|FilterType)\b')

def rows(path):
    cur = None
    for line in open(path, errors='replace'):
        line = line.rstrip('\n')
        m = HEAD.match(line)
        if m:
            if cur: yield cur
            cur = {'kind': m.group(1), 'n': int(m.group(2)), 'lines': [line]}
        elif cur is not None:
            if line.startswith('Trim verify finished') or line.startswith('✓ Compiling'):
                yield cur; cur = None
            else:
                cur['lines'].append(line)
    if cur: yield cur

def innermost_pormg(lines):
    for i, l in enumerate(lines):
        m = LOC.match(l)
        if m and (m.group(1) == 'PormG' or m.group(1).startswith('PormG.')):
            return m.group(2), int(m.group(3)), lines[i - 1].strip()
    return None

def main():
    path = sys.argv[1]
    summary = None
    for l in open(path, errors='replace'):
        if l.startswith('Trim verify finished'): summary = l.strip()
    c = collections.Counter()
    ws_sites = collections.Counter()
    e = w = 0
    for r in rows(path):
        c['total'] += 1
        if r['n'] == e + 1:
            e += 1; c['Error'] += 1
        else:
            w += 1; c['Warning'] += 1
            assert r['n'] == w, (r['n'], e, w)
        st = []
        for l in r['lines']:
            if l.startswith('Stacktrace:'): break
            st.append(l)
        stmt = '\n'.join(st)
        ip = innermost_pormg(r['lines'])
        if ip and (('/querybuilder/' in ip[0]) or ip[0].endswith('/Dialect.jl') or ip[0].endswith('/value_repr.jl')):
            c['qb'] += 1
        if ABSTRACT.search(stmt):
            c['abstract'] += 1
        if any('with_scope' in l for l in r['lines']):
            c['with_scope_any'] += 1
        frame1 = next((l for l in r['lines'] if l.startswith(' [1] ')), '')
        if '#with_scope#' in stmt or '#with_scope#' in frame1:
            c['with_scope_body'] += 1
        if 'with_scope' in stmt or 'with_scope' in frame1:
            c['with_scope'] += 1
            c['with_scope_' + ('call' if 'unresolved call' in r['lines'][0] else 'invoke' if 'unresolved invoke' in r['lines'][0] else 'other')] += 1
            if ip:
                f = ip[0].split('/src/')[-1]
                ws_sites[f'{f}:{ip[1]}'] += 1
    print(summary)
    if summary:
        m = re.search(r'with (\d+) errors, (\d+) warnings', summary)
        if m and (int(m.group(1)), int(m.group(2))) != (c['Error'], c['Warning']):
            print(f'WARNING: parsed {c["Error"]} errors + {c["Warning"]} warnings, the summary says otherwise '
                  '(a log saved without tee loses its tail)')
    for k in ('total', 'Error', 'Warning', 'qb', 'abstract', 'with_scope_any', 'with_scope', 'with_scope_body', 'with_scope_call', 'with_scope_invoke', 'with_scope_other'):
        print(f'{k}\t{c[k]}')
    if '--list-with-scope' in sys.argv:
        for k, v in ws_sites.most_common():
            print(f'  ws-site\t{k}\t{v}')

main()
