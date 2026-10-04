# Plan: the research steward

Status: draft, 2026-09-18, revised after two independent review rounds. Not
implemented. Companion to [`collection-steward.md`](collection-steward.md):
that plan keeps a collection of *deliverables* moving; this one keeps a
*research program* moving, where most work is never merged and the output is
knowledge. It reuses the collection steward's decision tiers (§4 there) and
its rule that the steward never edits code.

Written from one day of running a research loop by hand on ptc_runner
(issues #1995–#1997, jobs 166 and 167, 2026-09-17/18): the console admitted
the issues, ran the experiments, retained the branches, and produced an
independent review that found a methodological defect. The only human work
was reading the report against a null model, deciding what to run next,
closing a fallback that was no longer needed, and filing the next issue.

Three principles from `PLAN.md` shape every section: a person approves
consequential actions, GitHub is the source of truth, and model output is
validated data, never authority. The consequences for this plan are strict
and worth stating up front:

- The steward has no authority. Authority comes from a maintainer-approved
  **research run** whose actionable content is frozen at approval (§3).
- Verdicts are computed by the console from a commit-bound, machine-readable
  result and the commit-bound method review, never from what the steward
  says (§6.5).
- Nothing merges automatically. Report pull requests go through the normal
  merge decision.
- Labels and issue text are projections. Every research effect resolves
  through a durable experiment record (§3.2).

## 1. Vocabulary

| Term | Meaning |
| --- | --- |
| **Program** | One research question, kept as one document on the target repository's main branch. A GitHub projection with no authority. |
| **Research run** | The maintainer-approved, frozen policy record in the console that authorizes work on one program at one exact document digest and one exact set of pre-approved backlog entries (§3.1). |
| **Run version** | A new approval of the same program after its document or its pre-approved backlog changed. Each version is a fresh consequential approval. |
| **Hypothesis** | A falsifiable sentence with a metric, a null model, and a tolerance. Stable id `H1`, `H2`, … |
| **Backlog entry** | A candidate experiment in the program document, id `<program>/b<nn>`. Only entries frozen into the current run version may be filed without a person. |
| **Experiment** | A durable console record (§3.2) created from a frozen backlog entry, id `<program>/<nnn>`, bound to an issue, a job, a reservation, an artifact PR, and an artifact commit. |
| **Kind** | `measure`, `change`, or `explore` (§5.5). |
| **Artifact commit** | The reviewed commit on the experiment's retained branch, tagged `research/<program>/<nnn>`. Never merged. |
| **Result file** | `docs/research/reports/<program>/<nnn>.json` in the artifact commit: the machine-readable metrics the console computes verdicts from (§5.4). |
| **Report** | `docs/research/reports/<program>/<nnn>-<slug>.md` in the artifact commit; copied to main by a console-derived pull request that the maintainer merges (§5.3). |
| **Ledger** | Console data, one row per finished experiment, projected into the program document by the same derived pull request. |
| **Verdict** | `supports`, `refutes`, `inconclusive`, `invalid`, or `stopped`, computed by the console (§6.5). |

## 2. Repository layout in a target repository

```text
docs/research/README.md                          index of programs
docs/research/<program>.md                       the program document (§4)
docs/research/reports/<program>/<nnn>-<slug>.md  the report, copied from the artifact commit
docs/research/reports/<program>/<nnn>.json       the result file, copied from the artifact commit
scripts/labs/<program>/                          the harness, when the program has one
```

The experiment's branch is retained on the remote and tagged
`research/<program>/<nnn>` at the artifact commit. Tags are never deleted by
automation; a branch may be pruned once its tag exists. Nothing on that
branch merges through the experiment. A harness change a second experiment
needs is an ordinary issue and an ordinary pull request.

## 3. Where authority lives

### 3.1 The research run

`PLAN.md` today permits automatic admission only through repository auto-fix
and through a collection run whose members were frozen at approval. A
research run is a third case of the same shape and needs the same
treatment: **work item 1 amends `PLAN.md`** to define it before anything
else is built. The definition:

A research run is approved by the maintainer for one program and freezes:

| Field | Meaning |
| --- | --- |
| `program`, `document_digest`, `base_sha` | The exact program document version |
| `approved_entries` | The backlog entry ids the console may file as experiments without a further person, with each entry's frozen text |
| `budget_usd` | Lifetime cap for everything the run causes |
| `reservation_table` | Per kind and model, the worst-case reservation the console computes from execution profiles and provider ceilings (§3.3); never a number from a document or a model |
| `filing_limits` | Per pass, per day, and lifetime counts for experiments, ordinary issues, retries, and steward actions |
| `allowed_kinds`, `allowed_models` | Closed lists |
| `expires_at` | After which every trigger is refused |
| `stop_rules` | Copied verbatim from the document at approval |

Anything not in `approved_entries` is not actionable: a backlog entry the
steward proposes, a runtime want, an experiment whose dependencies changed
shape, all wait as pending proposals until the maintainer approves a new
run version that includes them. A new version is a new consequential
approval with its own digest; the previous version's open experiments
finish under the version that created them.

Console-authored changes to the program document (ledger rows, backlog
proposals marked pending) reach GitHub only through the derived pull
request of §5.3 and are not rebinding events. When that pull request
merges, the run's `base_sha` and `document_digest` advance to the merged
values as an explicit **successor binding** recorded on the run, and the
approved entries are unchanged; a change to any approved entry or to a
hypothesis, budget, allowed list, or stop rule is not a successor binding
and refuses every trigger until re-approval.

### 3.2 The experiment record

`research_experiments` is created transactionally from an approved entry
and binds: run id and version, backlog entry id, experiment id, the
reservation, and then as they come into existence the issue id, the job id,
the artifact pull request, the reviewed artifact commit SHA, the tag, the
derived report commit SHA, and the ledger row. The `experiment` label on
the issue and pull request, and the run id in the issue body, are
projections written from this record; the console never resolves an
experiment from a label or a body field. A pull request carrying the label
with no record is an ordinary pull request.

### 3.3 Spend

Every spend-bearing effect reserves its worst case against the run before
it is enqueued, in the same transaction that creates it, from the
`reservation_table`, and is refused when the reservation would exceed the
remaining budget. Actual cost is reconciled from the console's own records
when the work finishes. Provider ceilings (tokens, requests, wall-clock) are
enforced by execution profiles and manifest limits, outside any prompt. A
cost figure in a document, a report, or a steward output is never an input
to reservation or eligibility.

## 4. The program document

Sections, in order: **Question**; **Hypotheses** (id, sentence, metric, null
model, tolerance, state); **Budget and limits** (informational; the run is
authoritative); **Stop rules** (§8); **Ledger** (projection of console
data); **Backlog** (entries `<program>/b<nn>` with kind, hypothesis, what it
settles, priority, `spawned_by` as exactly one experiment id or
`maintainer`, and `after`: backlog ids that should complete first, which is
an ordering preference and is separate from native issue dependencies);
**Pending proposals** (entries the steward proposed and no run version has
approved); **Runtime wants** (each linking the ordinary issue filed for
it, or marked pending).

## 5. The experiment lifecycle

```text
approved entry
  -> experiment record + reservation (§3.2, §3.3)
  -> issue (§5.1), projections written; native dependency links recorded
  -> admission (label + native dependencies; ptc_manager #164)
  -> implementation job in a retained worktree
  -> artifact PR: full branch, projection label, never merged (§5.2)
  -> method review bound to the artifact commit (§7): passed | changes_requested | method_invalid
  -> steward pass (§6) on passed or method_invalid
  -> console computes the verdict (§6.5) and derives the report PR (§5.3)
  -> maintainer merges the report PR through the normal merge decision
  -> console reconciles the merge, tags the artifact commit, closes the artifact PR, records the successor binding
```

### 5.1 The experiment issue

Written by the console from the frozen entry, or by a person in the same
shape. It states program and run ids, hypothesis ids and sentences, kind,
conditions (matrix, seeds, model from `allowed_models`, this experiment's
reservation, early-stop metric, wall-clock cap), the deliverable (report,
result file, and per kind the fixtures, candidate diff, or candidate
entries), prior results by experiment id, and the pull request shape:
title `experiment(<program>): <slug>`, body `Artifact for #<issue>`, never
merged.

### 5.2 The artifact PR

The implementation job works as it does today: it commits its work and
publishes a pull request whose review evidence is bound to that exact
commit. The pull request is never merged. It stays open until the report
pull request has merged and the tag exists (§5.3), so a rejected or stale
report never leaves an artifact closed without a record. The console then
closes it with a comment naming the tag and the report commit, and the
job's worktree is released like any closed-PR job.

### 5.3 The derived report pull request

Publication is a sequence of durable phases, each recorded on the
experiment record, each resumable after a crash, and each re-checking
GitHub before it acts:

1. **Derive.** From the reviewed artifact commit the console extracts
   exactly two blobs, the report and the result file at their fixed paths,
   plus the ledger row it computed (§6.5) rendered into the program
   document, and creates a commit on top of the current default-branch
   head. It persists the derived head SHA, the derivation base SHA, the
   base repository and ref, the blob hashes, and the diff digest.
2. **Publish.** The commit is pushed through the credential-isolated broker
   as a console-authored branch and a pull request is opened for it,
   carrying the projection label.
3. **Merge decision.** The maintainer merges through the normal merge
   contract, which binds head SHA, base, and diff digest exactly as for any
   other pull request. There is no automatic path; the exception a
   collection run records for its frozen members is not extended here.
4. **Reconcile.** After the merge is observed on GitHub, the console
   records the merged commit, tags the artifact commit
   `research/<program>/<nnn>`, closes the artifact pull request, advances
   the run's successor binding, and marks the experiment finished.

A phase that finds GitHub changed underneath it (base moved, pull request
edited, tag exists with a different target) stops and records a pending
decision with the observed values; it never guesses.

### 5.4 The result file and the report

The result file is what verdicts are computed from. It is written by the
harness, not by a model, and its schema is part of the program's harness:

```json
{"experiment": "prelude-search/001", "hypotheses": {"H1": {"metric": "held_out_pass_rate", "observed": 0.9167, "baseline": 0.4333, "k": 4}}, "cost_usd_reported": 0.30}
```

The console evaluates each hypothesis's null model and tolerance, which are
frozen in the run, against these numbers. `cost_usd_reported` is
informational; spend comes from console records.

The report header is fixed so results are searchable with `rg`:

```yaml
program: prelude-search
experiment: prelude-search/001
issue: 1996
tag: research/prelude-search/001
kinds: [measure]
hypotheses: [H1]
model: openrouter:deepseek/deepseek-v4-flash
replay: scripts/labs/prelude-search/fixtures/deepseek-v4-flash/
tags: [sampling, held-out-check, deepseek]
```

The header carries no verdict and no cost; both are ledger columns the
console writes. The body holds conditions, metric tables, the author's
comparison with the null model, verbatim examples, failure modes with
counts, and **runtime wants**.

### 5.5 Kinds

| Kind | May change on the branch | Reaches main | Output |
| --- | --- | --- | --- |
| `measure` | `scripts/labs/<program>/`, fixtures | report and result file | metric table |
| `change` | anything, as a candidate | report and result file; the candidate never merges here | baseline vs candidate table; a pending runtime-want proposal if the change earned one |
| `explore` | nothing outside `docs/research/` | report and result file (with an empty metric map) | candidate backlog entries as pending proposals |

A `change` experiment measures the same harness on main and on the
candidate with the same replay fixtures. If the difference earns the
change, the proposal waits for a run version that approves filing it, and
the ordinary issue then goes through the normal path. Runtime wants become
work the same way.

### 5.6 When an experiment does not finish

An implementation job that stops, fails, times out, or ends with partial
progress keeps its issue **open** and its worktree allocation in
`attention` while a maintainer decision is pending. That is what the
existing recovery paths require: `Operations.resume_from_worktree/2` needs
the retained worktree and an open issue, and so does
`Operations.retry_stopped_job/2`. The console never preserves-and-removes
the worktree before the decision.

| Outcome | Pending decision offered |
| --- | --- |
| `missing_prerequisite` | Drop the experiment (record `stopped`, close, keep the entry with its `after` pointing at whatever the maintainer files) or file the prerequisite yourself and resume later |
| `environment_broken` | Resume from the retained worktree under a fresh reservation, or drop |
| `ambiguous_requirement` | The stop report's two options; resume with the answer, or drop |
| `unsafe_to_proceed` | Drop, or a maintainer-authored plan; no automatic path |
| Job failed or lost with partial progress | Resume from the retained worktree under a fresh reservation, or drop |

Only an explicit drop writes `stopped` and closes the issue. Until then the
experiment counts as open for the idle trigger (§6.1), and `filing_limits`
bounds retries. A decision left pending for longer than the run's
`attention_timeout` is surfaced as a stall by the existing stall detection.

## 6. The steward action

A catalog action, `research_steward`, shaped like `daily_digest` and
`nightly_ci_investigation`: the console builds the prompt and the context,
an ephemeral agent reads and reasons, its output is JSON validated against
`priv/codex/research_steward_output.schema.json`. The output is advice: the
console computes verdicts on its own (§6.5), and every proposal the
steward makes is either already in `approved_entries` or becomes pending.

### 6.1 Triggers, the lock, and pending triggers

- **After a method review reaches `passed` or `method_invalid`** on an
  artifact pull request whose experiment record exists.
- **Idle**: on a schedule, when the run has budget and filing capacity
  left, no open experiment, and at least one approved entry not yet filed.
- **On demand**: a console button on the program.

Every trigger is persisted in a pending-trigger table with a unique
identity (review round id, schedule slot, button press). A pass takes a
durable per-program lock; a trigger that finds the lock held stays pending
and is processed by the next pass. Schedule triggers coalesce; review
triggers never do. A reconciliation pass also scans for experiments whose
review reached a terminal disposition without a completed steward pass and
re-queues them, so a race cannot strand an artifact.

A pass binds itself to the run version, the default-branch SHA, the
document digest, the artifact commit SHA (if any), the open-experiment
snapshot, and the reservation version. Every effect re-fetches its GitHub
target immediately before acting and applies only if those bindings still
hold, except for changes the console itself made in an earlier phase,
which are recorded as successor bindings and are not drift.

### 6.2 Inputs

The program document at the bound digest, every report header under the
program, the triggering report and result file from the artifact commit,
the method-review findings for that commit and their disposition, the
ledger, the backlog with each entry's approval state, the open-experiment
snapshot, and the run's spend and remaining budget from console records.

### 6.3 The checklist the prompt carries

1. Compare each result with the hypothesis's null model. State the
   predicted and observed values side by side and explain them.
2. Was the check inside the runtime and captured in its artifacts, or
   computed beside it?
3. Does the scorer measure the stated metric in both directions?
4. Does replay reproduce the table, including cost and failure categories?
5. Was the budget enforced before each spend, or checked afterwards?
6. Which runtime wants are new, and which were predicted.
7. Which backlog entries this result makes more or less valuable, which new
   ones it spawns, and why. A failed or invalid experiment spawns "why"
   entries; a successful one spawns the next question.
8. Which stop rule, if any, the numbers appear to fire.

Items 2 to 5 duplicate the method reviewer's questions on purpose: the
reviewer's findings are commit-bound evidence, the steward's are
annotations. When they disagree, the disagreement is a question for the
maintainer, not a verdict.

### 6.4 Output schema (sketch)

No tier, no filing instruction, no merge instruction, no cost the console
would use, no verdict the console would record. Ids must resolve to
existing hypotheses, ledger rows, or backlog entries, or be new backlog ids
in the program's namespace.

```json
{
  "program": "prelude-search",
  "triggered_by": "prelude-search/001",
  "readings": [{"hypothesis": "H1", "predicted": "89.7%", "observed": "91.7%", "explanation": "..."}],
  "method_annotations": [{"severity": "medium", "finding": "..."}],
  "result_line": "K=4 91.7% equals the sampling prediction; selection ran outside the runtime",
  "backlog_proposals": [
    {"op": "add", "entry": {"id": "prelude-search/b08", "kind": "measure", "hypothesis": "H1", "settles": "...", "priority": 1, "spawned_by": "prelude-search/001", "after": []}},
    {"op": "reprioritise", "id": "prelude-search/b03", "priority": 3, "why": "..."},
    {"op": "drop", "id": "prelude-search/b05", "why": "..."}
  ],
  "runtime_wants": [{"finding": "...", "predicted": false, "reproduction": "..."}],
  "next_candidates": [{"backlog_id": "prelude-search/b01", "why_now": "..."}],
  "stop_reading": {"program": false, "hypotheses": [], "reason": ""},
  "questions": [{"question": "...", "options": [{"label": "...", "consequence": "..."}], "recommended": 0}]
}
```

### 6.5 What the console does with it

| Effect | Rule | Tier |
| --- | --- | --- |
| Verdict and ledger row | Computed by the console, once, keyed by experiment id: `invalid` if the method review's disposition is `method_invalid`; `stopped` for a §5.6 drop; otherwise each hypothesis in the result file is evaluated against its frozen null model and tolerance, giving `supports`, `refutes`, or `inconclusive` (observed inside the tolerance band of the null prediction, or a result file that lacks the hypothesis's metric). Cost from console records. The steward's `result_line` is stored as the row's annotation | console |
| Backlog proposals and runtime wants | Recorded as **pending proposals** in the program document's pending section, never as approved entries; the duplicate check (hypothesis id plus condition hash against ledger rows and existing entries) refuses exact repeats | 1 (a projection; approval is tier 3) |
| Report pull request | Derived and published per §5.3, with the ledger row and any pending proposals rendered into the program document | 1 to open; the merge is the maintainer's |
| Next experiment | Filed only from an entry in `approved_entries` that has no experiment record yet, whose `after` entries are finished, within `filing_limits` and `filing_depth`, with a reservation that fits from the `reservation_table`, and whose kind and model are allowed. The steward's `next_candidates` may reorder among such entries; the console's deterministic ranking (§6.6) is recorded beside it | 2 |
| Anything else: a proposal, a runtime want, `stop_reading`, a disagreement between review and steward, any `questions` | A pending maintainer decision through the existing decision UI, with the two options and the console's reason for refusing an automatic path | 3 |
| Program stop | Only by the maintainer's decision, or by a frozen stop rule the console evaluates itself (§8) | 3 or console |

