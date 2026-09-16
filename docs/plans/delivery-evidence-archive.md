# Delivery evidence for daily updates and workflow insights

## 1. Outcome

Build a deterministic delivery-evidence projection from PtcManager's existing
database records and the bounded GitHub selection already used by daily updates.
Use it first to restore a useful daily update. After several weeks of real use,
reuse the projection for an explicitly requested workflow-insights action that
can propose, but never create, follow-up issues.

The database remains the durable record. Evidence JSON is an action input, not a
second archive:

- a one-day daily update receives bounded JSON inline in its persisted prompt;
- each day's encoded projection is also written to a console-owned evidence
  directory, which is a cache: every file in it can be rebuilt from the
  database, and losing the whole directory loses no record;
- an insights action over at most 30 days mounts that directory read-only beside
  its repository snapshot;
- the files an action is given are hashed for it;
- accepted output cites durable repository, job, publication, review-round,
  operation, event, and audit identifiers.

This plan deliberately adds no evidence scheduler, export table, content-addressed
store, or repository removal protocol.

The evidence directory needs none of those because it is a cache over durable
records, not a second copy of them. A daily action's persisted prompt is the
exact JSON that day was given, `target_snapshot` records its hash, and
`daily_digests` retains the published report. Every file is therefore derivable,
which sets the directory's whole policy: it may be deleted at any time, it is
rebuilt by an explicit command, and no code may treat a file in it as the only
place a fact exists. Retention is "keep what fits, rebuild what is asked for",
not a schedule.

## 2. Decisions and boundaries

### 2.1 Files are an interface, not storage

Agents receive validated JSON rather than a SQLite path or database credentials.
The daily-update agent needs no file interface because one bounded day fits in
the prompt. The later insights agent may use `jq`, `rg`, and ordinary shell tools
over temporary JSON files and the read-only repository snapshot.

The common worker identity means repository scoping is selection and provenance
enforcement, not a confidentiality boundary. The existing snapshot protections
still reject symlinks, validate ancestry and markers, and verify that the worker
cannot write the supplied inputs.

### 2.2 Evidence trust and coverage are explicit

Every value is one of:

- **observed** — returned by GitHub or another external system, with observation
  time and source;
- **computed** — derived deterministically by PtcManager from identified rows,
  with algorithm/schema version;
- **reported** — written by an agent or person and retained as an attributed
  claim.

Commit binding is independent of trust: `exact`, `unavailable`, or
`not_applicable`. Agent-authored prose bound to an exact head remains reported;
it does not become observed merely because the SHA matches.

Each evidence family records `complete`, `partial`, `unavailable`, or
`not_applicable`, plus a bounded reason and source epoch when relevant. An empty
array therefore means a measured zero only when coverage is `complete`; it never
silently means that the feature did not exist or the query failed.

### 2.3 Rich means structured and bounded

The projection includes normalized review findings, managed operations and
durations, lifecycle events, attempts, validation, and retrospective material.
It does not copy raw terminal transcripts, environment values, credentials,
`pre_publication_output`, arbitrary command output, or unbounded errors.
Agent-authored Markdown is bounded, marked reported, and treated as inert data.

Durations are integer milliseconds. Existing operation rows contain an
agent-reported label, not the executed command, so the projection calls it a
“managed operation” and exposes the label with `reported` trust. It does not
classify an operation as a test or claim a command identity. The first version
shows measured values and recurrence, not “abnormal” or “slow” claims that would
require a separately designed baseline.

### 2.4 No capsule table and no automatic issue creation

The existing `DeliveryReport` projection already joins review rounds, operations,
audits, timings, and publication data for one job. Extend and reuse that query at
action preparation; do not persist a snapshot of the join.

An insights agent may propose a defect, refactoring, flaky-test, missing-test,
instruction gap, or other follow-up. Deterministic validation and a person decide
whether it becomes an approved issue-creation action. Model output is evidence,
never authority for a GitHub write or workflow transition.

### 2.5 Partial history is normal

Managed jobs may have rich evidence; external or historical pull requests may
have GitHub data only. Missing records lower the relevant coverage field without
making the whole projection unusable. Daily prose must read naturally from
GitHub-only evidence and must not turn into a list of coverage disclaimers.

Repository removal remains the boundary at which the associated database rows
are deleted. This plan assumes there is no independent pruning of jobs, review
rounds, resource operations, delivery events, publications, or audits. Adding
such pruning later must first define how cited insight provenance survives it.

