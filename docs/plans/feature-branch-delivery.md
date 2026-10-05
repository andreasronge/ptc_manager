# Feature-branch delivery and per-repository configuration

Status: planned. Nothing here is implemented.

Goal: deliver the SKA step-1 issues in `tyraorg/api` as one collection whose
pull requests merge into the integration branch `feature/ska`, and make room
for more `tyraorg` repositories.

## Findings (2026-10-05)

### tyraorg/api

- Private Deno repository with an `AGENTS.md` and GitHub Actions CI
  (`test.yml` and others). GitHub's default branch is `develop`, where pull
  requests merge and where `Closes #N` closes issues. `main` also exists.
  `develop` is unprotected.
- `feature/ska` exists and is level with `develop`. The `ska` dev environment
  deploys from it.
- 13 open issues carry `ska` (#117–#129). None has a parent, sub-issues, or a
  blocked-by link.
- #123 (step 1) and #124 (step 2) are tracking issues. Their order lives in
  Markdown task lists, which PtcManager does not read.
- No `ptc:*` workflow labels exist in the repository.

### Server credentials

- `GITHUB_READ_TOKEN` is the `gh` OAuth token (`gho_`) of `andreasronge`, not
  the fine-grained token the README describes. It reads `tyraorg/api`.
- The worker's `gh` is logged in as `andreasronge` (`repo`, `read:org`,
  `workflow`), has admin on `tyraorg/api`, and is git's credential helper, so
  agents can clone, fetch, push, and open pull requests there.
- `PTC_PUBLICATION_ENABLED=false`: the GitHub App broker is not in use, so no
  App installation is needed for `tyraorg`.
- Registered repositories: `ptc_runner`, `ptc_manager`, `ptc-fs-mcp`, all
  public, all on `main`.
- The worker has no `deno`.

### Gaps

- **Provisioning cannot clone a private repository.** The Prepare repositories
  button starts `deploy/ptc-manager-provision-repository`, which clones as root
  with an anonymous `git clone https://github.com/<owner>/<name>`. Root has no
  GitHub credentials. The script exits on the first failure, before it writes
  any service drop-in, so one private repository stalls provisioning for all.
- **Checkout paths collide across owners.** Onboarding sets
  `local_path: "/srv/#{name}"` (`operations.ex:198`).
- **Workspace setup must be a file in the repository.** `Repository.Contract`
  requires `.ptc-manager.yml` with a `bootstrap` script path at the worktree's
  commit. `tyraorg/api` has none.
- **The base branch is the repository's `default_branch`, set once.** PR
  creation (`app_broker.ex:609`), the base fetch (`app_broker.ex:502-512`), PR
  target checks (`app_broker.ex:701`, `publications.ex:1805`,
  `merge_decisions.ex:270`, `maintainer_actions/sync.ex:500`,
  `toolchain/pin_bump.ex:107`, `delivery_evidence/selection.ex:69`), worktree
  checks (`git_probe.ex:112,289,308`, `worktrees.ex:265`), and the agent prompts
  (`herdr_adapter.ex:745,773`, `catalog.ex:236,804,880`, `automations.ex:816`,
  `maintainer_actions.ex:755-848`) read it. Nothing edits it after onboarding.
- **Collections assume members close.**
  - A member counts as delivered once its PR is `merged` (`collections.ex:588`).
    That already works for an integration branch.
  - A dependency is satisfied only when the blocker is closed as completed
    (`operations.ex:5428`), so the second member of a chain is never admitted.
  - A run closes out only when every member is `:closed_completed`
    (`collections.ex:413`), so it never finishes.
  - `Collections.Structure.validate/1` accepts a blocker only if it is a member
    or closed, and refuses nested collections and members from another
    repository.
- **Merged-but-open work disappears.** The Delivery board drops a job once its
  PR merges (`operations.ex:2839`).
- **The Configuration page repeats every section per repository.**
  `configuration_live.html.heex` is about 600 lines and grows with each
  repository.

## Decisions

- Issues close only when their work reaches the default branch. GitHub does
  that itself through `Closes #N`, so `develop` merges keep closing issues.
- An issue labelled with a mapped label, or a member of a collection whose
  umbrella carries it, targets that label's integration branch. Its issue stays
  open after the merge and counts as integrated.
- "Integrated" is derived from the merged PR PtcManager already records from
  GitHub. It is not a new label or a stored issue state.
- Integrated work is not implemented again, unblocks dependents that target the
  same branch, and shows in its own lane until GitHub closes the issue.
