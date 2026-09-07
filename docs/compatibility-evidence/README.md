# Evidence index

Read [the report](../cross-runtime-compatibility-report.md) for verdicts, causes,
exact configurations, commands, scope and limitations.

* `minimal-blocker-packet.json`: minimal original bytes and old/candidate results,
  separated into incoming edits, legacy replay and candidate-write rollback.
* `baseline-closure.json`: observed shared checkout refs/locks/installed dependencies,
  plus the separately identified pristine Next baseline actually executed.
* `candidate-closure.json`: exact candidate locks and verified installed Git revisions.
* `named-outcomes.json`: actual ExUnit case names and outcomes; defined-but-excluded
  cases are labeled separately. Failed prerequisites that never reached ExUnit have
  no case record and are described in the report.
* `synthetic-oracle-transcripts.json`: only deterministic synthetic library and application matrix
  commands/responses, including author IDs, exact update bytes and state vectors.
* `fixture-sha256.json`: hashes of immutable source fixtures, including verification
  that the original old-writer file is unchanged.
* `history-observations.json`: two reader revisions and independent real Yjs views
  for identical immutable bytes. Writer observations are not inferred provenance.

History source bytes and generators live in `test/fixtures`. The original old-pin
fixture is unchanged. New JSON uses escaped Unicode; the shared fixture description
records independent code points, grapheme counts and UTF-16 units. New-history
acceptance derives its intermediate expected strings from the specified operations,
not the candidate's recorded output.

Raw application/full-suite logs remain local and are not part of this public
evidence bundle. No real user history or credentials are included.