## 3. Structured implementation outcome

The successful implementer's summary, validation, and retrospective should be
captured while the implementation context is still present. They belong beside
the verified result, but they cannot be fields produced by the deterministic Git
probe itself.

Replace the failure-only agent stop-file contract with one versioned,
discriminated `agent_outcome_report` for the current implementation attempt. It
uses one attempt-scoped random file token and has exactly one outcome:

- `completed`: exact reported `head_sha`, bounded summary, validation, and
  retrospective;
- `stopped`: the existing reason code, summary, detail, prerequisite, and
  progress fields.

The implementation prompt and runtime context expose one report path and one
schema. Review continuation rotates the report token and removes the prior
attempt's file. One path makes simultaneous completed/stopped reports impossible,
so there is no precedence rule.

The job's frozen automation definition version is the cutover marker. Outcome
protocol v2 is required only when that immutable version has
`result_protocol_version: 2`; already-created protocol-v1 jobs retain the
failure-only behavior. Parsing, bounded completion storage, and the result CAS
land before any built-in definition is advanced to v2.

When the result reconciler claims a job under the existing
`result_attempt_token`, it reads and validates that attempt's outcome report:

1. `stopped` takes the existing fenced failure transition;
2. `completed` is attached to the Git-probe result only when its `head_sha`
   equals the probed head;
3. `mark_result_verified` persists the verified Git fields and the bounded
   completion object in the same compare-and-swap and transaction it already
   uses for the result claim;
4. a present but invalid report cannot be interpreted as success and produces a
   bounded reconciliation error;
5. an absent report is recorded as unavailable for protocol-v1 jobs, while
   protocol-v2 jobs are required to produce one.

The stored completion envelope records schema version, report outcome, exact
head, result-attempt observation, review generation, timestamp, and either the
accepted bounded report or a bounded validation failure. It is reported evidence
and cannot change publication eligibility. Broker-created PR bodies format the
accepted summary, validation, and retrospective; historical and agent-published
PR bodies remain separately attributed fallbacks.

The implementation agent may add `ptc:follow-up` only through its already
approved PR-writing authority and existing rules. PtcManager does not infer that
label from retrospective prose.

## 4. Pure delivery-evidence projection

Introduce one pure, versioned projection API used by both products. It accepts a
repository, a bounded half-open time window, and an already captured GitHub
selection. In one deferred database transaction it loads the matching durable
rows and returns validated Elixir data ready for JSON encoding. It performs no
writes and has no filesystem concerns.

For every merged pull request it emits:

- repository, PR number and URL, issue, title, author, labels, base, head, merge
  SHA, merge time, additions, deletions, changed-file count, and commit count
  when observed;
- exact publication and producing-job identifiers when present;
- every same-issue implementation attempt created no later than the merge time,
  with explicit inclusion reason and attempt coverage;
- accepted structured completion material, or bounded historical PR-section
  extraction with its reported provenance;
- final validation state and distinct implementation, reviewed, published, and
  merged heads without substituting one for another;
- normalized review rounds and findings for every included job;
- reported resource-operation label, state, start/end times, duration, exit
  status, timeout/recovery facts, and bounded error category;
- delivery lifecycle events, state changes, stop reasons, audits, and available
  attempt timings;
- one compact health object: review-round count, time-to-ready when measured,
  and failed managed-operation count;
- trust, commit binding, coverage, schema version, and exact durable source IDs
  for every evidence family.

Direct commits remain a separate bounded array selected from GitHub. They retain
the current committer-time caveat and are not assigned fabricated jobs, reviews,
or issues.

The projection validates field lengths, counts, units, enums, and total encoded
bytes. Arrays use semantic stable ordering. Tests prove the same inputs produce
the same encoded JSON, but the bytes need no RFC 8785 implementation because
they are not a long-lived cross-process content address. The action hashes the
exact encoded bytes it actually supplies.

## 5. GitHub selection and provenance

GitHub's `merged_at` remains the selector for the daily half-open window. A
publication row enriches a selected PR; it is not evidence that the PR merged in
that window.

Reuse `PtcManager.DailyDigests.Evidence` and its existing scan-signature logic:
the closed-PR feed is scanned until consecutive bounded scans agree, with the
existing pagination, PR, direct-commit, and byte ceilings. Close its current head
coherence gap at the same boundary: capture the default-branch head before and
after the stable PR scans and retry unless they match. The accepted PR selection
and direct commits are then bound to the same recorded head. Extend the existing
normalizer and body-section handling; do not implement a second stability
algorithm in the delivery projection.

