# Automations Page Redesign

Status: implemented on 2026-09-02; see Outcome at the end
Scope: `/automations` LiveView, trigger editing, agent and workspace selection
Related: `docs/plans/coordinated-resource-operations.md`, the Operations tab
split in commit `36a0925`

## Purpose

The Automations page has grown into one long scroll of eleven identical cards,
each exposing every runtime setting and a full prompt editor. A maintainer
opens it to answer three questions: which automations exist and are on, when
does each one run, and did the last run work. Editing is the exception.

This plan restructures the page into a compact index and a per-automation
detail page, fixes the collapsible-state bug, replaces raw cron editing with a
schedule builder, and turns the free-text agent kind into a selector. It keeps
the existing domain model: definitions, immutable versions, triggers, and
invocations stay as they are, and every save still creates a new version.

## Problems observed

1. **Collapsibles close by themselves.** The create form, the schedule editor,
   the button editor, and "Copy to another repository" are plain `<details>`
   elements. The page subscribes to `Operations` changes and re-renders on
   every worker heartbeat. LiveView's DOM patch removes the browser-set `open`
   attribute because the server never rendered it, so the panel snaps shut
   within a couple of seconds. Only the prompt editor survives, because its
   open state lives in `expanded_definition_ids`.
2. **Eleven full-size cards.** Every card shows five raw setting chips, inline
   trigger editors, the complete prompt editor, and a copy panel. Built-ins are
   rarely edited, so most of the page is noise.
3. **Internal vocabulary.** Chips read `generic_ephemeral`, `planning / light`,
   `trusted_direct`, `1200s timeout`. The maintainer thinks in "read-only
   snapshot", "any agent", "full GitHub access", "20 minutes".
4. **Agent profile health** prints `inspect(worker.capabilities)`. Worker
   health belongs on Operations. The useful part, the list of agent kinds,
   should feed the agent selector instead.
5. **Run history is global** and prints full result Markdown for up to one
   hundred runs beneath the create form.
6. **Schedules need cron syntax** and are reached through a hidden "Add paused
   schedule" button. A unique index on `(definition, trigger_type, surface)`
   allows only one schedule per automation.
7. **The key is typed by hand.** It is an internal identifier used for
   uniqueness per repository, for `action_key` on queued actions, and for
   built-in default lookups. Nothing requires the maintainer to invent it.

## User experience

### Index: `/automations`

The page works on one repository at a time. The existing repository selector
in the top bar chooses it, and the browser-remembered selection is restored on
the next visit as it is today. When no repository is selected the index shows
the rows of every repository under one heading per repository, so the page is
still usable on first visit, but every action, the create page, and "Latest
runs" always refer to one repository. One row per automation, with columns:

- name, with a small "built-in" or "custom" tag and the version number;
- enabled switch (the existing `toggle-definition` event);
- "How it runs": a plain-language summary derived from the triggers, for
  example "Nightly at 03:00 · Run now · Button on Planning issues", or
  "Paused" when no trigger is enabled;
- agent: "Any", "Prefer codex", or "Only cursor";
- last run: state badge and relative time, from the newest invocation;
- next run: the earliest enabled schedule's `next_run_at`, in the schedule's
  time zone.

Clicking a row navigates to the detail page. A "New automation" button at the
top navigates to `/automations/new` with the selected repository preselected.
Below the table, "Latest runs" shows the five newest invocations for the
selected repository as one-line entries: automation name, trigger type, state,
requested time. Each links to its automation's Runs section. With no
repository selected the strip is hidden rather than mixing repositories.

Nothing on the index is editable except the enabled switch, so heartbeat
re-renders cannot lose state.

### Detail: `/automations/:id`

Sections, top to bottom:

1. **Header.** Name, repository, description, built-in or custom, enabled
   switch, and a "Run now" button when a manual trigger exists and is enabled.
2. **When it runs.** The trigger list and builder described below.
3. **Agent and workspace.** Agent policy and kind, workspace, GitHub access.
4. **Prompt.** The single editable prompt textarea, "Preview composed prompt"
   (existing overlay), and "Restore PtcManager suggestion" for built-ins.
5. **Advanced.** Internal key (read-only), queue lane, resource class, timeout
   in minutes. Collapsed by default, with its open state in an assign.
6. **Runs.** Invocations for this automation only, newest first, twenty at a
   time with a "Show more" button. Result Markdown is collapsed behind a
   per-run toggle whose state lives in an assign.
7. **Versions.** The existing "v3 by maintainer · v2 by …" line.
8. **Copy to another repository.** The existing buttons, shown only when more
   than one repository exists.

Sections 3, 4, and 5 are one form. Saving creates a new immutable version and
updates the identity fields, exactly as `save-definition` does today. The form
uses `phx-change` with a changeset-backed `to_form/2`, so typed values survive
re-renders and validation errors show inline.

### Create: `/automations/new`

A dedicated page with the same form as the detail page, reduced to what a new
automation needs: repository, name, description, prompt, agent, workspace,
GitHub access. The key is derived from the name as a slug (`[a-z][a-z0-9_]*`,
suffixed with `_2`, `_3` when taken) and shown read-only under Advanced, where
it can be overridden before the first save only. Creation still produces a
disabled definition with a disabled manual trigger, then redirects to the
detail page with a flash telling the maintainer to review and enable it.

