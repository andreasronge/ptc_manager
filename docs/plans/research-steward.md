# Plan: the research steward

Status: draft, 2026-09-18. Not implemented. Companion to
[`collection-steward.md`](collection-steward.md): that plan keeps a
collection of *deliverables* moving; this one keeps a *research program*
moving, where most work is never merged and the output is knowledge. It reuses
the collection steward's decision tiers (§4 there) and its rule that the
steward never edits code.

Written from one day of running a research loop by hand on ptc_runner
(issues #1995–#1997, jobs 166 and 167, 2026-09-17/18): the console admitted
the issues, ran the experiments, retained the branches, and produced an
independent review that found a methodological defect. The only human work
was reading the report against a null model, deciding what to run next,
closing a fallback that was no longer needed, and filing the next issue.
That work is the steward.

## 1. Vocabulary

| Term | Meaning |
| --- | --- |
| **Program** | One research question with a budget and stop rules, kept as one document on the target repository's main branch. |
| **Hypothesis** | A falsifiable sentence inside a program, with a metric, a null model, and a tolerance. Has a stable id (`H1`, `H2`, …). |
| **Experiment** | One issue that tests one or more hypotheses under stated conditions and ends in a report. Has a stable id (`<program>/<n>`). |
| **Kind** | `measure` (run a harness), `change` (alter the runtime or a shipped prelude and measure it against a baseline), or `explore` (read code, traces, or literature and produce candidates, no measurement). |
| **Report** | A small markdown file with a fixed header, merged to main. The branch that produced it is retained and not merged. |
| **Ledger** | The table in the program document with one row per finished experiment. |
| **Backlog** | The list in the program document of experiments not yet filed, each with a priority and what it would settle. |
| **Verdict** | One of `supports`, `refutes`, `inconclusive`, `invalid` (method defect), `stopped` (budget or cap). |

## 2. Repository layout in a target repository

Everything a program owns lives under `docs/research/` in the repository the
research is about, so it is versioned, reviewable, and searchable with the
tools every agent already has.

```text
docs/research/README.md                     index of programs, one line each
docs/research/<program>.md                  the program document (§3)
docs/research/reports/<program>/<nnn>-<slug>.md   one report per experiment (§4)
scripts/labs/<program>/                     the harness, when the program has one
```

Branch convention: an experiment's work is committed on the job's branch as
today. When the report merges, the branch is **retained on the remote**, never
deleted, and the report header names it. The report and the ledger row are
the only things that merge by default. Harness changes merge only when a
second experiment needs them, and runtime or prelude changes never merge
through a research issue at all (§6).

This keeps main free of one-off fixtures, keeps every result one `rg` away,
and keeps every branch reproducible from its own commit.

## 3. The program document

Sections, in order. Each is short; the ledger and backlog grow.

1. **Question.** One sentence.
2. **Hypotheses.** A table: id, sentence, metric, null model, tolerance,
   state (`open`, `supported`, `refuted`, `dropped`).
3. **Budget.** Money per program, money per experiment, and the steward's
   filing depth (how many experiments it may file without a person, default
   three).
4. **Stop rules.** Program-level and hypothesis-level (§8).
5. **Ledger.** One row per finished experiment: id, issue, branch, kinds,
   hypotheses touched, verdict, cost, one-line result, report path.
6. **Backlog.** One entry per candidate experiment: id, kind, hypothesis,
   what it would settle, rough cost, priority, `spawned_by` (an experiment id
   or `maintainer`), dependencies.
7. **Runtime wants.** Findings that need a runtime or prelude change. Each
   line links the ordinary issue that was filed for it.

The first program document is the prelude-search plan rewritten into this
shape, with job 167's result as ledger row 1 (§11).

## 4. The report

A report starts with a fixed header so agents can search results without
parsing prose:

```yaml
program: prelude-search
experiment: prelude-search/001
issue: 1996
branch: ptc-manager/issue-1996-job-167
kinds: [measure]
hypotheses: [H1, H2]
verdict: supports
cost_usd: 0.30
model: openrouter:deepseek/deepseek-v4-flash
replay: scripts/labs/prelude-search/fixtures/deepseek-v4-flash/
tags: [sampling, held-out-check, deepseek]
```

Then the body the experiment issue asked for: conditions, metric tables, the
stop-rule verdict against the null model, verbatim examples, failure modes
with counts, and **runtime wants**. A report of kind `explore` has no metric
table; it has candidates for the backlog with the evidence for each.

Searching existing results is then `rg` over `docs/research/reports/` by
program, hypothesis, tag, or verdict, plus the ledger. The steward is
required to read the ledger and cite prior experiment ids before proposing
anything, and a deterministic check refuses a backlog entry whose hypothesis
and condition hash already have a ledger row unless the entry says what is
different.

## 5. The experiment lifecycle

```text
backlog entry
  -> issue (template §5.1), labelled ptc:ready and experiment
  -> admission (label + native dependencies; ptc_manager #164)
  -> implementation job in a retained worktree
  -> method review (§7)
  -> report PR: report file + ledger row only
  -> merge (tier 1 when review passed and diff is only those files)
  -> steward pass (§6): verdict, backlog updates, next issues or stop
```

### 5.1 The experiment issue template

The steward files issues in this shape, and a person filing one by hand
should too. Everything an agent needs is in the body; the program document
is linked for context, never required.

- **Program and hypotheses.** Ids and the sentences.
- **Kind.** `measure`, `change`, or `explore`.
- **Conditions.** The matrix, seeds, models, budget for this experiment, and
  the stop rule for this experiment.
- **Deliverable.** The report path and header, the ledger row, and for
  `measure` the replay fixtures on the branch. For `change`, the candidate
  diff on the branch and the baseline-versus-candidate table (§6). For
  `explore`, the candidate backlog entries with evidence.
- **Prior results.** Ledger rows this experiment builds on, by id.
- **Pull request.** Title `experiment(<program>): <slug>`, label
  `experiment`, body `Report for #<issue>`. Only the report and ledger row
  are in the diff. Fixtures and harness changes stay on the branch; a
  harness change that must merge is a separate ordinary PR.

### 5.2 Kinds and what each may touch

| Kind | May change on the branch | Merges | Typical output |
| --- | --- | --- | --- |
| `measure` | `scripts/labs/<program>/`, fixtures | report, ledger row | metric table, verdict |
| `change` | anything, as a candidate | report, ledger row; the candidate diff is **not** merged here | baseline vs candidate table, a linked ordinary issue if the change earned one |
| `explore` | nothing outside `docs/research/` | report, ledger row, backlog entries | candidates with evidence, questions for the maintainer |

A `change` experiment is how the program reaches into the runtime or the
core preludes without a research branch ever becoming the delivery vehicle.
It measures the same harness on main and on the candidate, using the same
replay fixtures so the model is constant, and reports the difference. If the
difference earns the change, the report links an ordinary issue with the
reproduction and the diff, filed through the existing issue-creation action,
and that issue goes through the normal implementation and review path. This
is also how an experiment's **runtime wants** become work: never as a
research PR, always as an ordinary issue the ledger points at.

## 6. The steward action

Not a new agent kind. A catalog action, `research_steward`, shaped like
`daily_digest` and `nightly_ci_investigation`: the console builds the prompt
and the context, an ephemeral agent reads and reasons, its output is JSON
validated against `priv/codex/research_steward_output.schema.json`, and
deterministic code applies the effects. The agent never writes GitHub or the
repository itself.

### 6.1 Triggers

- **After a report merges** for a program: the pass reads that report.
- **Idle**: on a schedule, when a program has budget left, no open
  experiment issue, and a non-empty backlog. This is "when there is time".
- **On demand**: a console button on the program, for the maintainer.

Never while an experiment issue of the same program is open, so two passes
cannot file competing next steps.

### 6.2 Inputs

The program document, every report header under the program, the full text
of the report that triggered the pass, the ledger, the backlog, the
repository's open issues carrying the `experiment` label, and the program's
spend so far from the console's own job and action records.

### 6.3 The checklist the prompt carries

This is what the maintainer's agent did by hand on 2026-09-18, made
explicit:

1. Compare each result with the hypothesis's null model. State the predicted
   value and the observed value side by side.
2. Was the check inside the runtime and captured in its artifacts, or
   computed beside it?
3. Does the scorer measure the stated metric in both directions?
4. Does replay reproduce the table, including cost and failure categories?
5. Cost against the cap, and how the cap was enforced.
6. Which runtime wants are new, and which were predicted.
7. Which backlog entries this result makes more or less valuable, and which
   new ones it spawns. A **failed** experiment spawns "why" entries; a
   **successful** one spawns the next question. Both are backlog entries with
   `spawned_by` set, never issues yet.
8. Which stop rule, if any, fires.

### 6.4 Output schema (sketch)

```json
{
  "program": "prelude-search",
  "triggered_by": "prelude-search/001",
  "verdicts": [{"hypothesis": "H1", "verdict": "supports", "predicted": "89.7%", "observed": "91.7%", "note": "..."}],
  "method_findings": [{"severity": "medium", "finding": "held-out selection ran outside the runtime"}],
  "ledger_row": {"experiment": "prelude-search/001", "verdict": "supports", "cost_usd": 0.30, "result": "..."},
  "backlog_updates": [
    {"op": "add", "entry": {"id": "prelude-search/b07", "kind": "measure", "hypothesis": "H1", "settles": "...", "cost_usd": 0.5, "priority": 1, "spawned_by": "prelude-search/001", "depends_on": []}},
    {"op": "reprioritise", "id": "prelude-search/b03", "priority": 3, "why": "..."},
    {"op": "drop", "id": "prelude-search/b05", "why": "answered by 001"}
  ],
  "runtime_wants": [{"finding": "...", "predicted": false, "file_issue": true, "reproduction": "..."}],
  "next": [{"backlog_id": "prelude-search/b07", "tier": 2, "why_now": "..."}],
  "stop": {"program": false, "hypotheses": ["H2"], "reason": "..."},
  "questions": [{"question": "...", "options": [{"label": "...", "consequence": "..."}], "recommended": 0}]
}
```

### 6.5 Effects, all deterministic

| Output | Effect | Tier |
| --- | --- | --- |
| `ledger_row`, `backlog_updates`, `verdicts` | One PR to the program document, merged by the console when it touches only that file | 1 |
| `runtime_wants` with `file_issue` | An ordinary issue through the existing issue-creation action, linked from the program's runtime-wants section | 2 |
| `next` within budget and depth | Experiment issues from the template, native dependency links recorded, `ptc:ready` | 2 |
| `next` beyond depth, or any `change` experiment whose candidate touches a public contract | Filed with `ptc:needs-decision` and the question | 3 |
| `stop.program` | The program document's status becomes `stopped` with the reason; no further passes | 3, as a two-option question: accept or extend budget |
| `questions` | Surfaced through the existing decision UI | 3 |

Depth: the steward may file at most the program's filing depth of
experiments in a row without a merged human decision. A pass that would
exceed it files nothing and asks.

### 6.6 Selecting from the backlog when idle

Priority is not a number the agent invents; it is argued from three things
the prompt asks for explicitly: how much the entry would move an open
hypothesis's state, its cost, and whether it can run as replay only (no
model spend). Ties go to the cheaper entry. An entry spawned by a failed
experiment outranks one spawned by a successful one at equal priority,
because an unexplained failure poisons every later result.