- Workspace setup moves from `.ptc-manager.yml` to the database.
  `verification` and `deployment` stay in the file because brokered publication
  and self-deployment freeze them from an exact commit.
- Existing checkouts keep their paths. New repositories go under
  `/srv/<owner>/<name>`.

## Plan

Each step is one pull request and is useful on its own.

### 1. Repository configuration page

- `/configuration`: worker capacity, integrations, Add repository, and a
  compact list of repositories (name, enabled, sync status, health badge) that
  links to each.
- `/configuration/repositories/:id`: health and checkout, enable/disable,
  auto-fix, maintainer labels, agent environment variables, and Remove. Later
  steps add branches, workspace setup, and integration branches here.
- The existing handlers move with their sections. No behaviour changes.

### 2. Editable default branch, checked against GitHub

- `Operations.update_repository_branch/3` trims and validates the name with
  the broker's `safe_ref?` rule. It refuses while the repository has active
  jobs or open managed pull requests, and writes an audit row.
- Onboarding prefills the branch from GitHub's `default_branch` and validates
  it the same way.
- Synchronization records GitHub's default branch. The repository page warns
  when it differs from the configured one and never changes it on its own.

### 3. More than one owner, private repositories

- Onboarding defaults `local_path` to `/srv/<owner>/<name>` for new
  repositories. Existing checkouts stay: their paths are also in
  `deploy/ptc_manager.service`, `ptc_manager-herdr.service`,
  `PTC_REPOSITORY_PATH`, and the git metadata of retained worktrees.
- Provisioning creates the checkout directory owned by `ptc-manager-worker` and
  runs `git clone` as that user, whose `gh` credential helper reads private
  repositories. A failed clone is reported for that repository and does not
  stop the drop-ins for the others.
- Until this lands, a checkout cloned by hand as the worker works: provisioning
  skips a checkout that already exists.
- README: the read token may be the `gh` OAuth token. An App installation per
  owner is needed only when brokered publication is enabled.

### 4. Workspace setup in the database

- Repository setting on the repository page: a setup command and a timeout,
  run as the worker in each new worktree with the repository's agent
  environment variables, under the operation wrapper.
- `Repository.Contract` drops `bootstrap`. `.ptc-manager.yml` becomes optional
  and holds only `verification` and `deployment`. Repository health checks the
  setting instead of the file.
- A migration sets the existing repositories to `./scripts/ptc/bootstrap` with
  a 30-minute timeout, the largest in use (`ptc_runner`). The maintainer can
  lower it per repository.
- The same release removes `bootstrap` from this repository's
  `.ptc-manager.yml`. `ptc_runner` and `ptc-fs-mcp` drop it from theirs
  afterwards. Their files are not read in the meantime, because publication
  verification is off and only `ptc_manager` deploys.

### 5. Label-mapped integration branches

- Repository setting: a list of `{label, branch, active}` entries, validated
  like maintainer labels. Branch existence is checked on GitHub at save time
  and again before dispatch.
- Suggestions, not automatic routing: synchronization lists the remote
  branches, and the repository page suggests a mapping when a label `x` has a
  matching `feature/x` branch. The maintainer adds it with one click. A label
  and branch that merely share a name (`cleanup`, an old `feature/cleanup`)
  never change where a pull request goes without that decision.
- An inactive mapping keeps its entry but routes nothing: issues with that
  label target the default branch again. Removing the mapping once the feature
  reaches the default branch ends it. Jobs already approved keep their stored
  base either way.
- `jobs.base_branch` and `pr_publications.base_branch`, backfilled from
  `default_branch`.
- Approval resolves the base from the issue's labels, shows "→ feature/ska" on
  the approval card, and stores it. The card offers "→ develop instead" for a
  single issue that should skip the feature branch; the choice is recorded with
  the approval. A collection run offers the same choice once, at start. Two labels that map to different branches
  block approval with a reason. A collection run resolves the base from the
  umbrella issue, and every member inherits it.
- Every use listed under "The base branch is the repository's
  `default_branch`" reads the stored base instead. Deployments, digests, source
  updates, and health stay on `default_branch`.
- A label change after approval does not retarget the job. The card shows the
  mismatch.
- Approval refuses an issue that already has a PR merged into its mapped
  integration branch.

### 6. Integrated lane and collection completion

- `DeliveryLane` gains `:integrated`. `delivery_board_items` includes merged
  managed PRs whose base is not the default branch and whose linked issue is
  still open, grouped by branch. Planning shows the same badge.