The prepared action records the exact window, captured default branch and head,
GitHub observation time, PR numbers, change count, selection limits, projection
schema version, and SHA-256 of the exact supplied JSON in `target_snapshot`.
The persisted prompt is the durable copy of a daily action's full inline input.
Output must echo the trusted window, source head, change count, and evidence hash
before it can be accepted.

A later insights action may make read-only GitHub calls for current issues, pull
requests, commits, or repository state. Those reads are separately marked
supplemental with URL and observation time. They cannot rewrite facts in the
prepared evidence projection.

## 6. Daily update first

### 6.1 Preserve useful PR sections

Fix the current truncation before changing the digest contract. Raise the
600-character PR-body limit and add a bounded Markdown heading extractor. Under
manifest pressure retain `Summary`, `Validation`, and `Retrospective`, with
Summary first. Shorten retained sections before dropping bodies, and record
per-PR coverage. Start with the PR #1981 shape as a failing
test. This remains the fallback for external and historical PRs.

### 6.2 Inline one bounded day

At daily-action preparation:

1. use the existing stable GitHub selection;
2. build the pure delivery projection from that selection and one database
   snapshot;
3. encode and validate it once;
4. record its trusted provenance and exact byte hash in `target_snapshot`;
5. inline it in the persisted prompt under a clearly delimited inert-data block;
6. reject the action before dispatch if the evidence or final prompt exceeds a
   measured configurable cap.

Raise the current cap only after fixtures show the rich one-day shape fits the
chosen model's context with room for instructions and output. Do not add an
evidence directory, change snapshot path semantics, or alter the snapshot reaper
for the daily update.

### 6.3 Output contract

The daily output contains:

1. **What shipped** — concise summary, why it matters, links, and validation
   confidence for the delivered commit;
2. **What we learned** — explicit retrospective follow-ups or repeated concrete
   review/validation lessons, omitted when empty;
3. **Delivery health** — one factual line per PR using review rounds,
   time-to-ready when measured, and failed managed operations.

The agent may omit low-value detail but may not invent counts, durations,
coverage, or provenance. The digest is not an issue generator.

### 6.4 The evidence directory

The same encoded bytes the daily action is given are also written to a
console-owned root, configured like the existing planning snapshot root:
`PTC_DELIVERY_EVIDENCE_ROOT`, defaulting under a release to
`/var/lib/ptc_manager-output/delivery-evidence` and otherwise unset. Layout is
deterministic and needs no index to navigate:

```
<root>/<repository>/<YYYY-MM-DD>.json
<root>/<repository>/<YYYY-MM-DD>.report.md
```

A day is written exactly once per generation, by atomic rename. The console
writes it; agents only ever read it. The same permission check the planning
snapshot already applies must confirm the agent user cannot write this root.

Each file records how it came to exist, because the two ways are not equivalent:

- `replayed` — the exact bytes that day's action was given, recovered from its
  persisted prompt and verified against the hash in `target_snapshot`. Available
  only for a day whose action ran.
- `backfilled` — generated later by running the projection over that day's
  window against current rows. Available for any day, including days that
  predate the feature. It is honest about being a later reconstruction: rows
  that landed after that day ran are included, and the GitHub-observed families
  are re-observed or marked unavailable.

A file never mixes the two, and a consumer never has to guess which it holds.
Replay is preferred wherever it is possible.

A day with no merged pull requests is a measured zero under §2.2, not a gap: it
writes an ordinary file with `complete` coverage and empty arrays. The three
states are therefore distinguishable without inference — an absent file means
the day was never generated, a present file with `unavailable` coverage means
generation ran and the source failed, and a present file with `complete`
coverage and no changes means a quiet day.

Regeneration is an explicit, idempotent command taking a repository and an
inclusive date range, exposed as a mix task and over the release RPC already
used to drive console actions. It is the backfill path, the disaster-recovery
path, and the way a failed day is retried. Running it twice over the same range
produces the same files. It never reaches GitHub for a day it can replay.

## 7. Delivery insights later

Do not schedule this initially. Add a maintainer button after several weeks of
daily updates reveal which evidence is useful in practice.