### 6.6 Ranking approved entries when idle

Deterministic: entries whose hypothesis is `open` first, then lower
reservation, then replay-only before model-spending, then entries spawned
by a failed or invalid experiment before those spawned by a successful one,
then priority, then id. The steward's reordering within that set and its
`why_now` are recorded next to the console's order.

## 7. Method review and the `method_invalid` disposition

An experiment's pull request is reviewed by the existing independent
review with an additional instruction, selected because the experiment
record exists (never because of the label): review the method against the
hypotheses named in the issue, and report items 2 to 5 of §6.3 as findings
with severities. Review evidence stays bound to the artifact commit.

Today a medium or high finding leaves a job in `changes_requested`. For an
experiment that is the wrong terminal state: the invalid method *is* the
result. The console therefore derives a third commit-bound disposition,
**`method_invalid`**, deterministically from validated blocking method
findings on an experiment's pull request. It is not a clean review, it
authorizes no merge of the artifact (nothing ever merges the artifact), and
it triggers the steward pass and the publication of the report with the
verdict `invalid`. Style or correctness findings that are not method
findings keep today's behaviour.

The reviewer's changed-path cap is unchanged. An artifact pull request
that exceeds it is a maintainer question, as it was for job 167, and the
experiment issue asks for fixtures consolidated to one file per condition.