## 7. Method review

The `experiment` label selects a review instruction that says: review the
method against the hypotheses in the issue, not the code style. Concretely,
the reviewer answers checklist items 2 to 5 of §6.3 and reports each as a
finding. Job 167's review already did this without being asked and found
that held-out selection ran outside the runtime; the plan only makes it the
rule. The reviewer's changed-path cap needs no change once fixtures stay on
the branch and the PR carries only the report.

## 8. Stop rules

Program-level, written into every program document:

- **Answered.** Every hypothesis is `supported`, `refuted`, or `dropped`.
- **Flat.** Two consecutive experiments on one hypothesis move its metric by
  less than the tolerance: the hypothesis is `dropped` with that reason.
- **Budget.** Program spend reaches the cap: `stopped`, question to the
  maintainer.
- **Invalid twice.** Two consecutive `invalid` verdicts on the same harness:
  the harness needs an ordinary issue before research continues.
- **Runtime first.** A hypothesis whose next experiment needs a runtime
  change waits on that ordinary issue; it is not `dropped`.

Experiment-level, written into every issue: the metric threshold that ends
the run early, the budget, and the maximum wall-clock.

## 9. What changes where

**ptc_manager**

1. `research_steward` automation definition and catalog action, with the
   context builder for §6.2 and the output schema of §6.4.
