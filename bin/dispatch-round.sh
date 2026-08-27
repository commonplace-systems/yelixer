#!/usr/bin/env bash
# Launch a Sol round in a tmux pane — refusing to launch NOTHING, and refusing
# to launch a round that CANNOT pass its own CI for reasons the round did not
# cause.
#
# Ported from commonplace-next/bin/dispatch-round.sh (the most evolved copy in
# the fleet: 2026-08-27). The SHAPE is copied — refuse-on-empty-prompt,
# refuse-on-unpushed-base, refuse-on-dirty-tree, refuse-on-unfetchable-deps,
# verify the running process by captured pid, never by a self-matching
# pgrep/pkill. The GATE LIST is yelixer's own, established by measurement in
# this repo on 2026-08-27 — see bin/README-rounds.md for what changed and why.
#
# WHY THE PROMPT-EMPTINESS GATE EXISTS (unchanged from commonplace-next,
# 2026-08-24 phase 7): a launcher that can dispatch nothing must refuse to.
#
# WHY THE DEPS GATE EXISTS, YELIXER VERSION:
# ⭐ FETCHING IS A HOST ACT, NEVER A FENCED ONE. A fenced round has masked
# credentials and no network egress (see sol-egress-run.sh's own banner: it
# grants egress but the credentials a `mix deps.get` or `npm ci` needs are
# scrubbed). yelixer's CI needs TWO fetched trees this repo did not need
# before it grew a JS-based conformance oracle:
#   - deps/            (mix deps.get: jason, telemetry, stream_data)
#   - test/fixtures/node_modules   (npm ci --prefix test/fixtures: yjs-stable
#     13.6.32, yjs-preview 14.0.0-16 — the wire-conformance oracles)
# A fenced round must never be the first thing to attempt either fetch. This
# script verifies BOTH are already populated on the HOST worktree and refuses
# to dispatch if not — it does NOT run `mix deps.get` or `npm ci` itself,
# because doing so silently launders a host-fetch requirement into "the
# script handled it", and the next repo's copy would then assume the fetch is
# always safe to automate. State it, don't paper over it.
#
# Usage: bin/dispatch-round.sh <round-dir e.g. /home/jes/sol-yx1> <round-name e.g. "yx round 1"> [--preflight]
set -euo pipefail
dir="${1:?round dir}"; name="${2:?round name as it appears in the prompt}"; mode="${3:-}"  # --preflight: run every refusal check, dispatch nothing
wt="$dir/wt"; prompt="$dir/prompt.txt"

[ -d "$wt/.git" ] || [ -f "$wt/.git" ] || { echo "REFUSED: no worktree at $wt" >&2; exit 64; }
[ -s "$prompt" ] || { echo "REFUSED: $prompt is missing or empty — nothing to dispatch." >&2; exit 65; }
grep -qF -- "$name" "$prompt" || { echo "REFUSED: prompt does not name the round '$name'." >&2; exit 65; }
[ "$(wc -w < "$prompt")" -ge 100 ] || { echo "REFUSED: prompt is $(wc -w < "$prompt") words; a real brief is longer." >&2; exit 65; }

base=$(git -C "$wt" rev-parse HEAD)
git -C "$wt" fetch -q origin
git -C "$wt" branch -r --contains "$base" | grep -q . || { echo "REFUSED: worktree HEAD $base is on no remote ref. Push first." >&2; exit 66; }

# ⛔ CLEAN-TREE GATE, ADAPTED FOR YELIXER: this repo's TRACKED tree is what
# must be clean, not the whole working directory. The whole directory is
# PERMANENTLY dirty at present — `y-crdt/` and `yjs/` are untracked
# directories on disk (a separate in-flight change is expected to rename or
# .gitignore them), and a stray untracked file has already appeared once
# during this investigation (test/fixtures/yjs_diff_driver_c5b_569491.mjs).
# A gate keyed to those specific paths would go stale the moment either
# disappears or a new one appears; a gate keyed to "no untracked files at
# all" would NEVER pass on this tree and so would never be a gate, only a
# permanent refusal. `git status --porcelain --untracked-files=no` reports
# only staged/unstaged changes to TRACKED files, which is the actual
# invariant a round needs (it starts from a known committed tree) and is
# blind to however many untracked directories or files happen to exist.
[ -z "$(git -C "$wt" status --porcelain --untracked-files=no)" ] || { echo "REFUSED: tracked files in the worktree are dirty; a round must start from a committed state." >&2; exit 67; }