## 8. Stop rules

Frozen into the run and evaluated by the console after every ledger write.

- **Answered.** Every hypothesis is `supported`, `refuted`, or `dropped`.
- **Flat.** Two consecutive non-`invalid` experiments on one hypothesis
  move its metric by less than the tolerance: `dropped` with that reason.
- **Budget.** Remaining budget is below the smallest reservation in the
  table: `stopped` pending a decision.
- **Invalid twice.** Two consecutive `invalid` verdicts on the same
  harness: the harness needs an ordinary issue first.
- **Runtime first.** A hypothesis whose next approved entry depends on a
  runtime change waits on that ordinary issue.
- **Expiry.** `expires_at` passed: every trigger refused until renewed.

Experiment-level: the early-stop metric in the issue, the reservation
enforced before each spend inside the harness, and the wall-clock cap
enforced by the operation wrapper.

## 9. What changes where

**ptc_manager**

1. `PLAN.md`: define the research run as the third automatic-admission
   case, with its frozen content and its limits (§3.1).
2. `research_runs` and `research_experiments`: schemas, approval, freezing,
   versioning, successor bindings, reservation and reconciliation,
   `filing_limits` counters, projections.
3. Method review for experiments: the instruction (§7) and the
   `method_invalid` disposition derived from blocking method findings.