2. Effects of §6.5 on top of existing actions: program-document PR,
   issue creation, native dependency links, `ptc:needs-decision` filing, and
   the stop transition.
3. Triggers of §6.1, including the idle schedule and the "no open experiment"
   guard.
4. `experiment` label: review instruction selection (§7) and PR diff guard
   (report and ledger only, else the PR is a `needs-decision`).
5. Console surface: a program card listing hypotheses, ledger, backlog, spend,
   last pass, with the on-demand trigger.

**Target repositories (ptc_runner first)**

1. `docs/research/` layout (§2), the first program document (§11), and the
   report header contract (§4) in `AGENTS.md`.
2. The experiment issue template (§5.1) in `AGENTS.md`, replacing the
   ad-hoc conventions used for #1995–#1997.

## 10. Work items, in order

1. Program document format and report header: write them into ptc_runner
   with the prelude-search program migrated (§11). No console change. Value:
   results become searchable and the null-model comparison is written down.
2. `experiment` label and method-review instruction (§7), plus the PR diff
   guard. Small console change; removes the changed-path failure and makes
   every experiment review a method review.
3. `research_steward` as an **on-demand** action only (§6.1 third trigger),
   with ledger and backlog effects (tier 1) and questions (tier 3). No
   automatic filing yet. This is where the checklist and schema get
   exercised by a person reading its output.