### When it runs: trigger builder

Triggers are listed as rows, each with an enabled switch and a delete button
for non-built-in triggers:

- **Run now.** The manual trigger. Label editable. Always offered.
- **Schedule.** Offered only when `target_type == "repository"`, because a
  schedule has no issue or PR to act on. The editor has:
  - a preset select: "Every day", "Weekdays", "Every week on …" (with a day
    select), "Every hour", "Custom cron";
  - a time input (`HH:MM`) for the daily, weekday, and weekly presets;
  - a time zone select listing a short curated set (Europe/Stockholm default,
    Etc/UTC, Europe/London, Europe/Berlin, America/New_York,
    America/Los_Angeles) plus "Other…" revealing a free-text field validated
    with `Tz.TimeZoneDatabase`;
  - a raw cron field, visible for "Custom cron" and shown read-only for
    presets so the maintainer can see what will be stored;
  - a live "Next runs" list of the next three occurrences, computed from the
    current form values on every `phx-change`, rendered in the schedule's
    time zone with the UTC equivalent.

  The builder writes `cron_expression` and `time_zone`; `next_run_at` is
  recomputed by `Automations.update_trigger/2` as today. When a stored cron
  expression matches a preset pattern the editor opens on that preset,
  otherwise on "Custom cron".
- **Button.** The contextual trigger. Offered only for issue or PR targeted
  automations. Fields: label and surface ("Planning issues" or "Delivery pull
  requests").

Adding a trigger is a button per type that creates it disabled and opens its
editor, so nothing runs until the maintainer enables it. All editor open
states live in a `MapSet` assign keyed by trigger id.

### Agent and workspace

- **Agent policy**: "Any available agent", "Prefer a kind", "Only this kind".
- **Agent kind**: a select whose options are the union of the kinds reported
  by online workers (`capabilities["agent_kinds"]`) and the keys of the
  configured `:agent_profiles`, marked "(offline)" when no online worker
  reports them. Disabled when the policy is "Any". The value is stored in the
  existing `agent_selector` map as `preferred_kind`; no schema change.
- **Workspace**: today custom automations can only run in a read-only snapshot
  of the default branch (`execution_profile: "generic_ephemeral"`). The other
  profiles are bound to built-in adapters. The selector therefore shows
  "Read-only snapshot of the default branch" as the single choice for custom
  automations, with a sentence explaining why, and shows the built-in's fixed
  profile as read-only text. A writable worktree that can push a branch and
  open a pull request is a follow-up (see below), not part of this plan.
- **GitHub access**: "None", "Read", "Full gh CLI", "Brokered publish (built-in
  only)", using the existing values.

### Re-render policy

The page keeps its `Operations.subscribe/0` so run states update live, but
nothing editable depends on browser-only state anymore. Every collapsible
binds `open` to an assign, every form is changeset-backed, and the create and
detail pages are routes. Reloading on `{:operations_changed, _}` may be
narrowed to invocation-related sources later if it proves noisy.

## Routing and module structure

Follow the Operations split: one LiveView with live actions and one template
per action.

```
live "/automations",          AutomationsLive, :index
live "/automations/new",      AutomationsLive, :new
live "/automations/:id",      AutomationsLive, :show
```

- `lib/ptc_manager_web/live/automations_live.ex` keeps the events and helper
  functions and uses `embed_templates "automations_live/*"`.
- `lib/ptc_manager_web/live/automations_live.html.heex` becomes the shell:
  header and the `case @live_action` dispatch, like `operations_live.html.heex`.
- `automations_live/index.html.heex`, `new.html.heex`, `show.html.heex`.
- The nav highlight uses `String.starts_with?(@current_path, "/automations")`.
- The repository selector's `?repo=` parameter is preserved across patches by
  a `path/2` helper that drops blank parameters, as `OperationsLive.tab_path/2`
  does.

New context helpers in `PtcManager.Automations`:

- `trigger_summary/1`: the plain-language "how it runs" string;
- `list_invocations_for_definition/2` with a limit and offset;
- `latest_invocation_by_definition/1` for the index rows;
- `slug_key/2` deriving an available key from a name for a repository;
- `Automations.Schedule` (new module): `presets/0`, `build_cron/2` from a
  preset and time, `detect_preset/1` from a stored expression,
  `next_occurrences/4` using `Oban.Cron.Expression` and `Tz`, and
  `valid_time_zone?/1`.

Presentation helpers in the LiveView map stored values to labels:
`execution_profile`, `github_access`, agent policy, timeout in minutes.

## Data model

No migration is required for the index, detail, create, builder, or selector
work. Two optional changes:

1. **Several schedules per automation.** Replace the unique index on
   `automation_triggers (automation_definition_id, trigger_type, surface)`
   with a partial unique index that excludes schedules:

   ```elixir
   drop unique_index(:automation_triggers, [:automation_definition_id, :trigger_type, :surface])
   create unique_index(:automation_triggers, [:automation_definition_id, :trigger_type, :surface],
     where: "trigger_type <> 'schedule'")
   ```

   `Defaults`' `ensure_default_triggers/3` looks triggers up by type and
   surface and must instead match schedules by label so it does not insert a
   second default schedule on every boot.
