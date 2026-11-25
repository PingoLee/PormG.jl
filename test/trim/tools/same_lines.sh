#!/usr/bin/env bash
# The untyped read's lines (#1599 layer 6): a trimmed binary must print its JIT control's `untyped` and
# `get_or_create` lines, in the same order. Those lines name each cell's Julia type, which is each engine's own, so a
# job checks them against the JIT control it ran itself rather than against lines spelled out in the workflow. The bulk
# writers' refusals (`bulk_refusal`, #1694) are checked the same way: each line is a refusal's type and text, which must
# be the one the JIT raises. So are the `engine_read` lines (#1599 layer 5): the reads each engine answers its own way,
# rows on one and a capability refusal's text on another; and the `lookup_refusal` lines (#1838 decision 2): the JSON,
# array and network lookups, rows on PostgreSQL and each refusal's type and text on SQLite and MySQL.
#
#   test/trim/tools/same_lines.sh <JIT control output> <binary output> <at least N lines>
#
# Fails when the JIT control printed fewer than N such lines (so an empty comparison never passes) or when the
# binary's differ.
set -euo pipefail
pat=$'^step\t(untyped|get_or_create|bulk_refusal|engine_read|lookup_refusal)\t'
jit=$(grep -E "$pat" "$1" || true)
run=$(grep -E "$pat" "$2" || true)
n=$(printf '%s' "$jit" | grep -c . || true)
if [ "$n" -lt "$3" ]; then
  echo "::error::the JIT control printed $n untyped-read lines, expected at least $3"
  exit 1
fi
if [ "$jit" != "$run" ]; then
  echo "::error::the trimmed binary's untyped-read lines differ from its JIT control's"
  diff <(printf '%s\n' "$jit") <(printf '%s\n' "$run") || true
  exit 1
fi
echo "untyped-read lines: $n, identical to the JIT control's"
