# Round machinery

Two scripts, ported from `/home/jes/commonplace-next/bin/` and adapted to
yelixer's actual preconditions (measured 2026-08-27, see
`/tmp/claude-1000/-home-jes-yelixer/5174750d-9c87-44e0-87dd-85aec2b927e6/scratchpad/E-round-machinery.md`
for the full account of what changed and why).

## Dispatch a round

```
bin/dispatch-round.sh <round-dir> "<round name as it appears in prompt.txt>" [--preflight]
```

`<round-dir>` must contain `wt/` (a git worktree — see
`git worktree add <round-dir>/wt -b sol/<name> origin/main`) and a non-empty
`prompt.txt` naming the round and running to at least 100 words.

Before dispatch, the script refuses (does not launch anything) unless, on the
HOST:

- the worktree's HEAD is on some remote ref (pushed)
- the worktree's TRACKED files are clean (`git status --porcelain
  --untracked-files=no`)
- `wt/deps/` is already populated (`mix deps.get` run on the host)
- `wt/test/fixtures/node_modules/` is already populated (`npm ci --prefix
  wt/test/fixtures` run on the host — installs the yjs-stable/yjs-preview
  conformance oracles)
- `MIX_ENV=test mix compile` succeeds on the host

Use `--preflight` to run every check and report PREFLIGHT OK / REFUSED
without launching tmux or Sol. Always preflight before a real dispatch.

## Land a round

```
bin/land-round.sh sol/<round-branch>
bin/land-round.sh --self-test   # proves the gate mechanism blocks red and passes green, no git involved
```

Must be run from the main checkout (not a worktree, not a branch other than
`main`). Merges the round branch, then runs — in order, matching
`.github/workflows/ci.yml` — the boundary check, the full suite
(count-asserted via `bin/yx-test-guard --min 414`), both Yjs conformance
oracles (`bin/yx-test-guard --exact 11`, oracle required), and `mix format
--check-formatted`. Any gate failure leaves the merge local and unpushed and
prints how to undo it (`git reset --hard <before-sha>`); only if every gate
passes does it push `main` and the round branch to origin, then verifies the
landing against what `origin/main` actually reports (not the exit code of
`git push`).
