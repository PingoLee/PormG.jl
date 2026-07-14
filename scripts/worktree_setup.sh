#!/usr/bin/env bash
# Provision a fresh PormG worktree with the untracked local state it needs to run tests:
# the resolved Manifest (holds the LibPQ/SQLite weakdeps) and the gitignored integration
# fixtures (connection.yml, db_sl/migrations/, and optionally f1.sqlite). Safe to re-run.
#
# If the repo has a `.worktreeinclude`, EnterWorktree already copies the small gitignored
# files at creation time — then this script is only needed for `Pkg.instantiate()` and the
# guarded `f1.sqlite` copy. It also works standalone (re-copies everything) if you created
# the worktree with plain `git worktree add`, which does NOT process `.worktreeinclude`.
#
# Usage:
#   bash scripts/worktree_setup.sh [<worktree-path>]     # defaults to $(pwd)
#
# The f1.sqlite copy is GUARDED: if the main checkout's fixture looks like it is being
# written right now (recent mtime, or a non-empty -wal from a parallel session's suite), it
# is skipped with a warning so you never copy a torn WAL — copy it by hand once idle.

set -euo pipefail

WT="${1:-$(pwd)}"
WT="$(cd "$WT" && pwd)"

# The main working tree is the first entry of `git worktree list`.
MAIN="$(git -C "$WT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
if [[ -z "${MAIN:-}" || "$MAIN" == "$WT" ]]; then
  echo "!! could not resolve the main checkout for worktree: $WT" >&2
  echo "   (are you inside a worktree created from the main repo?)" >&2
  exit 1
fi
echo "main checkout : $MAIN"
echo "worktree      : $WT"

copy() {  # copy SRC -> DST if SRC exists; create parent dirs
  local src="$1" dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -r "$src" "$dst"
    echo "  + ${src#$MAIN/}"
  fi
}

echo "provisioning gitignored local state (idempotent; .worktreeinclude may have done these):"
# 1) Resolved Manifest — WITHOUT this, `Pkg.instantiate` drops the LibPQ/SQLite weakdeps
#    that test/load_drivers.jl loads by UUID.
copy "$MAIN/Manifest.toml" "$WT/Manifest.toml"
# 2) Always-safe, tiny fixtures. (db_2/migrations is TRACKED — already present, not copied.)
for f in test/integration/db_sl/connection.yml \
         test/integration/db_2/connection.yml \
         test/integration/db_sl/migrations; do
  copy "$MAIN/$f" "$WT/$f"
done

# 3) f1.sqlite — guarded. Skip if the source was written in the last 30s (likely an active
#    parallel run), or if a non-empty -wal is present (an unpumped in-progress transaction).
sl="$MAIN/test/integration/db_sl/f1.sqlite"
if [[ -f "$sl" ]]; then
  now=$(date +%s); busy=0
  for s in "$sl" "$sl-wal" "$sl-shm"; do
    [[ -e "$s" ]] || continue
    (( now - $(stat -c %Y "$s") < 30 )) && busy=1
  done
  [[ -s "$sl-wal" ]] && busy=1
  if (( busy )); then
    echo "  ! f1.sqlite looks busy (recent write / non-empty -wal) — SKIPPED."
    echo "    copy it manually once the other integration run is idle:"
    echo "      cp '$sl'* '$WT/test/integration/db_sl/'"
  else
    for s in "$sl" "$sl-wal" "$sl-shm"; do
      [[ -e "$s" ]] && copy "$s" "$WT/test/integration/db_sl/$(basename "$s")"
    done
  fi
fi

# 4) Instantiate against the copied Manifest so the weakdeps resolve.
echo "instantiating (julia --project=.) ..."
julia --project="$WT" -e 'import Pkg; Pkg.instantiate()'

echo "done — worktree ready for unit + SQLite(db_sl) tests."
echo "  (docs only) julia --project=docs -e 'import Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'"
