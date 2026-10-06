# Configurable branch prefixes for implementation jobs

## Problem

Every implementation job pushes `ptc-manager/issue-<n>-job-<id>`. Some
repositories enforce a branch-name ruleset, e.g. names must start with
`feature/`, `bugfix/`, `hotfix/` or `release/`. PtcManager cannot deliver to
such a repository: the broker's push, or the agent's own push under
`publication_source: "agent"`, is rejected by GitHub.

The prefix should also say what kind of change the branch carries, so a bug
fix lands on `bugfix/…` and a feature on `feature/…`.

## Decision

- Each repository configures a **default prefix** and an optional list of
  **label → prefix mappings**. Only labels in that list affect the prefix;
  every other label is ignored.
- The prefix is **resolved at approval**. A maintainer approving in the console
  sees the resolved prefix and may pick any other configured one. Automatic and
  collection approvals use the resolved prefix, and fall back to the default
  prefix when labels conflict.
- The chosen prefix is **frozen on the job** (`jobs.branch_prefix`), like
  `base_branch`. The branch is `<branch_prefix>issue-<n>-job-<id>`, built at
  lease as today. Changing the repository's configuration later does not move
  a job that was already approved.
- Every check that today hard-codes `ptc-manager/` builds the expected name
  from the job's frozen prefix instead. The broker keeps refusing any branch
  other than the exact expected one.

The default for every existing and new repository is `ptc-manager/` with no
mappings, so nothing changes until a maintainer configures it.

## Configuration shape

New column `repositories.branch_prefixes` (`:map`), validated by a new
`PtcManager.Repository.BranchPrefixes` module modelled on
`PtcManager.Repository.IntegrationBranches`:

```elixir
%{
  "default" => "ptc-manager/",
  "mappings" => [
    %{"label" => "bug", "prefix" => "bugfix/"},
    %{"label" => "enhancement", "prefix" => "feature/"}
  ]
}
```

The choices a maintainer can pick at approval are the default prefix plus the
mapped prefixes, without duplicates. There is no separate allowed list, so
`release/` cannot be chosen unless a maintainer deliberately maps it.

### Prefix format

`BranchPrefixes.valid_prefix?/1` accepts a prefix only when:

- it is 1–3 path segments, each matching `[A-Za-z0-9][A-Za-z0-9._-]*`,
  followed by `/` (so `bugfix/` and `team/bugfix/` are valid, `bugfix` and
  `bugfix-` are not);
- it is at most 64 bytes;
- no segment ends in `.` or `.lock`, and none contains `..`;
- the first segment is not `refs`, `origin`, `HEAD` or `remotes` (any case),
  because those names make refs ambiguous to git;
- `prefix <> "issue-1-job-1"` passes `PtcManager.GitHub.Ref.safe?/1`.

Requiring a trailing `/` keeps `issue-<n>-job-<id>` as its own path segment,
so every exact-match check stays straightforward.

### Mapping rules

These are the same as for integration branches:

- labels compare case-insensitively;
- `ptc:` labels are reserved (`MaintainerLabels.reserved?/1`);
- labels are unique and use the same format and length rules;
- at most 20 mappings.

`MaintainerLabels` and `IntegrationBranches` already check label names twice,
with the same length limit and similar formats. Consolidate the name rule
(non-empty, length, format) into one public `MaintainerLabels.valid_name?/1`.
Use it from `MaintainerLabels.add/3` and its changeset validation, from
`IntegrationBranches`, and from `BranchPrefixes`. Keep the reserved check
separate, so `add/3` still returns its distinct `:reserved_label_name`. If the
two existing formats differ, keep the stricter one; a stored label it rejects
would fail changeset validation, so check the production data before
narrowing anything.

A mapping's prefix may equal the default prefix; that is harmless.

### Git ref collisions

Git cannot hold both `feature/payments` and `feature/payments/issue-1-job-1`.
When a prefix is set or mapped, the console refuses it if
`repositories.github_branch_names` contains any ancestor of the prefix. For
`team/bugfix/`, both a `team` branch and a `team/bugfix` branch block it; for
`bugfix/`, a `bugfix` branch does.

The check runs only in the `Operations` functions that introduce a prefix
(set the default, add a mapping), and only against that prefix. It is not part
of the repository changeset. A newly synced ancestor branch therefore never
blocks a GitHub sync, removing a mapping, or any unrelated repository update.

This check is advisory: the branch list is a cached projection, and git or GitHub
still refuses a real collision at worktree creation or push time. That ends as
an ordinary failed job, not a corrupted state.

## Resolution

`BranchPrefixes.resolve(repository, label_names)` returns:

- `{:ok, default}` when no mapped label is present;
- `{:ok, prefix}` when every mapped label present gives the same prefix;
- `{:error, {:conflicting_branch_prefixes, mappings}}` when two present labels
  give different prefixes.

The outcome is decided by the distinct prefixes. The conflict carries every
matched mapping, not one per prefix: with `bug → bugfix/`, `defect → bugfix/`
and `enhancement → feature/`, the audit names all three labels.

Only the issue's **own** labels count: `MaintainerLabels.reported_names(issue)`,
not `Operations.route_labels/2`. A bug filed inside a feature collection is
still a bug, and an umbrella's labels must not rename its members' branches.
This differs from integration-branch routing on purpose.

## Approval

`Operations.do_approve_issue/6` gains a `:branch_prefix` step next to `:base`:

| Mode | Prefix chosen in the form | Result |
| --- | --- | --- |
| `:prepared` / `:direct` | a configured choice | that prefix |
| `:prepared` / `:direct` | not one of the current choices | `{:error, :invalid_branch_prefix}` |
| `:prepared` / `:direct` | none, labels resolve | the resolved prefix |
| `:prepared` / `:direct` | none, labels conflict | `{:error, :conflicting_branch_prefixes}` |
| `:automatic` / `:collection` | n/a | the resolved prefix; on a conflict, the default prefix |

The prefix is checked against the repository row read inside the approval
transaction, so a stale form cannot submit a prefix that was just removed.

`Job.branch_prefix` is set on the inserted job. The audit event records
`"branch_prefix"`, plus:

- `"branch_prefix_override" => true` when the maintainer picked something
  other than the resolved prefix. Any explicit pick that settles a conflict
  counts as an override.
- `"branch_prefix_conflict" => [labels…]` when labels conflicted, whoever
  settled it.

Automatic and collection approvals never refuse over a prefix conflict. An
unattended approval has nobody to ask, and the default prefix is the one the
maintainer configured as always acceptable. Refusing would also break
collections: `Collections.apply_action/4` only logs a refused admission and
reports the member as ready again, so the run would retry it forever.

The other places that create or continue jobs:

- `retry_stopped_job/2` copies `stopped.branch_prefix`. A retry is the same
  decision, like `base_branch`.
- `resume_from_worktree/2` keeps the same job and branch, so nothing changes.
- `approve_afresh!/3` writes approvals only; the prefix lives on the job.

## Lease

One builder, `BranchPrefixes.branch_name(prefix, issue_number, job_id)`,
returns `{:ok, name}` or `{:error, :invalid_branch_prefix}`. Lease and the
broker both call it, so the format exists in one place. `lease_job` in
`lib/ptc_manager/operations.ex` stores the name it returns.
A job without a valid `branch_prefix` is refused with `:invalid_branch_prefix`
before the worktree is created. After the migration this cannot happen; the
refusal guards against a hand-edited row.

## Checks that change

| Location | Today | After |
| --- | --- | --- |
| `GitHub.AppBroker.valid_target_context/3` | `"ptc-manager/issue-#{issue.number}-job-#{publication.job_id}"` | `job.branch_prefix <> "issue-…-job-…"`, and `valid_prefix?(job.branch_prefix)` is true, else `:unexpected_job_branch` |
| `Repository.GitProbe.valid_branch/1` | regex `\Aptc-manager/issue-\d+-job-<id>\z` | regex built from `Regex.escape(job.branch_prefix)`; an invalid or missing prefix is refused as `:unexpected_branch`. It keeps accepting any issue number, because its callers pass a `Job` without the issue loaded. This is no weaker than today; the broker remains the exact-match boundary. |
| `mix ptc.herdr_workspace_canary` | `%Job{branch_name: "ptc-manager/…"}` | also sets `branch_prefix: "ptc-manager/"` |
| `MaintainerActions.Catalog` preview fixtures | literal `ptc-manager/issue-123-job-42` | unchanged: preview text only |

Both validators check `valid_prefix?/1` **before** building the expected name,
so a nil or non-string prefix returns the refusal instead of crashing in `<>`
or `Regex.escape/1`. Tests cover a nil and an invalid stored prefix for each.

The broker deliberately validates the frozen prefix's **format** only, not
whether it is still configured on the repository. The approval was the
decision, and a configuration change must not strand verified work. GitHub's
own ruleset stays the final authority on what may be pushed.

These need no change because they read the stored `job.branch_name` or
`publication.branch_name`: worktree creation in `HerdrAdapter`, the
pre-publication gate, `WorktreePreserver`, `Reviews.Snapshots`, `Worktrees`
reclaim, managed-head matching in `Publications.managed_pr_heads/1` (so a
`feature/issue-…` PR stays managed, not external), `PullRequestClient.discover/1`,
the runtime context line `Branch: …`, and the PR-analysis head checks.

