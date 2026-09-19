#!/usr/bin/env bash
# Provision a fresh PormG worktree with the untracked local state it needs to run tests: the
# gitignored integration fixtures (connection.yml, db_sl/migrations/, the integration env's
# Manifest, and optionally f1.sqlite), then instantiate both test environments. Safe to
# re-run. The ROOT Manifest.toml is deliberately not copied — see step 1 (#624).
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
# 1) The root Manifest.toml is DELIBERATELY NOT COPIED (#624).
#    It used to be, with the rationale "without this, Pkg.instantiate drops the LibPQ/SQLite
#    weakdeps that test/load_drivers.jl loads by UUID". That was true only because the main
#    checkout's manifest predates #34 and still lists the drivers as hard `[deps]` — and
#    `Pkg.instantiate()` merely WARNS about a stale manifest instead of re-resolving it. So
#    the copy propagated one un-regenerable artifact into every worktree and made the
#    package-env spelling look green in all of them, right up until any re-resolve deleted
#    both entries. Copying it now would keep rewarding the one spelling
#    `test/unit/test_documented_commands.jl` exists to forbid. Instantiate re-resolves in
#    seconds against the already-populated depot, and it resolves the truth.
# 2) Always-safe, tiny fixtures. (db_2/migrations is TRACKED — already present, not copied.)
for f in test/integration/db_sl/connection.yml \
         test/integration/db_2/connection.yml \
         test/integration/Manifest.toml \
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

# 4) Instantiate BOTH test environments (#624).
#      --project=.                loads PormG itself. It carries NO SQL driver — they are
#                                 weakdeps — so it can run `Pkg.test()` but not a test script.
#      --project=test/integration carries LibPQ + SQLite + PormG (via [sources]). This is the
#                                 project for running ONE test file, unit or integration.
echo "instantiating (julia --project=.) ..."
julia --project="$WT" -e 'import Pkg; Pkg.instantiate()'
echo "instantiating (julia --project=test/integration) ..."
# Not fatal: this env is the heavier one (LibPQ needs a working system libpq) and `set -e`
# would abort provisioning after the copies but before the cleanup and the guidance below,
# for a failure that leaves the package env, the fixtures and f1.sqlite perfectly usable.
julia --project="$WT/test/integration" -e 'import Pkg; Pkg.instantiate()' || {
  echo "  ! test/integration instantiate FAILED — single-file test runs will not work until"
  echo "    you fix it: julia --project=test/integration -e 'using Pkg; Pkg.instantiate()'"
}
# Instantiating rewrites test/integration/Project.toml with the platform's line endings and
# nothing else, which then shows up as a hunk-less "modified" for the rest of the session.
# Drop that no-op diff — but ONLY if it really is one. This script is documented as safe to
# re-run, so an unconditional `checkout --` would silently eat a real edit on a re-run.
# `--ignore-all-space` exits 0 when the only differences are whitespace/line endings.
if ! git -C "$WT" diff --quiet -- test/integration/Project.toml 2>/dev/null; then
  if git -C "$WT" diff --quiet --ignore-all-space --ignore-cr-at-eol -- test/integration/Project.toml; then
    git -C "$WT" checkout -- test/integration/Project.toml
  else
    echo "  ! test/integration/Project.toml has REAL changes — left alone (not just line endings)."
  fi
fi

echo "done — worktree ready for unit + SQLite(db_sl) tests:"
echo "  full unit suite   julia --project=. -e 'using Pkg; Pkg.test()'"
echo "  one test file     julia --project=test/integration test/unit/test_<name>.jl"
echo "  (docs only)       julia --project=docs -e 'import Pkg; Pkg.develop(path=pwd()); Pkg.instantiate()'"
echo
echo "PostgreSQL (db_2) is a SHARED live database — the copied connection.yml points every worktree"
echo "at the same pormg_teste. You do not have to coordinate that by hand: the suite takes an"
echo "advisory lock on it, so a run started here QUEUES behind another session instead of"
echo "corrupting it (PORMG_TEST_LOCK_WAIT bounds the wait, default 900s). SQLite needs nothing —"
echo "f1.sqlite is copied per worktree above."
