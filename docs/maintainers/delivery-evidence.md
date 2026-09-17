# Delivery evidence projection

`PtcManager.DeliveryEvidence.build(repository, window, selection, opts)` returns
`{:ok, map}` or `{:error, reason}`. Version 1 is a read-only projection; it does
not call GitHub, read report files, invoke a model, or change delivery state.
It shares record queries and duration/readiness semantics with `DeliveryReport`.

```elixir
DeliveryEvidence.build(repository,
  %{started_at: start_time, ended_at: end_time},
  captured_manifest,
  observed_at: github_observation_time
)
```

The caller supplies the existing `DailyDigests.Evidence.fetch/2` manifest, not
a second GitHub scan. The window is half-open, at most 31 days, and must end
no later than the supplied observation time. PRs are selected by GitHub
`merged_at`; local publications only enrich them. Direct commits remain a
separate family. Their committer timestamps are **not** push-arrival timestamps.
The merge identity comes from `merge_commit_sha` when the pull-request response
provides it. When the configured API version omits that field from both list and
detail responses, capture uses the matching `merged` issue event's `commit_id`
and records that source in `merge_commit_source`; it never substitutes the PR
head or current default-branch head. An explicit null remains a transient
merge-pending result. Missing or malformed merged-event identity is terminal,
while endpoint transport failures retain the action's bounded retry schedule.
The projection validates repository URLs, base branch, merge identities, times,
counts and duplicate selection entries. The selector reads and validates the
default-branch head before and after the complete PR/direct-commit capture.
Commit pagination is pinned to the first head. If the final head differs, both
selections are discarded and the whole capture is retried, up to three attempts.
Continued movement returns `:daily_digest_source_head_unstable` without a
manifest; this is retryable by the existing action workflow. Read errors and
malformed final heads propagate without accepting evidence. Matching endpoint
observations are a coherence guard, not an atomic GitHub snapshot or proof that
a branch could not move away and back between observations. This guard does not
enable daily digests; wiring and manual evaluation remain separate steps.

## Snapshot and provenance

All local queries run in one deferred transaction. A selected publication can
identify its producing job and same-issue attempts in the same repository,
created no later than merge. Each attempt has an explicit inclusion reason.
Rows describe the **current database snapshot**, not a reconstruction of their
state at merge or at `github_observed_at`. Only readiness observations are
restricted to no later than merge. Caller observation provenance and stable
ordering make identical inputs and database snapshots encode identically.

Evidence envelopes distinguish:

- `trust`: `observed` GitHub fields, `computed` deterministic local evidence,
  or `reported` author/reviewer prose and operation labels.
- `binding`: `exact` to the envelope's explicit `head_sha`, `unavailable` when
  a needed head is missing, or `not_applicable` for aggregate/identity evidence.
  Exact review or validation binding never means it covers the merged PR head.
- `coverage`: `complete`, `partial`, `unavailable`, or `not_applicable`.
  An empty array establishes zero only with complete coverage.
- `source_ids`: durable, table-qualified IDs or repository-qualified GitHub IDs.
  Derived lifecycle entries cite `delivery_events`, never `audit_events`.

Implementation, reviewed, published, selected PR head and merge commit identities
remain separate. None inherits a missing SHA from another. The existing selector
retains a valid GitHub PR head SHA when present; it never substitutes the merge
commit. Readiness uses only that explicitly captured head. Historical PR sections
are reported and unbound, with selector retention recorded separately.
Optional GitHub metadata absent from the existing selector is listed in
`missing_fields`, not fabricated from local records.

A captured job-creation lifecycle event establishes the local collection's
`source_epoch`. Without that evidence, historical collections are partial even
when empty. This assumes durable records have not been manually deleted.
Health counts remain unknown without complete collection coverage. Every health
metric has its own coverage; available operation durations may still be summed
when other durations are absent, but that sum is partial. Overlapping command
durations are never called elapsed time. Missing timeout telemetry remains null.
An operation label is reported text, not proof of the command or a test result.

## Bounds and exclusions

