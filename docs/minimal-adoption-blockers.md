# Minimal adoption evidence: baseline versus candidate

The subsequent [incoming codec repair](unicode-inbound-repair.md) has its own
baseline/fixed comparison. The historical rows below retain their original pins.

This supplement answers the delayed ranking-seat evidence request. No full suite
was repeated. The [minimal packet](compatibility-evidence/minimal-blocker-packet.json)
contains exact base/candidate pins, original bytes, operation sequences, and separate
observations. These are the exact repository configurations inspected for this round,
not a fresh assertion about deployed bytes or live user history.

## Incoming edit — present in both codecs, different wrong output

Yjs 13.6.32, author 100: insert `\u{1F600}A` at 0, then `X` at UTF-16 position 1.
Apply these identical two updates in sequence to each reader:

```
base:  01016400040107636f6e74656e7405f09f98804100
delta: 01016403c464006401015800
```

| Observer | Measured resulting text |
|---|---|
| Real Yjs | `\u{FFFD}X\u{FFFD}A` |
| Old pinned Yelixer `bc35a0e9ff374449c71fb29be159bd9a711635bb` | `\u{1F600}XA`, accepted |
| Candidate Yelixer `bcaec6a3520c59464bab87daaab7e4f76546c9c5` | `\u{1F600}XAA`, accepted |

This incremental-receipt defect is **not candidate-only**. The candidate additionally
duplicates `A`. A fresh load of the final full Yjs state gives `\u{FFFD}X\u{FFFD}A`
under both codecs, so a full-state-only probe would miss the divergence.

The candidate's **actual Next route** also accepted and durably acknowledged the
browser operation with its divergent suffix. That desired-behavior test executed
and failed; its default exclusion is not evidence of safety. **Old Next application admission is now measured too:** the same single arm,
with the unchanged published dependency set, durably acknowledged the edit and
retained `\u{1F600}XA`. The acknowledged head matched the snapshot head before the
text assertion failed. One case executed and failed, 25 were excluded, rc 2.
The application source was `94abc915`; subsequent main `a538fa18` has identical
manifest and lock bytes (Git-verified). This is an isolated application test, not
a live-target observation. A first attempt retained copied candidate dependency
BEAMs and is invalidated; the verified attempt forced compilation of the exact
old dependencies as well as the application. Separately, the
old application dependency set already failed the actual Workspace scalar-boundary
Unicode second-append test (`unsupported_edit`), while the candidate passed it.

## Legacy replay — measured and accepted compatibility cost

The minimal old-writer example inserts `e\u{0301}b`, then appends `!` at its old
grapheme position 2. The two original updates and exact writer revision are in the
packet, copied from the unchanged immutable old-history fixture.

| Observer of identical incremental history | View after append |
|---|---|
| Original writer and old reader | `e\u{0301}b!` |
| Real Yjs | `e\u{0301}b` |
| Candidate reader | `e\u{0301}b` |

Browser disagreement therefore predates the candidate. Replacing the old reader
also loses the previously preserved old-server view: that is an upgrade regression
for this saved synthetic history. Neither observation establishes what any live
user intended; no live corpus was inspected. Wire bytes do not reliably identify
which clock convention authored them.

## Candidate-write rollback — measured limit of the accepted break

With the candidate writer, append `!` to the same base at UTF-16 position 3. The
candidate and real Yjs retain `e\u{0301}b!`; the old reader yields `e\u{0301}b`.
The exact two candidate-authored updates are separately retained in the packet.
This is a rollback/mixed-version limit, not the legacy replay population.

## Reproduce the incoming comparison

Run the existing reporter under each exact reader checkout, with the same fixture:

```
ERL_FLAGS='+S 1:1 +SDcpu 1 +SDio 1' MIX_ENV=test \
HISTORY_INPUT=/path/to/candidate/test/fixtures/incoming-half-surrogate.json \
HISTORY_REPORT=/tmp/incoming-reader.json \
nice -n 19 mix run /path/to/candidate/test/support/report_history.exs
```

The candidate path supplies the already used helper and real Node oracle; Mix loads
the production reader from the current checkout. Both minimal runs completed,
without exclusions or missing oracles. The output records incremental and fresh
full-state observations separately. The existing old/candidate history reports
supply the replay and rollback rows; those suites were not repeated.

**Adoption stays blocked by incoming new-edit divergence.** An enforced safe inbound
boundary or convergence repair is required. The user ruling of 2026-09-05 18:52:45 UTC
permits breaking our own history where needed to match official Yjs 13.6.32. Legacy
view changes and old-reader rollback limits are accepted compatibility costs, not
adoption gates; the former required-migration proposal is withdrawn. This permission
does not authorize deleting or resetting live stores. Experimental candidate branch
pins remain evidence configurations, not adoption into main or deployment.
