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
overall, and 100 rows per local family per job. File-delivered output JSON is at
most 32 MB by default. `max_bytes:` may lower, not raise, that ceiling. Text is
UTF-8 bounded (PR sections 1,500 bytes each; review
summary/finding and stop summary 1,000 bytes each); validated review results
already limit findings to 30. Oversized collections or encoded output return
an error rather than silently pretending truncated collections are complete.

Only allowlisted fields enter the projection. Full execution logs remain
separately indexed file artifacts and inert evidence; they never become
state-transition authority. Environment values and credentials are never
deliberately logged. Author-written PR/review prose remains untrusted
reported content, not an instruction or independently verified fact.

## Daily action contract

New agent results include `supplemental_references`, using an empty array when
there is no current GitHub context. All result properties are required by the
provider's strict structured-output schema.

Daily preparation now feeds the projection into the existing action workflow.
`DailyDigests.Input` atomically publishes an attempt-unique directory containing
`manifest.json` and `delivery.json`. Files become read-only before publication.
The action's persisted prompt contains only their paths and hashes. Its
`target_snapshot` records both hashes, byte size, projection version, observation
time, window, branch/head, PR numbers, change count and selection limits. The separate local source snapshot
retains its existing ownership, paths and cleanup; it is not the evidence store.
The manifest indexes exact available operation and review captures by durable
source ID and artifact-root-relative manifest path. Missing captures lower
coverage. Workspace setup retains its full combined output independently of the
UI tail, and supported provider sessions are acquired by exact session ID;
unsupported or absent artifacts are explicitly unavailable. Confirmed pane or
workspace shutdown and worktree removal trigger session archival independently of
report generation. Terminal database observations alone do not seal a live session.
Session files and manifests publish together through a unique
staging directory and atomic rename; interrupted copies can be retried. A sealed
archive is never replaced by a later observation.

Agent runs retain their provider/session history in database metadata, including
continuations that reuse a run row. Each session has a distinct hashed directory
identity; the daily index includes every remembered session and marks missing
captures separately. The existing disposable-workspace and planning-snapshot
reapers seal persisted action sessions after shutdown, including after coordinator
restart. A session-manifest identity must match its directory identity.

Archive contents are read-only; their directories remain group-writable so the
coordinator can unlink expired worker-owned files. Archival locks the parent
directory instead of creating persistent sibling lock files. Cleanup failures
are logged. Failed bundle publication releases its captured source checkout;
if removal fails, the source identity is persisted for the failed-action reaper.
Expiration validates every ancestor and uses descriptor-relative deletion with
no-follow directory opens, so swapped or symlinked parents cannot redirect
deletion outside the configured artifact root.

On main-command exit the wrapper terminates its remaining process group (and
operation cgroup when enabled), then drains already-emitted output. A pipe held
by an escaped descendant has a five-second post-exit drain limit and explicit
partial coverage, rather than holding the resource slot indefinitely.

Artifact indexing and exact replay each allow at most 1,000 manifests and 512 MB
of declared stream bytes, with a 30-second hashing deadline. A source manifest
and the bundle manifest are each limited to 1 MB. Application configuration
`:daily_digest_artifact_max_files` and `:daily_digest_artifact_max_bytes` controls
the aggregate limits. Exceeding them returns
`daily_digest_artifact_budget_exceeded`; no report is published with silently
omitted logs. Unknown artifact kinds and malformed stream maps are rejected;
explicit unavailable/error coverage is preserved. Workspace capture sync and
close errors produce error coverage without replacing the command result.

Application settings `:daily_digest_bundle_max_bytes` (default 32 MB) and
`:daily_digest_prompt_max_bytes` (default 100,000; ceiling 300,000) separately
bound file evidence and the complete path-only prompt. Multi-megabyte evidence
therefore does not spend model context before investigation. Preflight
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

File retention defaults to 90 days. Cleanup removes only finalized, expired,
unreferenced bundle and execution directories. It protects every bundle named by
an action snapshot and every execution manifest indexed by those bundles; active
captures have no final manifest and are not eligible. Prompt rejection removes
its newly published bundle immediately.

Temporary provider-session archival failures keep durable teardown pending for retry;
workspace cleanup and source release do not discard their retry records until archival succeeds.
Retries do not retain an execution resource slot.

The worktree cleanup poller also retries provider archival for terminal generic actions
without source snapshots. A persisted completion flag prevents repeated scans; a new
provider session clears it. Pane fallback IDs never select native session files and
are sealed as unavailable when no verified native session association exists.

Native session identities learned during Herdr synchronization join the durable history
and reopen archival. Completion is conditional on the exact history and current external
identity remaining unchanged throughout the copy.

If restart recovery observed a session before dispatch persisted its provider, archival
resolves an unknown mapping from the trusted allocation or invocation provider.
Existing known per-session provider identities take precedence over that fallback.
