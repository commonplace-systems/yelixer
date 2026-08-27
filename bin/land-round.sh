#!/usr/bin/env bash
# Land a Sol round branch onto main — FROM THE MAIN CHECKOUT, verified, pushed.
#
# Ported from commonplace-next/bin/land-round.sh. WHY THE SHAPE EXISTS
# (unchanged, 2026-08-24 commonplace-next): merging from inside the round's
# own worktree — whose checked-out branch IS the round branch — makes the
# merge a no-op, the push a no-op, and "0 commits ahead" reads as "landed"
# when nothing happened. Every command succeeds; the sentence is false in two
# ways at once. This script's on-main / non-worktree refusal exists so that
# mistake cannot recur here either.
#
# WHAT'S DIFFERENT FROM commonplace-next's copy, AND WHY (see
# bin/README-rounds.md for the full account):
#   - The gate list is yelixer's own CI, established by reading
#     .github/workflows/ci.yml on 2026-08-27, not commonplace-next's
#     check-plan-arms.sh / check-spec-pristine.sh (yelixer has no plan-arms
#     or pristine-spec convention — it uses `bd`/beads for issue tracking).
#   - Every `mix test` and conformance run is wrapped in bin/yx-test-guard,
#     which this repo already has and CI already relies on, because `mix
#     test` exits 0 when it selects NOTHING — assert the COUNT, never an
#     exit code (see bin/yx-test-guard's own header for the incident that
#     motivated it).
#   - The Yjs conformance gates need `npm ci --prefix test/fixtures` on the
#     HOST beforehand (see dispatch-round.sh) and set
#     YELIXER_REQUIRE_YJS_ORACLE=1 so a missing oracle is a hard failure,
#     matching CI exactly.
#
# Usage: bin/land-round.sh sol/<round-branch>   |   bin/land-round.sh --self-test
set -euo pipefail
# --self-test: prove, with the REAL gate() and a sentinel in place of `git push`, that a
# deliberately failing gate ends the run before the push line (rc 70, no sentinel), and --
# the green arm -- that a passing gate reaches it. Runs no git, merges nothing.
if [ "${1:-}" = "--self-test" ]; then
  before=self-test
  gate() {
    local label="$1"; shift
    local out rc=0
    out=$("$@" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then echo "$out" | tail -20; echo "REFUSED: $label failed (rc=$rc); not pushing." >&2; exit 70; fi
    echo "$out" | tail -1
  }
  push_main() { echo "REACHED_PUSH"; }
  red_rc=0; red=$( (gate "deliberately failing gate" sh -c 'echo simulated-FAIL; exit 1'; push_main) 2>&1 ) || red_rc=$?
  green_rc=0; green=$( (gate "passing gate" sh -c 'echo simulated-PASS'; push_main) 2>&1 ) || green_rc=$?
  if [ "$red_rc" -eq 70 ] && ! echo "$red" | grep -q REACHED_PUSH && [ "$green_rc" -eq 0 ] && echo "$green" | grep -q REACHED_PUSH; then
    echo "SELF-TEST PASS: failing gate -> rc 70, push never reached; passing gate -> push reached."; exit 0
  fi
  echo "SELF-TEST FAIL: red rc=$red_rc output=[$red] green rc=$green_rc output=[$green]" >&2; exit 3
fi

branch="${1:?round branch, e.g. sol/round-1}"
cd "$(dirname "$0")/.."

# ⛔ The whole commonplace-next defect: refuse unless we are on main in a non-worktree checkout.
cur=$(git branch --show-current)
[ "$cur" = "main" ] || { echo "REFUSED: on '$cur', not main. cd to the main checkout." >&2; exit 64; }
[ "$(git rev-parse --git-dir)" = ".git" ] || { echo "REFUSED: this is a linked worktree, not the main checkout." >&2; exit 64; }
git rev-parse --verify -q "$branch" >/dev/null || { echo "REFUSED: no branch $branch" >&2; exit 65; }

before=$(git rev-parse HEAD)
git merge --no-ff -q "$branch" -m "Merge branch '$branch'"
mix deps.get >/dev/null 2>&1 || true

# Gates capture their own exit status. `|| rc=$?` (not a trailing pipeline) so that under
# `set -e` a failing assignment does not exit before the REFUSED line is printed.
gate() {  # gate <label> <cmd...>: run, keep the verdict line, stop on non-zero
  local label="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  mkdir -p tmp; local logf="tmp/land-gate-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').log"
  printf '%s\n' "$out" > "$logf"   # the FULL output, always — a tail-20 can lose the test name on a one-failure red
  if [ "$rc" -ne 0 ]; then
    echo "$out" | tail -20
    { echo "failing tests (full output in $logf):"; printf '%s\n' "$out" | grep -E '^\s+[0-9]+\) test' || echo "  (no test-name lines; read $logf)"; }
    echo "REFUSED: $label failed (rc=$rc); not pushing." >&2
    # ⚠ THE MERGE ALREADY HAPPENED LOCALLY and is left in the tree. origin is
    # untouched -- that is the property that matters -- but local main now carries a
    # merge the gates rejected, and a naive re-run would push it.
    echo "REFUSED: local main still holds the rejected merge. Undo with: git reset --hard $before" >&2
    exit 70
  fi
  echo "$out" | tail -1
}

# PROPERTY 1 of 4, matching .github/workflows/ci.yml — boundary check.
gate "boundary check" elixir test/support/check_commonplace_refs.exs .
# PROPERTY 2 of 4 — the suite, count-asserted (mix test exits 0 on zero selection).
gate "mix test (count-asserted)" bin/yx-test-guard --min 395 -- mix test
# PROPERTY 3 of 4 — Yjs stable conformance, oracle REQUIRED, count-asserted.
YELIXER_REQUIRE_YJS_ORACLE=1 YJS_ORACLE=stable \
  gate "diff_yjs vs stable" bin/yx-test-guard --exact 11 -- mix test test/yelixer/diff_yjs_test.exs --include diff_yjs
# PROPERTY 3b — Yjs preview conformance, reported separately so a preview-only
# regression is visible as itself rather than averaged into the stable verdict.
YELIXER_REQUIRE_YJS_ORACLE=1 YJS_ORACLE=preview \
  gate "diff_yjs vs preview" bin/yx-test-guard --exact 11 -- mix test test/yelixer/diff_yjs_test.exs --include diff_yjs
# PROPERTY 4 of 4 — formatting.
gate "mix format" mix format --check-formatted

git push -q origin main "$branch"
git fetch -q origin
# ⭐ The verdict is what origin says, not what push returned.
if git merge-base --is-ancestor "$branch" origin/main && [ "$(git rev-parse origin/main)" = "$(git rev-parse HEAD)" ]; then
  echo "LANDED: origin/main $(git rev-parse --short origin/main) contains $branch ($(git rev-list --count "$before"..HEAD) new commits)."
else
  echo "NOT LANDED: origin/main $(git rev-parse --short origin/main) does not contain $branch or differs from HEAD." >&2; exit 1
fi