2. **Nothing else.** `agent_selector` already holds mode and preferred kind;
   `cron_expression`, `time_zone`, and `next_run_at` already exist.

## Test strategy

LiveView tests, one per route:

- **Index** renders one row per definition with the trigger summary, last run,
  and next run; the enabled switch toggles; the "Latest runs" strip lists the
  newest five; the repository filter narrows rows.
- **Create** derives the key from the name, refuses a duplicate name with an
  inline error, creates a disabled definition plus a disabled manual trigger,
  and redirects to the detail page.
- **Detail** saves settings and prompt as a new version; opens the prompt
  preview; lists runs for this automation only; copies to another repository.
- **Regression for the collapsible bug:** open the Advanced section and a
  trigger editor, send `{:operations_changed, :test}` to the view, and assert
  both remain open.
- **Trigger builder:** adding a schedule creates it disabled; choosing "Every
  day" at 03:00 in Europe/Stockholm stores `0 3 * * *` and shows the next
  three occurrences with the correct UTC offset across a DST boundary; the
  custom cron field rejects an invalid expression inline; schedules are not
  offered for issue-targeted automations; buttons are not offered for
  repository-targeted ones.
- **Agent selector:** options come from online workers' `agent_kinds`,
  offline-only kinds are marked, and saving stores `preferred_kind` in
  `agent_selector`.

Context tests for `Automations.Schedule` cover preset round-trips, detection
of stored expressions, and time-zone validation. Existing tests in
`test/ptc_manager_web/live/automations_live_test.exs` are rewritten to the new
routes; `test/ptc_manager/automations_test.exs` stays unchanged except for the
optional multi-schedule change.

## Delivery checkpoints

1. **Split and bug fix.** Routes, shell template, index, detail, create page,
   assign-backed collapsibles, changeset-backed forms, plain-language labels,
   removal of the agent profile section, per-automation runs. Existing trigger
   editing keeps working with the raw cron field.
2. **Schedule builder.** `Automations.Schedule`, presets, time zone select,
   next-occurrence preview, detection of stored expressions.
3. **Agent and workspace selectors.** Kind options from worker capabilities and
   agent profiles, policy select, workspace explanation, key slug and
   Advanced section.
4. **Several schedules per automation** (optional). Partial unique index,
   defaults matching by label, delete button for extra schedules.
5. **README.** Update the `/automations` route description and the
   "automations" section to the new structure.

Each checkpoint is one commit that passes `mix precommit`, with a demo-mode
browser check of the index, detail, and create pages.

## Follow-ups outside this plan

- **Writable workspace for custom automations.** A new execution profile
  (working name `repository_worktree`) that provisions a fresh worktree on a
  new branch through the implementation-job path, grants `brokered_publish`,
  and lets a custom automation open a pull request. Needs its own adapter
  routing in `ActionAdapter`, lock policy, and result schema.
- **Event triggers.** "When a pull request opens", "when nightly CI fails",
  "when an issue is labelled". The GitHub poller already observes these
  changes; a fourth trigger type with a filter map would materialize
  invocations the same way schedules do. Deduplicate with `occurrence_key`.
- **Trigger-level notifications.** Surface failed scheduled runs on the
  Planning page or in the daily update so a broken nightly job is noticed.

## Decisions

1. Built-in automations accept extra schedules and buttons like custom ones.
   Repository-targeted built-ins such as "Investigate nightly CI" can gain a
   second schedule; issue and PR targeted built-ins can gain a second button.
   Default triggers keep their labels so `ensure_default_triggers/3` still
   recognises them.
2. The time zone select stays curated (Europe/Stockholm, Etc/UTC,
   Europe/London, Europe/Berlin, America/New_York, America/Los_Angeles) with
   an "Other…" free-text field validated against `Tz`. Europe/Stockholm is
   the default for every new schedule.
3. The page is per repository. "Latest runs" never mixes repositories, and
   the create page is always bound to the selected one.

## Outcome

Implemented in one change with the following deviations from the text above:

- Built-in schedules are recognised by a `"built_in" => true` marker in the
  trigger's `configuration`, not by label. The migration that relaxes the
  unique index marks the existing schedules of `daily_digest` and
  `nightly_ci_investigation`, since before it a definition could hold only
  one. Labels of schedules are derived from the preset on every save.
- The templates are `index`, `detail`, and `create` because `show/1` would
  shadow the `show` JS command imported from `CoreComponents`, and the path
  helper is `page_path/2` because `path/2` is the verified-routes macro.
- Schedule editors have no label field; the trigger row shows the
  plain-language description instead. Button surfaces are restricted to the
  surface matching the automation's target type, since the maintainer-action
  catalog only accepts issue keys on Planning and PR keys on Delivery.
- The agent kind select offers a blank "Choose a kind…" option so a disabled
  select under "Any available agent" does not display a misleading kind.

