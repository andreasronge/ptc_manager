defmodule PtcManager.Automations.Defaults do
  @moduledoc "Built-in automation definitions used to preserve the current workflows."

  @common %{
    agent_selector: %{"mode" => "any", "required_capabilities" => []},
    result_protocol_version: 1,
    configuration_snapshot: %{}
  }

  @definitions [
    %{
      key: "toolchain_pin_bump",
      name: "Open toolchain update PR",
      description: "Change one approved toolchain pin and open a draft PR for human review.",
      target_type: "repository",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "writing",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "toolchain_pin_bump",
      prompt:
        "Update only the approved version and its approved digest and protocol pins in deploy/toolchain-versions. Run mix precommit, commit the change, and open a draft pull request for human review. Do not merge or change any other file or pin. Return the pull request number and the exact approved program, version, digest, and protocol values."
    },
    %{
      key: "post_cancellation_note",
      name: "Post cancellation explanation",
      description:
        "Post one explicitly approved explanation after an implementation is cancelled.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 300,
      result_type: "issue_maintenance",
      prompt:
        "Post only the exact approved explanation to the named issue. Check for an existing identical comment before writing. Do not make any other GitHub or repository changes. Return completed once the comment exists."
    },
    %{
      key: "private_issue_analysis",
      name: "Private issue analysis",
      description: "Create the simple private planning summary shown in the backlog.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "read",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 120,
      result_type: "private_issue_analysis",
      prompt:
        "Explain this issue in simple language for the maintainer. Inspect the repository read-only and report readiness, scope, risk, and concrete technical evidence."
    },
    %{
      key: "implement_issue",
      name: "Implement issue",
      description: "Implement, test, review, commit, and publish an issue pull request.",
      target_type: "issue",
      execution_profile: "implementation_job",
      github_access: "brokered_publish",
      queue_lane: "writing",
      resource_class: "heavy",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 7_200,
      result_type: "implementation",
      prompt:
        "Fix the issue completely. Follow the repository instructions, run all required checks, commit the validated change, perform the configured reviews, and publish the reviewed commit in a pull request that closes the issue. Its description needs a summary, what you verified beyond the repository hooks, and a `## Retrospective` section with two items that may each be `none`: untracked follow-up work with a reproduction, and one repository instruction that was missing, wrong, or that you had to guess at. If the Retrospective lists untracked follow-up work, add the label `ptc:follow-up` to the pull request. Do not merge it."
    },
    %{
      key: "prepare_issue",
      name: "Prepare issue",
      description: "Investigate an issue and make its GitHub state implementation-ready.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "Prepare the issue for implementation. Re-read the issue and relevant code, then update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), rejected by closing it, or split (`split`) when it cannot be delivered as one reviewable pull request: more than one independently reviewable deliverable, more than one subsystem, or a change too large for one review pass. Splitting means turning the plan into GitHub sub-issues with native blocked-by ordering as described in the runtime context, never marking the parent ready. Do not implement it, and explain the result simply."
    },
    %{
      key: "report_issue_blocker",
      name: "Report implementation blocker",
      description: "Put an agent's reason for stopping on the issue for a maintainer decision.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 900,
      result_type: "issue_maintenance",
      prompt:
        "An implementation agent stopped on this issue and reported why. Verify that claim against the issue and the code, then write one comment saying what a person has to settle before implementation can start again, and leave the issue blocked (`ptc:blocked`) or needing a decision (`ptc:needs-decision`). Do not implement anything, do not mark the issue ready, and do not close it."
    },
    %{
      key: "review_issue",
      name: "Review issue",
      description: "Challenge and improve issue readiness without implementing it.",
      target_type: "issue",
      execution_profile: "ephemeral_investigation",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "heavy",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "Review whether the issue is genuinely ready to implement. Use the disposable workspace to run relevant tests and create temporary reproduction tests when useful. Improve the issue and update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), rejected by closing it, or split (`split`) when it cannot be delivered as one reviewable pull request: more than one independently reviewable deliverable, more than one subsystem, or a change too large for one review pass. Splitting means turning the plan into GitHub sub-issues with native blocked-by ordering as described in the runtime context, never marking the parent ready. Exploratory source changes will be discarded: do not implement the fix, commit, push, or open a pull request. Explain the result simply."
    },
    %{
      key: "structure_collection",
      name: "Structure collection",
      description: "Turn a plan issue into ordered GitHub sub-issues, or repair their relations.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "Make this issue a collection whose members can be implemented one pull request at a time. When it has no sub-issues yet, create one sub-issue per independently reviewable pull request, each with a goal, scope, and acceptance criteria that stand alone. Record every ordering as a native GitHub blocked-by relation using the calls in the runtime context; a `Blocked by #N` line in a member body helps readers but is not the record. Label a member `ptc:ready` when its only blockers are other members and it is fully specified, otherwise `ptc:blocked` or `ptc:needs-decision`. Never label the parent `ptc:ready`. Report `structured` when the parent has at least two sub-issues, `no-changes` when the issue fits one pull request, or `needs-decision` with options. Do not implement anything."
    },
    %{
      key: "collection_handoff",
      name: "Collection handoff",
      description:
        "After a member pull request merges, carry its retrospective into the remaining members.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "A member pull request of this collection was merged. Read its description and retrospective, then update the open, unprotected members whose assumptions the merged work changed. When the retrospective names a defect or a small fix that a later member depends on, create one fix-up sub-issue of the parent labelled `ptc:ready`, with native blocked-by relations that place it before its dependents; never push code. Create an ordinary issue for follow-up work outside the collection only when it is concrete and not already tracked. Never edit a closed or protected issue, never change the parent's labels, never merge anything. Report `completed` when you changed GitHub, `no-changes` when nothing needed changing, or `needs-decision` with options."
    },
    %{
      key: "collection_closeout",
      name: "Collection close-out",
      description: "Check a delivered collection against its acceptance criteria.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "Every member of this collection is closed as completed. Check the parent issue's acceptance criteria against the default branch in the read-only snapshot and post one summary comment on the parent saying what is met and what is not. Report `needs-decision` with options such as closing the parent or keeping it open when the criteria are met or when you cannot tell; report `completed` when something is still missing and you created the missing sub-issues labelled `ptc:ready` with native blocked-by relations; report `no-changes` when the parent is already closed. Never close the parent yourself and never implement anything."
    },
    %{
      key: "report_collection_blocker",
      name: "Report collection blocker",
      description: "Tell the maintainer, on the parent issue, why a collection run paused.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 900,
      result_type: "issue_maintenance",
      prompt:
        "A collection run paused on one of this issue's members. Write one comment on this issue naming the member, what stopped, and the console link from the runtime context, then leave the issue needing a decision (`ptc:needs-decision`) with two to four plain-language options. Do not implement anything, do not edit the member, do not mark anything ready, and do not close anything."
    },
    %{
      key: "resolve_issue_decision",
      name: "Resolve issue decision",
      description: "Apply a maintainer answer to an issue and remove its decision marker.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_200,
      result_type: "issue_maintenance",
      prompt:
        "Apply the maintainer's decision to the issue, rewrite it so the decision is clear, and leave it ready, blocked, still needing a decision, or closed as appropriate. Do not implement it."
    },
    %{
      key: "daily_digest",
      name: "Daily update",
      description: "Create a private summary of repository changes for one calendar day.",
      enabled: false,
      target_type: "repository",
      execution_profile: "generic_ephemeral",
      github_access: "read",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "definition"},
      timeout_seconds: 1_800,
      result_type: "daily_digest",
      prompt:
        "Write a concise daily update for a busy maintainer using only the supplied delivery evidence. Use plain, factual language: no hype, generic praise, or unnecessary jargon. Start with a two-sentence overview in the summary field. For each shipped change, give one short sentence describing it and one explaining why it matters. Include at most three concrete, attributed lessons, and omit lessons when the evidence does not support them. Aim for a one-minute read on ordinary days; allow more space when needed to cover significant changes. Keep unknowns explicit and reported claims attributed. Do not propose or create issues."
    },
    %{
      key: "repair_pr",
      name: "Fix pull request",
      description: "Repair CI failures or conflicts and push the existing PR branch.",
      target_type: "pull_request",
      execution_profile: "retained_pr_repair",
      github_access: "trusted_direct",
      queue_lane: "writing",
      resource_class: "heavy",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 7_200,
      result_type: "pull_request_repair",
      prompt:
        "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, then push the existing PR branch; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Do not create another PR, merge, or force-push."
    },
    %{
      key: "repair_and_merge_pr",
      name: "Fix and merge pull request",
      description: "Repair, verify, push, wait for CI, and merge the exact PR.",
      target_type: "pull_request",
      execution_profile: "retained_pr_repair",
      github_access: "trusted_direct",
      queue_lane: "writing",
      resource_class: "heavy",
      lock_policy: %{"type" => "repository_merge"},
      timeout_seconds: 10_800,
      result_type: "pull_request_repair",
      prompt:
        "Fix the pull request's failing CI or merge conflicts, validate the repair with the repository's own checks, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable; the pull request's CI is the gate for a repair, because the managed review is not available in an action. Bring the branch up to date with the latest default branch and revalidate before you merge, so the result is proven against what it merges into. Do not force-push or work on another PR."
    },
    %{
      key: "merge_reviewed_pr",
      name: "Merge reviewed pull request",
      description: "Merge exactly the reviewed head of a collection member's pull request.",
      target_type: "pull_request",
      execution_profile: "retained_pr_repair",
      github_access: "trusted_direct",
      queue_lane: "writing",
      resource_class: "heavy",
      lock_policy: %{"type" => "repository_merge"},
      timeout_seconds: 3_600,
      result_type: "pull_request_repair",
      prompt:
        "Merge this pull request at exactly the authorized head named in the runtime context. Mark it ready for review if it is a draft, wait for required CI, and merge it when it is green and mergeable. Do not commit, push, rebase, or change the branch in any way: if the head differs from the authorized one, CI fails, or the pull request is not mergeable, report `repair-blocked` and stop."
    },
    %{
      key: "pr_retrospective",
      name: "Pull-request retrospective",
      description: "Inspect a completed change for concrete follow-up work.",
      target_type: "pull_request",
      execution_profile: "generic_ephemeral",
      github_access: "read",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "retrospective",
      prompt:
        "Review the completed pull request read-only and propose only concrete, untracked follow-up work such as potential bugs, refactoring, flaky tests, or missing tests. Returning no suggestions is valid."
    },
    %{
      key: "create_retrospective_issue",
      name: "Create retrospective issue",
      description: "Create one selected follow-up issue from retrospective evidence.",
      target_type: "pull_request",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_200,
      result_type: "github_issue_change",
      prompt:
        "Create at most one GitHub issue for the maintainer-approved retrospective suggestion, unless the work is already tracked. Do not modify code or unrelated GitHub items."
    },
    %{
      key: "nightly_ci_investigation",
      name: "Investigate nightly CI",
      description:
        "Inspect the latest nightly workflow and create or update a deduplicated issue when it failed.",
      target_type: "repository",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "definition"},
      timeout_seconds: 1_800,
      result_type: "repository_report",
      prompt: """
      Inspect the latest completed nightly GitHub Actions workflow for this repository. If it succeeded, report that no action was needed. If it failed, inspect bounded logs, search open and closed issues for the supplied invocation marker, and create or update exactly one GitHub issue describing the failure, evidence, and a useful next step. Never create a duplicate for the same workflow run. Return a concise private Markdown report and every GitHub URL changed.
      """
    }
  ]

  def all(repository) do
    repo = "#{repository.github_owner}/#{repository.github_name}"

    Enum.map(@definitions, fn definition ->
      definition
      |> Map.merge(@common)
      |> Map.update!(:prompt, &"For #{repo}: #{&1}")
    end)
  end

  def get(repository, key), do: Enum.find(all(repository), &(&1.key == key))

  @doc "Returns the built-in display name for an automation key, or nil for a custom key."
  def name(key) when is_binary(key),
    do: Enum.find_value(@definitions, &(&1.key == key && &1.name))

  def triggers("daily_digest", _repository) do
    [
      %{
        trigger_type: "manual",
        surface: "automations",
        label: "Generate update now",
        enabled: false,
        configuration: %{}
      },
      %{
        trigger_type: "schedule",
        surface: "automations",
        label: "Daily at 02:00",
        enabled: false,
        configuration: %{},
        cron_expression: "0 2 * * *",
        time_zone: "Europe/Stockholm"
      }
    ]
  end

  def triggers("nightly_ci_investigation", repository) do
    enabled = repository.github_name == "ptc_runner"

    [
      %{
        trigger_type: "manual",
        surface: "automations",
        label: "Check nightly CI now",
        enabled: enabled,
        configuration: %{}
      },
      %{
        trigger_type: "schedule",
        surface: "automations",
        label: "Nightly CI check",
        enabled: false,
        configuration: %{},
        cron_expression: "30 5 * * *",
        time_zone: "Europe/Stockholm"
      }
    ]
  end

  def triggers(key, _repository)
      when key in [
             "private_issue_analysis",
             "prepare_issue",
             "review_issue",
             "structure_collection"
           ] do
    [
      %{
        trigger_type: "contextual",
        surface: "planning_issue",
        label:
          case key do
            "private_issue_analysis" -> "Investigate privately"
            "prepare_issue" -> "Prepare issue"
            "review_issue" -> "Review issue"
            "structure_collection" -> "Structure collection"
          end,
        enabled: true,
        configuration: %{}
      }
    ]
  end

  def triggers("repair_and_merge_pr", _repository) do
    [
      %{
        trigger_type: "contextual",
        surface: "delivery_pr",
        label: "Fix and merge",
        enabled: true,
        configuration: %{}
      }
    ]
  end

  def triggers(_key, _repository), do: []
end