4. Research publication (§5.2, §5.3): artifact pull requests never merge,
   the four durable phases, broker push of a console-authored branch,
   tagging, closing with a comment.
5. `research_steward` action: context builder, output schema, pending
   triggers, lock and bindings, verdict computation, ledger and pending
   proposals, deterministic ranking.
6. Filing of approved entries (tier 2). Depends on ptc_manager #164.
7. Console surface: program card with hypotheses, ledger, backlog with
   approval state, pending proposals, spend and reservations, pending
   decisions, approve-run and on-demand buttons.

**Target repositories (ptc_runner first)**

1. `docs/research/` layout, the program document, the report header, the
   result file, and the experiment issue shape in `AGENTS.md`.

## 10. Work items, in order

1. Target-repository format (§2, §4, §5.4) with the prelude-search program
   written into ptc_runner. No console change.
2. `PLAN.md` amendment and the two records with approval and reservation
   (§3). Nothing can spend under a program without them.
3. Method review instruction and `method_invalid` (§7). Small, independent
   of item 2, and it fixes the state job 167 is in today.
4. Research publication (§5.2, §5.3).
5. `research_steward` on demand: readings, pending proposals, questions, and
   the console's verdict computation. No filing.
6. Filing of approved entries and the after-review and idle triggers.
7. Program card.