The on-demand `delivery_insights` action selects a bounded window of at most 30
days. Its days come from the evidence directory of §6.4, so there is no per-run
export: preparation ensures the range is complete, regenerating any missing or
failed day through the same idempotent command, then copies those days into a
temporary `evidence/` sibling beside the existing read-only repository snapshot.
Files stay split per day so the agent can investigate them with `jq`, `rg`, and
shell tools.

The agent is given a directory to search, not a prepared argument. For every day
of the window it carries the encoded projection and, where one was published,
that day's report from `daily_digests`.

Preparation never silently tolerates a hole. A day it cannot produce is listed
in the manifest as unavailable with a bounded reason and is absent from the
directory; it never becomes a gap the agent has to infer, and it never blocks
the action.

A day keeps the projection schema version it was built with, and whether it was
`replayed` or `backfilled`. The manifest records both per file, so the agent
neither reads an older shape as though it were current nor mistakes a later
reconstruction for what was reported at the time.

A small manifest lists every file, byte hash, projection version, database source
IDs, window, and repository source SHA. It states plainly that the projection
files are the evidence and the prior reports are context: a proposal cites
durable source IDs, never a sentence from an earlier update. Prose is cheaper to
read than JSON, so without that instruction an agent will summarize old reports
instead of examining the records underneath them.

This later slice changes the snapshot contract explicitly. One action-owned
`input_root` contains `repository/` and `evidence/`; `repository_path` is the
verified Git child and agent working directory, while `input_root` is the exact
marker, ownership, tombstone, and cleanup unit. Handoff verifies both children;
release and the reaper validate their ancestry and delete the parent. These
adapter and cleanup changes land together with the insights action and are not a
prerequisite for the daily update. The action fails before dispatch on file-count
or byte ceilings. After validated output is persisted, the temporary input root
is deleted through that action-owned lifecycle.

The agent looks for:

- recurring review findings or repeatedly edited modules;
- repeated failed or increasingly long managed operations;
- repeated flaky-test reproductions;
- recurring stop reasons, setup failures, or missing repository instructions;
- several deliveries pointing to the same refactoring need;
- a single strong terminal failure or explicit retrospective follow-up;
- a concern an earlier daily update already raised that later days show
  recurring, which the single-day view cannot distinguish from a one-off.

Each structured proposal cites exact durable source IDs, PRs, commits, review
rounds, operations, date range, and reproduction where available. It explains
why the evidence is systemic rather than ordinary implementation iteration.

### 7.1 Human-approved issue creation

Repository-scoped suggestion validation and approval come with insights, not the
daily-update restoration. Before approval, deterministic code constructs the
final issue title and body, including human-readable GitHub links, durable source
IDs, the action-input hash, and an idempotency marker. The UI shows the literal
payload that will be written.

The trusted writer receives only that validated payload. It may create exactly
one byte-equivalent issue, or make no change when deterministic postflight finds
the same marker or exact normalized payload. A semantic-only duplicate remains
unresolved for maintainer confirmation; model judgment cannot complete it.

## 8. Implementation order

The first seven items restore the daily update. Each should normally be its own
issue and pull request.

1. **Preserve PR sections.** Add the bounded heading extractor, increase the body
   allowance, and keep Summary, Validation, and Retrospective during compaction,
   shortening sections before dropping them.
2. **Prepare outcome protocol v2.** Add the discriminated completed/stopped
   schema and reader plus bounded completion fields. Extend the existing result
   compare-and-swap to persist accepted completion data atomically beside the
   verified Git result. Keep every built-in definition on protocol v1, so this
   slice changes no live agent contract.
3. **Activate and publish outcome protocol v2.** Create new immutable built-in
   automation versions with `result_protocol_version: 2`, update the
   implementation prompt and runtime context, rotate the one per-attempt report
   token on continuation, and format broker-created PR bodies from accepted
   completion data. Existing jobs remain governed by their frozen v1 version.
4. **Add the pure projection.** Extend `DeliveryReport`, join all included
   attempts in one database snapshot, reuse the existing stable GitHub scan, and
   validate trust, binding, coverage, bounds, and deterministic encoding.
5. **Replace the daily-update contract.** Inline the rich one-day projection,
   persist its hash and trusted selectors, update the output schema and renderer,
   and retain graceful GitHub-only entries.