# ⭐ MEASURED 2026-08-27: this repo's deps/ and test/fixtures/node_modules are
# BOTH gitignored (see .gitignore: "/deps/"; node_modules is npm-standard
# ignored). A `git worktree add` / fresh clone therefore produces a worktree
# with NEITHER populated, exactly the NEXT-RACE-B shape from commonplace-next
# one directory over. CI needs deps/ for `mix test` and node_modules for the
# two --exact 11 conformance jobs; a round dispatched without both would burn
# its whole budget on failures that have nothing to do with the brief.
[ -d "$wt/deps" ] && [ "$(ls "$wt/deps" 2>/dev/null | wc -l)" -gt 0 ] || {
  echo "REFUSED: $wt/deps is missing or empty — the fence cannot run 'mix deps.get' (no network egress with credentials), so every mix command would fail for a reason the round did not cause." >&2
  echo "  Fix on the HOST first:  (cd $wt && mix deps.get)" >&2
  exit 68; }

[ -d "$wt/test/fixtures/node_modules" ] && [ "$(ls "$wt/test/fixtures/node_modules" 2>/dev/null | wc -l)" -gt 0 ] || {
  echo "REFUSED: $wt/test/fixtures/node_modules is missing or empty — the fence cannot run 'npm ci' here, so the diff_yjs conformance suite would raise (YELIXER_REQUIRE_YJS_ORACLE=1) or silently skip for a reason the round did not cause." >&2
  echo "  Fix on the HOST first:  npm ci --prefix $wt/test/fixtures" >&2
  exit 69; }

# ⭐ Compile on the HOST before dispatch, same reasoning as commonplace-next's
# deps.get/compile pair: this surfaces a compile failure as a dispatch
# refusal instead of burning round time re-discovering it.
rc=0; out=$(cd "$wt" && MIX_ENV=test mix compile 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "$out" | tail -5; echo "REFUSED: test compile failed on the host (rc=$rc)." >&2; exit 68; }

[ "$mode" = "--preflight" ] && { echo "PREFLIGHT OK: $dir would dispatch '$name' (deps $(ls "$wt/deps" | wc -l), oracle node_modules $(ls "$wt/test/fixtures/node_modules" | wc -l), compiled)."; exit 0; }

win="$(basename "$dir")"
tmux new-window -d -t 0: -n "$win" -c "$dir" \
  "SOL_WORKDIR=$wt /home/jes/boss-clod/sol-egress-run.sh \"\$(cat $prompt)\" 2>&1 | tee $dir/sol-run.log; echo \"=== sol EXITED rc=\${PIPESTATUS[0]} ===\"; sleep 86400"
sleep 20

# ⭐ Verify on the RUNNING pids, and capture the outer pid.
# ⛔ NEWEST tree first: prefer the youngest process, so a lingering orphaned
# wrapper from a finished round is never mistaken for this round's outer pid.
n=0
for pid in $(ps -eo etimes,pid,cmd | awk -v d="$wt" '/[c]odex exec -m gpt-5.6-sol/ && index($0,d) {print $1, $2}' | sort -n | awk '{print $2}'); do
  n=$((n+1))
  echo "$pid prompt=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -cF -- "$name") masks=$(grep -c tmpfs /proc/$pid/mountinfo) -C=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -A1 -x -- '-C' | tail -1)"
  [ -z "${outer:-}" ] && outer=$pid && echo "$pid" > "$dir/outer.pid"
done
[ "$n" -gt 0 ] || { echo "NOT RUNNING: no codex process on $wt after 20s. Read $dir/sol-run.log." >&2; exit 1; }
echo "DISPATCHED $name in tmux window $win, outer pid $(cat "$dir/outer.pid"); wait on it by pid."