Items 1 to 5 let the next prelude-search experiment run under an approved
run with the steward reading the result. Item 6 removes the person from the
loop between experiments that were approved together.

## 11. Worked example: the prelude-search program

Question: does bounded search over model-written candidates, selected by a
check against recorded executions, produce repairs that hold on unseen
executions at a cost single-shot repair cannot match?

| id | hypothesis | metric | null model | tolerance | state |
| --- | --- | --- | --- | --- | --- |
| H0 | A recorded run re-executes byte-equal from its frozen bundle and input | fraction equal | none; the claim is exactly 1 | 0 | open until migrated |
| H1 | K parallel candidates with a held-out check beat single-shot at equal per-candidate budget | held-out pass rate | independent sampling: 1 − (1 − p₁)ᴷ | ±3 points | open |
| H2 | Feedback from a failed check beats more width at equal tokens | held-out pass rate per dollar | H1's K=4 result at equal spend | ±3 points | open |
| H3 | A helper the model wrote on one subject lowers cost on an unseen subject | cost per solved instance | the same run without the helper | ±10% | open |

**Pending migration**, not ledger rows until the console tags them and a
result file exists:

- `prelude-search/000`, issue #1995, merged as `ccc81520a` (the harness
  itself): 300 of 300 re-executions equal, about 5 ms each. Needs a result
  file and the tag `research/prelude-search/000`.
