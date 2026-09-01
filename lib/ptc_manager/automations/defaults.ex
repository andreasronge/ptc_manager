defmodule PtcManager.Automations.Defaults do
  @moduledoc "Built-in automation definitions used to preserve the current workflows."

  @common %{
    agent_selector: %{"mode" => "any", "required_capabilities" => []},
    result_protocol_version: 1,
    operational_policy:
      "Follow the coordinator-supplied target, authorization, and safety boundaries.",
    prompt: "Use the code-owned target prompt builder for this compatibility definition.",
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
      result_type: "private_issue_analysis"
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
      result_type: "implementation"
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
      result_type: "issue_maintenance"
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
      result_type: "issue_maintenance"
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
      result_type: "issue_maintenance"
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
      result_type: "daily_digest"
    },
    %{
      key: "prepare_merge_decision",
      name: "Prepare merge decision",
      description: "Produce a private summary for an exact pull-request version.",
      target_type: "pull_request",
      execution_profile: "generic_ephemeral",
      github_access: "read",
      queue_lane: "planning",
      resource_class: "light",
      lock_policy: %{"type" => "target"},
      timeout_seconds: 1_800,
      result_type: "merge_decision"
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
      result_type: "pull_request_repair"
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
      result_type: "pull_request_repair"
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
      result_type: "retrospective"
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
      result_type: "github_issue_change"
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
      Inspect the latest completed nightly GitHub Actions workflow for this repository. If it succeeded, report that no action was needed. If it failed, inspect bounded logs, search open and closed issues for the supplied stable occurrence marker, and create or update exactly one GitHub issue describing the failure, evidence, and a useful next step. Never create a duplicate for the same workflow run. Return a concise private Markdown report and every GitHub URL changed.
      """
    }
  ]

  def all, do: Enum.map(@definitions, &Map.merge(@common, &1))
  def get(key), do: Enum.find(all(), &(&1.key == key))

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

  def triggers(key, _repository) when key in ["prepare_issue", "review_issue"] do
    [
      %{
        trigger_type: "contextual",
        surface: "planning_issue",
        label: if(key == "prepare_issue", do: "Prepare issue", else: "Review issue"),
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

  def triggers("prepare_merge_decision", _repository) do
    [
      %{
        trigger_type: "contextual",
        surface: "delivery_pr",
        label: "Prepare merge decision",
        enabled: true,
        configuration: %{}
      }
    ]
  end

  def triggers(_key, _repository), do: []
end
