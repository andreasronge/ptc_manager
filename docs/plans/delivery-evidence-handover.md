# Handover: restoring the daily update

Working notes for whoever picks up [#135] next. Written 2026-09-16, after the
first two implementation steps. Delete this file with the plan it accompanies,
when #135 closes.

Read [`delivery-evidence-archive.md`](delivery-evidence-archive.md) first — it
is the design, and it is on `main`. This file only records where the work
stopped and what is already known to be wrong.

## Where things stand

The plan has nine steps. Two have been attempted.

| Step | What | State |
| --- | --- | --- |
| 1 | Preserve PR sections | Merged as [#137], then found to regress; fix open as [#141] |
| 2 | Prepare outcome protocol v2 | Written, reviewed five times, **parked as draft [#139]** |
| 3 | Activate outcome protocol v2 | Not started |
| 4 | Add the pure projection | **Not started — start here** |
| 5 | Replace the daily-update contract | Not started |
| 6 | Add the evidence directory | Not started |
| 7 | Operate before enabling | Not started |
| 8 | On-demand delivery insights | Deliberately later |
| 9 | Repository-scoped issue approval | Deliberately later |

Open issues: [#135] umbrella, [#138] step 2, [#140] the step 1 regression.

## Start with step 4, not step 3

The plan orders step 2 and 3 before the projection. That ordering is a
preference, not a dependency, and following it has not been productive.

§4 of the plan says the projection takes its evidence from "accepted structured
completion material, **or** bounded historical PR-section extraction with its
reported provenance". Step 1 shipped the second one. So steps 4 and 5 — the
projection and the daily-update contract — work today without steps 2 or 3, and
they are the two that produce something a maintainer can actually read.

Come back to step 3 once a daily update has run for a while and shown which
evidence is worth having.

## What is live right now

Daily updates are **enabled for `ptc_runner`** on `main`
(`Automations.Defaults.triggers/2` gates on `repository.github_name`). Anything
you change in `PtcManager.DailyDigests.Evidence` reaches a running automation.

There is uncommitted work in the primary checkout that disables them; see
"Uncommitted work" below.

## The two open pull requests

### [#141] — fix the step 1 regression. Merge this.

CI green. It fixes a live defect that [#137] introduced and that CI, a full
`mix precommit`, and the author's own testing all missed.

The short version: #137 replaced a flat 600-character body slice with bounded
Markdown sections, but left only two compaction rungs — keep the sections whole,
or delete every body. On a day of long descriptions both miss the 60,000-byte
manifest ceiling, so the digest receives *no* pull request prose where the flat
slice would have kept 600 characters each. Measured:

| merged PRs | whole | after dropping prose | outcome |
| --- | --- | --- | --- |
| 10 | 47,434 | 32,304 | kept whole |
| 15 | 71,164 | 48,469 | prose dropped |
| 20 | 94,894 | 64,634 | **all bodies dropped** |
| 30 | 142,354 | 96,964 | **all bodies dropped** |

#141 adds a rung that shortens sections first, moves `summary` to the front of
the priority set (the built-in prompt asks what changed; the old order kept
"Untracked follow-up work: none" and discarded the answer), states body coverage
per pull request, and fixes three parser faults: fenced code blocks scanned for
headings, `###` sub-headings ending their parent section, and only exact heading
spellings matching.

### [#139] — outcome protocol v2. Leave it parked.

Draft on purpose. Six commits, CI green, rebased on current `main`. Everything
in it is dormant: no built-in definition sets `result_protocol_version: 2`, so
none of the code runs.

It is not on the path to a useful daily update. It was parked rather than merged
because merging dormant code buys risk without function — and this branch has
twice modified live protocol v1 behaviour by accident.

The pull request description carries the full review history and five known
gaps. Read it before touching the branch. The gaps in brief:

- nothing reads `jobs.result_completion`; step 3 is what connects it;
- `ReportFile.read_json/2` collapses a read timeout, a permission error and an
  oversized file into the same reason as malformed JSON;
- a rotated report token orphans the previous attempt's file in the shared
  output directory;
- `jobs.stop_report_token` holds a v2 *outcome* token under v2; renaming it is
  cheaper while the path is dormant;
- `record_job_stop_report/5` keeps a weaker fence with no claim-expiry check.

## Uncommitted work in the primary checkout

`/Users/andreasronge/projects/ptc_manager` is on `fix/review-long-line-digest`
with **three unrelated changes mixed together**. Nothing here is committed, and
the repository convention is that unrelated fixes go on their own branch off
`origin/main`. Do not commit them as one change.

1. **Disable daily digests pending redesign** — `automations.ex`,
   `automations/defaults.ex`, `daily_digest_live.ex` and its template, the
   untracked migration
   `priv/repo/migrations/20260916093000_disable_daily_digests.exs`, part of
   `config/runtime.exs`, `deploy/ptc_manager.env.example`, part of
   `README.md`, and five test files. This is effectively step 0 of the plan and
   should land before step 7 turns updates back on.
2. **Resource-operation recovery retry** — `resource_operation_recovery.ex`
   returns `{:retry, ...}` where it returned `{:error, ...}`, plus the
   `resource_operation_cgroups` production default in `config/runtime.exs`, plus
   `resource_operations_test.exs`.
3. **Disposable deployment target** — `disposable_deployment_target_test.exs`
   (+96 lines) and related fixture changes.

Splitting these means hunk-level work in `config/runtime.exs` and `README.md`.
Ask before guessing the boundaries.

## Checking your work locally

No database, token, or server needed to see what a pull request body becomes:

```
gh pr view 134 --json body -q .body | mix ptc.digest.preview -
```

It prints the extracted sections and what survives each rung of compaction.

For the browser, demo mode has deterministic data on its own database:

```
PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db mix ptc.demo.reset
PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db PORT=4100 mix phx.server
```

Never point the demo reset at the development database. The daily update's page
is `PtcManagerWeb.DailyDigestLive`; the seed data that gives it a history is at
the bottom of `priv/repo/seeds.exs`.

## What went wrong, so it does not go wrong again

Five independent review rounds on [#139] produced 71 findings, and rounds two
through five each found defects introduced by the previous round's fixes. Two
were changes to live protocol v1 behaviour in a pull request whose description
claimed it changed nothing live. The post-merge review of [#137] then found the
regression above.

Concretely, for this area:

- **`mix precommit` passing is not evidence that the digest still works.** The
  #137 regression survived CI, the full suite, and manual testing, because no
  test measured the encoded manifest against its own ceiling with realistic
  bodies. If you change anything about body extraction or compaction, add a test
  that encodes a realistic day and asserts against `@max_manifest_bytes`.
- **A JSON schema can be unsatisfiable and everything still passes.** The v2
  schema initially rejected every legal report, because both `oneOf` branches
  set `additionalProperties: false` without declaring the root-level
  `schema_version`. Validate new schemas with a real Draft 2020-12 validator
  against a known-good document.
- **Anything that touches `HerdrAdapter`'s prompt is live.** Extracting a shared
  sentence silently rewrote the instruction every running agent receives. There
  is now a test pinning the v1 wording verbatim; keep it.
- **Widening a slice widens its blast radius.** Step 2 was specified as schema,
  reader, column and compare-and-swap. It grew to include reconciler branching,
  dispatch wiring and a prompt rewrite, which pulled in the review-pause
  machinery, the worktree allocation lifecycle and the retrospective channel —
  and every patch to one collided with another. Keep step 4 to the projection.
- **Evidence failures must not withhold delivery.** This is the plan's own rule
  (§9) and the thing that resolved the worst of the v2 churn: a missing or
  unreadable report lowers what is known about a change; it never blocks work
  PtcManager verified itself. The one exception is a *stop*, which still
  outranks the branch.

## Worktrees

Non-Codex worktrees in play, all on the same repository:

| Path | Branch | For |
| --- | --- | --- |
| `ptc_manager` | `fix/review-long-line-digest` | primary checkout, dirty — see above |
| `ptc_manager-wt3` | `feat/outcome-protocol-v2` | [#139], parked |
| `ptc_manager-wt4` | `fix/digest-evidence-ladder` | [#141] |
| `ptc_manager-wt5` | `docs/delivery-evidence-handover` | this file |

`ptc_manager-wt` and `ptc_manager-wt2` predate this work.

Remove wt3, wt4 and wt5 with `git worktree remove` once their branches land or
are abandoned.

[#135]: https://github.com/andreasronge/ptc_manager/issues/135
[#137]: https://github.com/andreasronge/ptc_manager/pull/137
[#138]: https://github.com/andreasronge/ptc_manager/issues/138
[#139]: https://github.com/andreasronge/ptc_manager/pull/139
[#140]: https://github.com/andreasronge/ptc_manager/issues/140
[#141]: https://github.com/andreasronge/ptc_manager/pull/141