- `prelude-search/001`, issue #1996, branch `ptc-manager/issue-1996-job-167`
  at `e4b36ab4e`: method review found blocking method defects, so its
  disposition would be `method_invalid` and its verdict `invalid`. Needs
  the tag `research/prelude-search/001`; its report is copied to main by
  hand in ptc_runner PR #1999 with that caveat stated.

Backlog, with `after` as an ordering preference:

| id | kind | hypothesis | settles | priority | spawned_by | after |
| --- | --- | --- | --- | --- | --- | --- |
| prelude-search/b01 | measure | H1 | corrective rerun of 001: check inside a no-model mission driven by workflow code and captured in the run's artifacts; scorer accepting qualified names, scoring all candidates, requiring citations; fixtures with usage and error responses; reservation enforced per case; E1 at three turns as an added row | 1 | prelude-search/001 | |
| prelude-search/b02 | measure | H2 | feedback depth 3 versus K=4 at equal tokens | 2 | prelude-search/001 | b01 |
| prelude-search/b03 | measure | H1 | soft evidence and no-bug cases: false-repair rate with and without an authority field | 3 | maintainer | b01 |
| prelude-search/b04 | measure | H3 | kept helper on an unseen subject | 4 | maintainer | b02 |
| prelude-search/b05 | change | H0 | record the run input as a private inspection record; E0 from artifacts alone | 2 | prelude-search/001 | |
| prelude-search/b06 | change | H1 | render `data/params` as its value to the model; prompt tokens and pass rate on b01's fixtures | 3 | prelude-search/001 | b01 |
| prelude-search/b07 | explore | H2 | which evidence-graph representation a feedback loop would need from the debugger prelude | 5 | maintainer | |