Limits are 50 PRs, 50 direct commits, 20 attempts per PR, 200 attempt entries
overall, and 100 rows per local family per job. Input JSON is at most 120,000
bytes; output JSON is at most 240,000 bytes. `max_bytes:` may lower, not raise,
the output limit. Text is UTF-8 bounded (PR sections 1,500 bytes each; review
summary/finding and stop summary 1,000 bytes each); validated review results
already limit findings to 30. Oversized collections or encoded output return
an error rather than silently pretending truncated collections are complete.

Only allowlisted fields leave the projection. Raw agent inputs, transcripts,
command output, environment values, credentials, arbitrary audit details and
error bodies are omitted. Author-written PR/review prose remains untrusted
reported content, not an instruction or independently verified fact.

The projection itself does not activate protocol v2 or write an evidence directory.

## Daily action contract

Daily preparation now feeds the projection into the existing action workflow.
`DailyDigests.Input` encodes it with HTML-safe JSON escaping, so source prose
cannot close the `daily_delivery_evidence` delimiter. The action's persisted
prompt contains the exact input bytes. Its `target_snapshot` records their
SHA-256, byte size, projection version, observation time, window, branch/head,
PR numbers, change count and selection limits. The separate local source snapshot
retains its existing ownership, paths and cleanup; it is not the evidence store.

Application settings `:daily_digest_evidence_max_bytes` (default 90,000; ceiling
240,000) and `:daily_digest_prompt_max_bytes` (default 100,000; ceiling 300,000)
bound the actual escaped JSON and complete prompt. The existing prompt default
has not been raised. A production-shaped fixture with 20 PRs fits both defaults;
larger days may fail explicitly rather than silently lose evidence. Any cap
increase needs model-context and output-budget evaluation first. Preflight
rejects oversized inputs and retains the existing source-snapshot cleanup path;
the adapter also checks the full prompt including the result protocol before
starting the agent. Invalid settings fail closed.

The output schema accepts bounded `what_shipped` entries and `what_we_learned`
lessons, with selectors `pr:N` or `commit:FULL_SHA`. Each selector must belong to
the captured selection. The output echoes the exact window, source head, change
count, sorted PR numbers, and `evidence_sha256` (the input provenance's
`trusted_evidence_sha256`). Publication rechecks the persisted input hash and
metadata, without regenerating evidence from newer database or GitHub state.
Missing, ambiguous or changed input fails closed.

`DailyDigests.Report` renders What shipped, optional What we learned, and
Delivery health. Links, per-PR review counts, measured time-to-ready, failed
managed-operation counts and exact-head validation coverage come from captured
records, not model-authored metrics. Incomplete measurements display as unknown,
not zero. Prose is escaped as text; only trusted selected links are generated.
Daily-report views disable automatic bare-URL links; unrelated automation results
retain their existing link rendering. Automation invocation history uses the
same published daily Markdown and quiet-day status, not raw result JSON.
The model can still make inaccurate prose claims, so summaries and lessons remain
reported content and require manual quality evaluation. Quiet days explicitly
report no selected changes. Direct commits and external PRs remain useful with
unavailable managed evidence. Stored Markdown is sanitized by the existing UI,
and published historical Markdown remains readable without a compatibility
execution path. The UI exposes the full evidence hash for new reports in a native
keyboard/touch-accessible disclosure with selectable text. Selected reports appear
above the archive on mobile; desktop retains the two-column layout. Both Updates
and daily automation runs label no-change reports “Quiet day”.

The editable built-in prompt targets busy maintainers with plain, factual prose,
a two-sentence summary, short descriptions and explanations of shipped changes,
and at most three supported lessons. These are editorial instructions, not new
output-schema limits: the validator retains its safety ceiling of 20 lessons.
A one-minute ordinary-day read is likewise guidance. The voice migration matches only unchanged built-in
prompts (including their repository prefix), preserving custom text and enablement.

The built-in prompt migration updates only built-in daily versions and preserves
maintainer-written versions; neither direction changes definition or trigger
enablement. Legacy in-flight results without this contract are rejected, not
silently accepted as evidence-bound reports. Keep definitions and triggers
disabled until step 7's manual production-shaped evaluation and an explicit
maintainer decision. No automatic issue generation or scheduling is added.