## Out of scope

- **Repair-PR and investigation branches.** `ptc-manager/repair-pr-…` and
  `ptc-manager/review-issue-…` are local worktree branches that are never
  pushed under their own name: a repair pushes to the pull request's existing
  head. They keep their names.
- **GitHub native issue types.** These would be a cleaner signal than labels,
  but the sync does not fetch `issueType` today. That is a follow-up.
- **Templates beyond a prefix**, such as `bugfix/<number>-<slug>`. The
  `issue-<n>-job-<id>` suffix is what makes the broker's exact-match check and
  job identification work, so it stays fixed.

## Migration

`*_add_branch_prefixes.exs`:

- `repositories.branch_prefixes :map`, default
  `%{"default" => "ptc-manager/", "mappings" => []}`, backfilled for existing
  rows;
- `jobs.branch_prefix :string`, `null: false`, default `"ptc-manager/"`.
  The schema field has the same default, so test fixtures that build a `Job`
  directly keep the legacy name. Every approval path sets the field
  explicitly.

Every existing job used `ptc-manager/`, so the backfill is exact. That includes
queued jobs whose `branch_name` is still nil, so in-flight publications keep
passing the broker check.

## Console

**Repository configuration** (`RepositoryConfigurationLive`): add a "Branch
names" section next to integration branches, with:

- the default prefix as an editable field, saved with an audit event
  `repository.branch_prefixes_updated`;
- the mapping list with add and remove, labels offered from
  `github_label_names`;
- a preview line such as `bugfix/issue-123-job-42`.

The `Operations` functions follow `update_integration_branches/4`:
`set_default_branch_prefix/3`, `add_branch_prefix_mapping/4` and
`remove_branch_prefix_mapping/3`. Each rewrites the whole map inside an
immediate transaction from the stored row, and audits the result.

**Approval form** (`DashboardLive`): next to the base route, show the branch the
job will get, e.g. `bugfix/issue-123-job-…`.

- With one choice the prefix is shown as text and no field is sent.
- With more than one choice, a `branch-prefix` select lists them with the
  resolved prefix preselected.
- When labels conflict, nothing is preselected and the select is required.
  The server also rejects a conflicting issue whose submission carries no
  prefix, or an empty one, because the select's placeholder is an empty
  value. When labels resolve, a missing field means "use the resolved
  prefix".

The "Fix directly" button uses the same field, as it does for the review count.

## Risks

- **Broker strictness regression.** The broker check is part of the trust
  boundary. Tests must show that it still refuses a wrong prefix, a wrong
  issue number, a wrong job id, and an invalid stored prefix.
- **Hidden hard-coded prefixes.** Found by `grep "ptc-manager/"` over `lib`;
  only the two producers and the two validators above depend on the format.
  A test fixture using `ptc-manager/issue-job-<id>` is unaffected because it
  writes `branch_name` directly.
- **Conflicts in unattended approvals.** An issue labelled both `bug` and
  `enhancement` gets the default prefix when automation approves it. The audit
  event records the conflict, and the dashboard shows the conflict note for
  manual approval.
- **Ruleset mismatch.** A prefix the ruleset rejects fails at push time as
  today's push failures do. The console cannot read rulesets with its
  read-only client, so it does not try to validate against them.

## Tests

- `BranchPrefixes`: prefix format (valid and invalid cases above), mapping
  validation, case-insensitive resolution, conflicts, choices, and the
  collision check against cached branch names.
- Approval: each row of the approval table; overrides and conflicts are
  audited; automatic and collection approvals with a conflict use the default;
  retry copies the prefix.
- Lease builds the branch from the job's prefix.
- Broker: accepts `bugfix/issue-N-job-M` for a job frozen with `bugfix/`, and
  refuses mismatches and an invalid stored prefix.
- `GitProbe.valid_branch` through its public callers, with a non-default prefix.
- Freezing: approve with `bugfix/`, then remove the mapping and change the
  default, then lease, verify and publish. The branch is still `bugfix/…`, and
  the broker accepts it.
- Relabelling between approval and lease leaves the prefix unchanged, even
  when approval freshness refreezes the approval.
- `publication_source: "agent"`: a `feature/issue-…` PR is discovered and
  reconciled as managed, not external.
- `resume_from_worktree` keeps the non-default branch.
- The collision check refuses a new prefix with a cached ancestor branch, but
  still allows removing a mapping and running a GitHub sync.
- LiveView: the configuration section adds and removes mappings and edits the
  default; the approval form shows the preview, the select, and the
  conflict-required state, and submits the chosen prefix.
- Migration: existing jobs and repositories get `ptc-manager/`.