A first run version would approve `b01` alone, or `b01` and `b05`, and
nothing else; `b02` is filed only under a later version once `b01` has a
ledger row.

Runtime wants from `prelude-search/001`, pending proposals until a run
version approves filing them: mission params recorded by hash only; no
mission return record; `data/params` rendered as a type; `kernel/eval-source-with`
cannot take a complete component; replay cursors are run-scoped; provider
errors have no replayable response.

## 12. Other programs this shape supports

Named only to show the shape is not specific to prelude search.

- **Agent-loop policy** (`change` on `agent.core`): consolidation threshold
  or turn budget against pass rate per dollar on the prelude-search
  fixtures. Replay only.
- **Kernel cost** (`measure` then `change`): where per-run milliseconds go
  under a serving load, the shape of ptc_runner #1988 as a program.
- **Debug-navigation evidence** (`explore` then `measure`): which
  relationship a model-written debugger follows first, and whether a
  different frozen-graph vocabulary shortens diagnoses.
- **Model choice** (`measure`): the same harness under a second model, filed
  only when a verdict depends on it, the rule that closed ptc_runner #1997.

## 13. Non-goals

- The steward does not edit code, run experiments, merge anything, compute
  verdicts, or hold authority. Implementation jobs run experiments; the
  research run holds the budget and the approved entries; the console
  computes verdicts; the maintainer merges every pull request and approves
  every new entry.
- No cross-repository programs.
- No automatic budget increases, run renewals, or automatic merges.
- Replacing the method review with the steward's reading. The review is
  commit-bound evidence; the steward's pass is annotation and proposal.