- The Delivery board and Planning get a branch filter (all, default branch
  only, or one integration branch), remembered per viewer.
- A blocker is satisfied when it is closed as completed, or when it has a PR
  merged into the base branch the dependent issue targets. Dependency
  admission and `Collections.Structure.validate/1` use the same rule, so an
  integrated blocker outside the collection is accepted.
- The approved merge action on an integration-branch PR comments on each linked
  issue: "Merged into `feature/ska` in #N; stays open until `feature/ska`
  reaches `develop`."
- A collection run on an integration branch ends as `integrated` once every
  member is merged. Its close-out comment on the umbrella lists the members.
- The lane offers the `Closes #…` lines for the `feature/ska → develop` pull
  request, which the maintainer opens. When GitHub closes the issues, the cards
  leave the lane.

## Verification

Each step is checked locally before it merges, and the whole feature is
checked against `tyraorg/api` before the production run.

### Per step: demo mode

Use the isolated demo checkpoint from `README.md` (`tmp/ptc_manager_demo.db`,
port 4100). Extend `mix ptc.demo.reset` so each new surface has seed data:

| Step | Seed | Check |
|---|---|---|
| 1 | Four repositories, one with sync errors and missing labels | `/configuration` stays short; each repository page shows its sections; enable, auto-fix, labels, variables, and Remove still work |
| 2 | One repository whose GitHub default branch differs | The mismatch warning; editing refused while work is active |
| 4 | Repositories with and without a setup command | Setup form; health shows a missing command |
| 5 | A `ska → feature/ska` mapping; an issue with two conflicting labels | Approval card shows "→ feature/ska"; conflict blocks approval |
| 6 | Merged-but-open members on `feature/ska`; a collection with every member merged | Integrated lane grouped by branch; Planning badge; run ends `integrated`; `Closes` list |

Static screenshots and Playwright click-throughs, as for earlier page work.
Screenshots go in the pull request.

### Before production: local console against tyraorg/api

A separate development database and a disposable clone, so neither the
development database nor the working checkout at `~/projects/tyra/api` is
touched:

```sh
git clone git@github.com:tyraorg/api.git tmp/tyraorg-api
GITHUB_READ_TOKEN=$(gh auth token) PTC_DATABASE_PATH=tmp/ptc_manager_tyra.db \
  PORT=4200 mix phx.server
```

Agent actions stay disabled, so nothing writes to GitHub. Check:

1. Onboarding `tyraorg/api` prefills `develop` and proposes
   `/srv/tyraorg/api`. For this run, point `local_path` at the absolute path of
   `tmp/tyraorg-api` from `iex -S mix`.
2. Synchronization brings in the 13 `ska` issues. The repository page reports
   the missing `ptc:*` labels.
3. The `ska → feature/ska` mapping saves, and an unknown branch is refused.
4. The approval card for a `ska` issue shows "→ feature/ska".
5. #123 is refused as a collection while it has no sub-issues. After the
   GitHub preparation below, it validates with members in dependency order.
6. The workspace setup command, called through
   `PtcManager.Repository.WorkspaceSetup.run/3` on a `git worktree` of
   `tmp/tyraorg-api` at `feature/ska`, installs Deno and dependencies on the
   Mac. The server run in the next section proves it for the worker.

### Production: one member, then the run

1. In `tyraorg/api`: create the `ptc:*` labels. Make #118, #121, #127, #117,
   #129, #119 sub-issues of #123 with blocked-by links in the task-list order,
   either by hand or with the Structure collection action.
2. Onboard `tyraorg/api` on the server: branch `develop`, workspace setup,
   `ska → feature/ska`, provision, enable.
3. Approve one member with no blockers (#118 or #121) on its own. Its PR must
   target `feature/ska`, pass CI, merge, leave the issue open with the merge
   comment, and appear in the Integrated lane.
4. Start the #123 collection run. Dependents must be admitted after their
   blockers merge into `feature/ska`, and the run must end `integrated`.

#124 is not a collection PtcManager can run, because its work spans
`tyraorg/api`, `tyraorg/web`, and `tyraorg/infra`. It stays a tracking issue.
Its api work (#122, then #128 → #125) can become a small api collection once
step 1 is integrated. Web work needs `tyraorg/web` onboarded with its own
collection.

## Resolved questions

- All `ska` issues, including #127, #129, and #128 → #125, target
  `feature/ska`.
- The Integrated lane does not track how far `feature/ska` is behind
  `develop`. Keeping it current stays manual.
