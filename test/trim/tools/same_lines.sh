#!/usr/bin/env bash
# The untyped read's lines (#1599 layer 6): a trimmed binary must print its JIT control's `untyped` and
# `get_or_create` lines, in the same order. Those lines name each cell's Julia type, which is each engine's own, so a
# job checks them against the JIT control it ran itself rather than against lines spelled out in the workflow.
#
#   test/trim/tools/same_lines.sh <JIT control output> <binary output> <at least N lines>
#
# Fails when the JIT control printed fewer than N such lines (so an empty comparison never passes) or when the
# binary's differ.
set -euo pipefail
pat=$'^step\t(untyped|get_or_create)\t'
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
