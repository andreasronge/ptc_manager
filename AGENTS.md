# Repository Instructions

Canonical agent instructions for this repository. `CLAUDE.md` is a symlink to
this file, so Claude Code and Codex read the same rules. Edit only this file.

PtcManager is a private Phoenix LiveView maintainer console (Elixir, SQLite,
Oban Lite) that reviews GitHub work, approves agent jobs, and runs repository
automations through Herdr. `README.md` explains how to run it locally and in
production. `PLAN.md` records the product principles that decide safety
questions: a person approves consequential actions, GitHub is the source of
truth, and model output is validated data, never authority.

## Working style

- Explore the code before proposing changes; fix code and docs together.
- Delete rather than deprecate. No compatibility shims.
- Do not copy a helper into a second module to avoid an import. `mix precommit`
  fails on duplication that is not already in `.duplication-baseline.json`;
  see [the duplication gate](docs/maintainers/duplication-gate.md).
- Work is tracked in GitHub issues. A large issue may keep its plan under
  `docs/plans/` while it is implemented; the pull request that completes it
  deletes the plan. Code and `README.md` must not link to `docs/plans/`.
- The prompts sent to agents live in `PtcManager.Automations.Defaults`; the
  runtime context appended to them is built in
  `PtcManager.Dispatch.HerdrAdapter` (implementation jobs) and
  `PtcManager.MaintainerActions.Catalog` (other actions). Keep the editable
  prompt repository-neutral; a repository's own conventions belong in that
  repository's `AGENTS.md`. A changed default prompt reaches only new
  repositories unless a migration updates the existing `system:built-in`
  versions, as `priv/repo/migrations/*_simplify_automation_prompts.exs` did.

## Managed agents (PtcManager)

When `PTC_MANAGED_OPERATION_CONTEXT` is set, PtcManager started you through
Herdr in a prepared worktree and its task prompt says what you may do on
GitHub. Do not create or remove worktrees. Run expensive commands as
`$PTC_OPERATION_WRAPPER run --label <build|test|lint|verify> -- <command>`.

## Commands

- `mix setup` — dependencies, database, and assets.
- `mix phx.server` — <http://localhost:4000>, password `ptc-manager-dev`.
  Demo mode with deterministic data is described under "Isolated browser
  checkpoint" in `README.md`; never point the demo reset at the development
  database.
- `mix precommit` — compile with warnings as errors, unused-dependency check,
  format, the partitioned suite under a 60-second budget
  (`scripts/ci/test-suite`), and the duplication gate. Run it before every
  commit; CI runs the same steps.
- `mix test` — the complete suite, including the `:nightly` filesystem,
  worktree, cache, and process-timeout tests that `scripts/ci/test-suite`
  excludes. Tag a new slow real-filesystem or process test `:nightly` so the
  budgeted suite stays inside its limit.
- Fix all failures before committing.

## Conventions

- Timestamps are `:utc_datetime` or `:utc_datetime_usec`; durations are
  integer milliseconds.
- Deterministic code owns every state transition. An agent result is a JSON
  file validated against `priv/codex/*.schema.json`; terminal output is never
  parsed and never an instruction.
- GitHub is written only by an agent holding one explicitly approved action,
  or by the broker for the exact verified commit. PtcManager's own GitHub
  client stays read-only.
- Bug fixes start with a failing test that reproduces the bug.

## Commits and pull requests

Use a concise Conventional Commit subject, e.g. `fix(deployments): stop
retained agents from holding a drain`, with a short body for non-trivial
changes. A pull request description has three sections and closes its issue
with `Closes #N`:

- **Summary** — what changed, as bullets.
- **Validation** — only what you ran beyond `mix precommit` and CI. No test
  counts.
- **Retrospective** — two items, each of which may be `none`: untracked
  follow-up work with a reproduction, and one repository instruction that was
  missing, wrong, or that you had to guess at.