4. Filing effects (tier 2): next experiments and runtime-want issues, with
   depth and budget caps. Depends on ptc_manager #164 for dependency-ordered
   admission.
5. Triggers after merge and when idle.
6. Program card in the console.

Items 1 to 3 are enough to run the next prelude-search experiment with the
steward reading the result. Items 4 and 5 are what removes the person from
the loop between experiments.

## 11. Worked example: the prelude-search program

Question: does bounded search over model-written candidates, selected by a
check against recorded executions, produce repairs that hold on unseen
executions at a cost single-shot repair cannot match?

| id | hypothesis | metric | null model | tolerance | state |
| --- | --- | --- | --- | --- | --- |
| H0 | A recorded run re-executes byte-equal from its artifacts | fraction equal | n/a | 100% | supported (job 166: 300/300) |
| H1 | K parallel candidates with a held-out check beat single-shot at equal per-candidate budget | held-out pass rate | independent sampling: 1 − (1 − p₁)ᴷ | ±3 points | supported, but equals the null model (job 167: 91.7% vs 89.7% predicted) |
| H2 | Feedback from a failed check beats more width at equal tokens | held-out pass rate per dollar | H1's K=4 result | ±3 points | open |
| H3 | A helper the model wrote on one subject lowers cost on an unseen subject | cost per solved instance | no helper | ±10% | open |

Ledger row 1: `prelude-search/001`, issue #1996, branch
`ptc-manager/issue-1996-job-167`, kinds `[measure]`, H1, verdict `supports`,
USD 0.30, "K=4 91.7% ≈ sampling prediction 89.7%; E1 handicapped at one
turn; scorer rejects qualified names; 180 fixture files".

Backlog after the pass:

| id | kind | hypothesis | settles | cost | priority | spawned_by |
| --- | --- | --- | --- | --- | --- | --- |
| b01 | measure | H1 | honest baseline: E1 at three turns, scorer accepts qualified names and checks citations, one fixture file per condition | USD 1 | 1 | 001 (invalid parts) |
| b02 | measure | H2 | feedback depth 3 versus K=4 at equal tokens | USD 2 | 2 | 001 |
| b03 | measure | H1 | soft evidence and no-bug cases: does the false-repair rate fall with an authority field | USD 2 | 3 | maintainer |
| b04 | measure | H3 | kept helper on an unseen subject | USD 2 | 4 | maintainer |
| b05 | change | H0 | record the run input as a private inspection record; measure that E0 runs from artifacts alone | USD 0 (replay) | 2 | 001 (runtime wants) |
| b06 | change | H1 | render `data/params` as its value to the model; measure prompt tokens and pass rate on b01's fixtures | USD 0 (replay) | 3 | 001 (runtime wants) |
| b07 | explore | H2 | which evidence-graph representation the debugger prelude would need for a feedback loop | USD 0 | 5 | maintainer |

Runtime wants from 001, each an ordinary issue when filed: mission params
recorded by hash only; no mission return record; `data/params` rendered as a
type; `kernel/eval-source-with` cannot take a complete component; replay
cursors are run-scoped; provider errors have no replayable response.

## 12. Other programs this shape supports

Named here only to show the shape is not specific to prelude search; none is
proposed.

- **Agent-loop policy** (`change` on `agent.core`): does a different
  consolidation threshold or turn budget change pass rate per dollar on the
  prelude-search fixtures? Replay only, zero model spend.
- **Kernel cost** (`measure` then `change`): where the per-run milliseconds
  go under a serving load, and whether a candidate change moves them, the
  shape of ptc_runner #1988 as a program instead of an issue.
- **Debug-navigation evidence** (`explore` then `measure`): which
  relationship a model-written debugger follows first, and whether a
  different frozen-graph vocabulary shortens diagnoses on the captured
  failures.
- **Model choice** (`measure`): the same harness and fixtures under a second
  model, filed only when a hypothesis's verdict depends on it, which is the
  rule that closed ptc_runner #1997.

## 13. Non-goals

- The steward does not edit code, run experiments, or merge anything but
  the program document. Implementation jobs run experiments; the maintainer
  merges runtime changes.
- No cross-repository programs. A program lives in one repository.
- No automatic budget increases. Reaching the cap is always a question.
- Replacing the method review with the steward's own reading. Both run; the
  review is evidence for the exact commit, the steward's pass is judgement
  over the program.