6. **Add the evidence directory and its regeneration command.** Write each day's
   encoded bytes and published report under the configured root, record whether
   a file was replayed or backfilled, and ship the idempotent mix task and
   release RPC that rebuild an arbitrary date range. Prove the root is not
   agent-writable and that deleting it loses nothing.
7. **Operate before enabling.** Run manual production-shaped daily actions,
   measure prompt size and output quality, document the disable migration's
   intentional asymmetric rollback, then update `Automations.Defaults` so new
   repositories get an enabled definition plus enabled built-in manual and
   scheduled triggers, and migrate those same rows for existing repositories.
   Do not make the existing disable migration's `down/0` silently reactivate its
   trigger.

Later work is deliberately separate:

8. **Add on-demand delivery insights.** Add the button, a window bounded to at
   most 30 days, completeness-checked assembly from the evidence directory,
   action-owned input root with repository/evidence children and manifest,
   read-only GitHub inspection, structured proposals, and atomic
   adapter/release/reaper support for the new cleanup unit.
9. **Add repository-scoped issue approval.** Generalize suggestion validation,
   persist the literal approved payload and durable evidence IDs, and constrain
   the trusted writer and postflight to an exact zero-or-one issue delta.

## 9. Validation and failure policy

Every bug fix starts with a failing reproduction. In addition to
`mix precommit`, implementation slices cover:

- PR #1981-shaped bodies and compaction priority;
- completed, stopped, absent historical, malformed, stale-token, wrong-head,
  and review-continuation outcome reports;
- one atomic compare-and-swap for completion data and verified Git results;
- exact timezone and daylight-saving boundaries;
- reuse of the existing stable-scan behavior under concurrent GitHub movement;
- a merge racing the scan, proving the before/after default-branch heads must
  match before the PR selection is accepted;
- managed, external, historical, failed-attempt, and partial-lifecycle PRs;
- explicit zero versus unavailable coverage;
- reported operation labels, duration units, overlapping operations, and missing
  telemetry without invented command identities or test classifications;
- deterministic ordering, field bounds, and exact supplied-byte hashes;
- an inline digest at and above both evidence and prompt byte ceilings;
- source-head, PR-number, change-count, window, and evidence-hash mismatch;
- a GitHub-only daily update and a fully enriched managed update;
- temporary insight evidence that is read-only, bounded, reverified, and cleaned
  after success, failure, restart, and repository removal;
- a replayed day reproducing its action's prompt bytes exactly and failing
  closed when the recorded hash does not match, never falling back to a silent
  regeneration;
- a backfilled day for a date with no action at all, labelled as such, and a day
  whose backfill and replay differ because rows landed after it ran;
- a quiet day with no merged pull requests written as `complete` coverage with
  empty arrays, distinguishable from a failed day and from a day never
  generated, with no consumer inferring which it holds;
- regeneration run twice over the same range producing identical files, run over
  a partly present range touching only what is missing, and reaching GitHub for
  no day it can replay;
- the whole evidence directory deleted and rebuilt, losing nothing a durable
  record still holds;
- the evidence root rejected when the agent user can write it;
- a window whose days carry an older projection schema version, reaching the
  manifest as versioned entries without failing the action;
- a window requested beyond 30 days, rejected before any file is written;
- deterministic duplicate issue handling with no unapproved GitHub write;
- protocol-v1 jobs completing after v2 deployment and v2 jobs requiring exactly
  one valid outcome report;
- default creation and migration enabling the daily definition plus both built-in
  triggers for existing and newly added repositories.

A projection or GitHub-selection failure does not enter maintenance mode and
does not block delivery. It fails or defers only that analysis action with a
bounded visible reason. Missing historical enrichment lowers coverage; it never
authorizes publication of another commit or invention of a value.

## 10. Documentation and non-goals

Document the projection schema, trust classes, metric caveats, prompt caps,
source-ID provenance, and the manual insights workflow. Document the evidence
directory as operational state: its configured root, its layout, the fact that
it is safe to delete, and the regeneration command that rebuilds a date range.
The console should show the selected window, evidence hash, change count,
coverage summary, and bounded failure for each action.

Non-goals for this design:

- an evidence store that is itself a record — the directory is a rebuildable
  cache over the database, never the only place a fact lives;
- querying SQLite from an agent;
- scheduled workflow-insight generation;
- automatic issue creation;
- statistical anomaly detection;
- raw terminal-output retention;
- replacing the delivery-report page;
- preserving evidence after repository removal.
