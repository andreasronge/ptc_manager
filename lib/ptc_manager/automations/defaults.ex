defmodule PtcManager.Automations.Defaults do
  @moduledoc "Built-in automation definitions used to preserve the current workflows."

  @common %{
    agent_selector: %{"mode" => "any", "required_capabilities" => []},
    result_protocol_version: 1,
    configuration_snapshot: %{}
  }

  @definitions [
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
        "Fix the issue completely. Follow the repository instructions, validate the change, perform the configured reviews, commit it, and publish a pull request that closes the issue. Its description needs a summary, what you verified beyond the repository hooks, and a `## Retrospective` section with two items that may each be `none`: untracked follow-up work with a reproduction, and one repository instruction that was missing, wrong, or that you had to guess at. Do not merge it."
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
        "Prepare the issue for implementation. Re-read the issue and relevant code, then update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply."
    },
    %{
      key: "review_issue",
      name: "Review issue",
      description: "Challenge and improve issue readiness without implementing it.",
      target_type: "issue",
      execution_profile: "generic_ephemeral",
      github_access: "trusted_direct",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "issue_maintenance",
      prompt:
        "Review whether the issue is genuinely ready to implement. Improve it and update GitHub with one outcome: ready (`ptc:ready`), blocked (`ptc:blocked`), needs a maintainer decision (`ptc:needs-decision`), or rejected by closing it. Do not implement it, and explain the result simply."
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
      target_type: "repository",
      execution_profile: "generic_ephemeral",
      github_access: "read",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "definition"},
      timeout_seconds: 1_800,
      result_type: "daily_digest",
      prompt:
        "Write a concise, easy-to-read daily update from the supplied change manifest. Explain what was added, fixed, changed, or removed and include practical examples when the evidence supports them."
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
        "Fix the pull request's failing CI or merge conflicts, validate and review the repair, then push the existing PR branch. Do not create another PR, merge, or force-push."
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
        "Fix the pull request's failing CI or merge conflicts, validate and review the repair, push the existing branch, wait for required CI, and merge this PR when it is green and mergeable. Do not force-push or work on another PR."
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

  def triggers("daily_digest", repository) do
    enabled = repository.github_name == "ptc_runner"

    [
      %{
        trigger_type: "manual",
        surface: "automations",
        label: "Generate update now",
        enabled: enabled,
        configuration: %{}
      },
      %{
        trigger_type: "schedule",
        surface: "automations",
        label: "Daily at 02:00",
        enabled: enabled,
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
      when key in ["private_issue_analysis", "prepare_issue", "review_issue"] do
    [
      %{
        trigger_type: "contextual",
        surface: "planning_issue",
        label:
          case key do
            "private_issue_analysis" -> "Investigate privately"
            "prepare_issue" -> "Prepare issue"
            "review_issue" -> "Review issue"
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
