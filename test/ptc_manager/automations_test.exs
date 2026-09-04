defmodule PtcManager.AutomationsTest do
  use PtcManager.DataCase, async: false

  import PtcManager.OperationsFixtures

  alias PtcManager.Automations
  alias PtcManager.Automations.{DefinitionVersion, Invocation, Trigger}
  alias PtcManager.MaintainerActions
  alias PtcManager.Repo

  defmodule GitTrustCommand do
    def git_command(_args), do: {"", 0}
  end

  defmodule ClaudeTrustCommand do
    def trust_command(args) do
      send(
        Application.fetch_env!(:ptc_manager, :worker_claude_trust_test_pid),
        {:claude_trust, args}
      )

      {"", 0}
    end
  end

  defmodule GenericHerdrCommand do
    def run(args, _timeout \\ nil) do
      cond do
        Enum.take(args, 2) == ["worktree", "open"] ->
          workspace_path = Enum.at(args, Enum.find_index(args, &(&1 == "--cwd")) + 1)
          Process.put({__MODULE__, :workspace_path}, workspace_path)

          {:ok,
           Jason.encode!(%{
             "result" => %{
               "workspace" => %{"workspace_id" => "generic-workspace"},
               "root_pane" => %{"pane_id" => "generic-pane"}
             }
           })}

        Enum.take(args, 2) == ["agent", "start"] ->
          workspace_path = Process.get({__MODULE__, :workspace_path})
          false = Enum.any?(args, &String.contains?(&1, "{{workspace_path"))
          true = workspace_path in args
          true = ~s("#{workspace_path}") in args

          {:ok,
           Jason.encode!(%{
             "result" => %{"agent" => %{"agent_session" => %{"value" => "generic-session"}}}
           })}

        Enum.take(args, 2) == ["agent", "prompt"] ->
          true = option_values(args, "--until") == ["working", "blocked"]
          prompt = Enum.at(args, 3)
          prepare_prompt_result(prompt)

          if String.starts_with?(prompt, "Read and follow the complete task") do
            {:error,
             {:herdr_exit, 1,
              ~s({"error":{"code":"agent_prompt_stalled","message":"agent prompt produced no observed state change within 5000 ms; status is idle and state_change_seq remained 40"},"id":"cli:agent:prompt"})}}
          else
            {:ok, ~s({"result":{"state":"working"}})}
          end

        Enum.take(args, 2) == ["agent", "get"] ->
          {:ok, ~s({"result":{"agent":{"agent_status":"working","state_change_seq":41}}})}

        Enum.take(args, 2) == ["agent", "wait"] ->
          true = option_values(args, "--until") == ["idle", "done", "blocked"]
          complete_prompt_result()
          {:ok, ~s({"result":{"state":"idle"}})}

        Enum.take(args, 2) == ["workspace", "close"] ->
          {:ok, "{}"}

        true ->
          {:error, {:unexpected_command, args}}
      end
    end

    defp result do
      %{
        "outcome" => "no-changes",
        "private_summary" => "No repository change was needed.",
        "why_it_matters" => "The configured check completed.",
        "scope" => "small",
        "risk" => "low",
        "technical_evidence" => "The invented test agent inspected the fixture.",
        "github_changes" => [],
        "evidence" => ["contract-test"],
        "decision_question" => "",
        "decision_options" => [],
        "created_issue_numbers" => [],
        "suggestions" => []
      }
    end

    defp assert_schema!(path) do
      body = File.read!(path)
      true = body =~ ~s("private_summary")
      :ok
    end

    defp option_values(args, option) do
      args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        [^option, value] -> [value]
        _pair -> []
      end)
    end

    defp prepare_prompt_result("Initialization check only." <> _rest = prompt) do
      attempt = Process.get({__MODULE__, :ready_attempt}, 0) + 1
      Process.put({__MODULE__, :ready_attempt}, attempt)

      if attempt == 1 do
        Process.put({__MODULE__, :pending_prompt_result}, :swallowed)
      else
        [token] = Regex.run(~r/exactly (ready-\d+-\d+)/, prompt, capture: :all_but_first)
        [path] = Regex.run(~r/rename it to (\/\S+?\.ready)\./, prompt, capture: :all_but_first)
        Process.put({__MODULE__, :pending_prompt_result}, {:ready, path, token})
      end
    end

    defp prepare_prompt_result(loader) do
      [prompt_path] = Regex.run(~r/task at (.+?\.txt)\./, loader, capture: :all_but_first)
      prompt = File.read!(prompt_path)
      [path] = Regex.run(~r/to (\/\S+?\.json)\b/, prompt, capture: :all_but_first)
      [schema] = Regex.run(~r/read (\/\S+?\.schema\.json)\b/, prompt, capture: :all_but_first)
      assert_schema!(schema)
      true = byte_size(loader) < 500
      true = prompt =~ String.duplicate("Long context line.\n", 100)
      Process.put({__MODULE__, :pending_prompt_result}, {:result, path})
    end

    defp complete_prompt_result do
      case Process.delete({__MODULE__, :pending_prompt_result}) do
        :swallowed ->
          :ok

        {:ready, path, token} ->
          File.write!(path, token <> "\n")

        {:result, path} ->
          false = File.exists?(path)
          temporary_path = path <> ".tmp"
          File.write!(temporary_path, Jason.encode!(result()))
          File.rename!(temporary_path, path)
      end
    end
  end

  test "new repositories receive versioned built-in definitions idempotently" do
    repository = repository_fixture()

    definitions = Automations.list_definitions(repository)
    assert length(definitions) == 11
    assert Enum.all?(definitions, &match?(%DefinitionVersion{version: 1}, &1.current_version))

    assert Enum.all?(definitions, fn definition ->
             definition.current_version.prompt =~
               "#{repository.github_owner}/#{repository.github_name}"
           end)

    assert :ok = Automations.ensure_defaults(repository)
    assert length(Automations.list_definitions(repository)) == 11
  end

  test "editing an action creates an immutable version used only by future actions" do
    repository = repository_fixture()
    issue = issue_fixture(repository)

    assert {:ok, first} = MaintainerActions.enqueue("prepare_issue", issue.id, "maintainer")
    definition = Automations.get_definition(repository, "prepare_issue")
    first_version = definition.current_version

    attrs =
      first_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :agent_selector,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, "Use a shorter maintainer explanation for future runs.")

    assert {:ok, second_version} = Automations.create_version(definition, attrs, "maintainer")
    assert second_version.version == 2
    assert Repo.get!(DefinitionVersion, first_version.id).prompt == first_version.prompt

    first = Repo.get!(PtcManager.Operations.AgentAction, first.id)
    assert first.automation_definition_version_id == first_version.id

    first
    |> PtcManager.Operations.AgentAction.changeset(%{state: "done", ended_at: DateTime.utc_now()})
    |> Repo.update!()

    assert {:ok, second} = MaintainerActions.enqueue("prepare_issue", issue.id, "maintainer")
    assert second.automation_definition_version_id == second_version.id
    assert second.prompt =~ "Use a shorter maintainer explanation for future runs."
    refute first.prompt =~ "Use a shorter maintainer explanation for future runs."
  end

  test "the built-in implementation prompt asks for the follow-up label" do
    repository = repository_fixture()
    definition = Automations.get_definition(repository, "implement_issue")

    assert definition.current_version.created_by == "system:built-in"

    assert definition.current_version.prompt =~
             "add the label `ptc:follow-up` to the pull request"
  end

  test "implementation approval freezes its user-owned prompt" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)

    definition = Automations.get_definition(repository, "implement_issue")
    current = definition.current_version

    attrs =
      current
      |> version_attrs()
      |> Map.put(
        :prompt,
        "Use this repository's normal pull-request policy. Keep the implementation change tightly scoped."
      )

    assert {:ok, configured} = Automations.create_version(definition, attrs, "maintainer")

    assert {:ok, job} = PtcManager.Operations.approve_issue(issue.id, "maintainer")
    assert job.automation_definition_version_id == configured.id
    assert job.prompt_instructions =~ "Use this repository's normal pull-request policy."
    assert job.prompt_instructions =~ "Keep the implementation change tightly scoped."

    later_attrs = Map.put(attrs, :prompt, "This later edit must not alter approved work.")
    assert {:ok, _later} = Automations.create_version(definition, later_attrs, "maintainer")

    frozen = Repo.get!(PtcManager.Operations.Job, job.id).prompt_instructions
    assert frozen =~ "Keep the implementation change tightly scoped."
    refute frozen =~ "This later edit must not alter approved work."
  end

  defp version_attrs(version) do
    version
    |> Map.from_struct()
    |> Map.take([
      :target_type,
      :execution_profile,
      :agent_selector,
      :github_access,
      :queue_lane,
      :resource_class,
      :lock_policy,
      :timeout_seconds,
      :result_type,
      :result_protocol_version,
      :prompt,
      :configuration_snapshot
    ])
  end

  test "repository defaults include disabled schedules where updates are not relevant" do
    runner = repository_fixture(%{github_name: "ptc_runner"})
    manager = repository_fixture(%{github_name: "ptc_manager"})

    runner_digest = Automations.get_definition(runner, "daily_digest")
    manager_digest = Automations.get_definition(manager, "daily_digest")

    assert Enum.any?(runner_digest.triggers, &(&1.trigger_type == "schedule" and &1.enabled))
    refute Enum.any?(manager_digest.triggers, &(&1.trigger_type == "schedule" and &1.enabled))
    assert Enum.any?(runner_digest.triggers, &(&1.trigger_type == "manual" and &1.enabled))
    refute Enum.any?(manager_digest.triggers, &(&1.trigger_type == "manual" and &1.enabled))
  end

  test "a definition may hold several schedules and the bootstrap recognises the built-in one by its marker" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "daily_digest")
    built_in = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
    assert built_in.configuration == %{"built_in" => true}
    assert Automations.default_trigger?(definition, built_in)

    assert {:ok, renamed} =
             Automations.update_trigger(built_in, %{label: "Renamed by the maintainer"})

    assert {:ok, extra} =
             Automations.create_trigger(
               definition,
               PtcManager.Automations.Schedule.new_trigger_attrs()
             )

    refute Automations.default_trigger?(definition, extra)

    assert :ok = Automations.ensure_defaults(repository)

    schedules =
      Automations.get_definition(repository, "daily_digest").triggers
      |> Enum.filter(&(&1.trigger_type == "schedule"))

    assert Enum.map(schedules, & &1.id) |> Enum.sort() == Enum.sort([renamed.id, extra.id])

    assert {:ok, _deleted} = Automations.delete_trigger(extra)

    assert Automations.trigger_summary(Automations.get_definition(repository, "daily_digest")) ==
             "Every day at 02:00 · Run now"

    assert Automations.slug_key(repository, "Daily digest") == "daily_digest_2"
    assert Automations.slug_key(repository, "2 Fast & Furious") == "automation_2_fast_furious"
  end

  test "manual repository actions create one immutable invocation per occurrence" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    trigger = Enum.find(definition.triggers, &(&1.trigger_type == "manual"))

    assert {:ok, invocation} =
             Automations.run_trigger(trigger, "maintainer", occurrence_key: "manual:test-1")

    assert invocation.automation_definition_version_id == definition.current_version.id
    assert invocation.agent_action_id
    assert invocation.occurrence_key == "manual:test-1"

    [queued_action] = PtcManager.Operations.list_queued_agent_actions()
    assert queued_action.id == invocation.agent_action_id
    assert queued_action.automation_definition_version.queue_lane == "planning"
    assert PtcManager.Operations.planning_agent_action?(queued_action)

    assert {:ok, same} =
             Automations.run_trigger(trigger, "maintainer", occurrence_key: "manual:test-1")

    assert same.id == invocation.id
    assert Repo.aggregate(Invocation, :count) == 1
  end

  test "schedule tick materializes a due occurrence and advances the trigger" do
    repository = repository_fixture(%{github_name: "ptc_runner"})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")
    schedule = Enum.find(definition.triggers, &(&1.trigger_type == "schedule"))
    due = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    schedule =
      schedule
      |> Trigger.changeset(%{enabled: true, next_run_at: due})
      |> Repo.update!()

    assert :ok = PtcManager.Automations.ScheduleTickWorker.perform(%Oban.Job{})
    invocation = Repo.one!(Invocation)
    assert invocation.automation_trigger_id == schedule.id
    assert invocation.occurrence_key == DateTime.to_iso8601(due)

    advanced = Repo.get!(Trigger, schedule.id)
    assert DateTime.compare(advanced.next_run_at, due) == :gt
  end

  test "an invented Herdr kind completes the generic result contract without model-specific code" do
    previous_dispatch = Application.get_env(:ptc_manager, :dispatch_enabled)
    previous_command = Application.get_env(:ptc_manager, :generic_herdr_command)
    previous_profiles = Application.get_env(:ptc_manager, :agent_profiles)

    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :generic_herdr_command, GenericHerdrCommand)

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "test-maintainer" => %{
        "enabled" => true,
        "args" => ["--fixture", "{{workspace_path}}", "{{workspace_path_toml}}"]
      }
    })

    on_exit(fn ->
      Application.put_env(:ptc_manager, :dispatch_enabled, previous_dispatch)
      Application.put_env(:ptc_manager, :generic_herdr_command, previous_command)
      Application.put_env(:ptc_manager, :agent_profiles, previous_profiles)
    end)

    repository = repository_fixture(%{github_name: "ptc_runner", local_path: System.tmp_dir!()})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")

    attrs =
      definition.current_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, String.duplicate("Long context line.\n", 1_000))
      |> Map.put(:agent_selector, %{
        "mode" => "require",
        "preferred_kind" => "test-maintainer",
        "required_capabilities" => []
      })

    assert {:ok, version} = Automations.create_version(definition, attrs, "test")
    trigger = Automations.get_definition(repository, definition.key).triggers |> hd()
    assert {:ok, invocation} = Automations.run_trigger(trigger, "maintainer")

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    incarnation = PtcManager.RuntimeIncarnation.current()

    assert {:ok, _worker} =
             PtcManager.Operations.create_worker(%{
               worker_key: "herdr:default",
               name: "Herdr default",
               status: "online",
               capabilities: %{"herdr" => true},
               last_heartbeat_at: now,
               worker_incarnation_id: "worker-test",
               herdr_incarnation_id: "herdr-test",
               coordinator_incarnation_id: incarnation
             })

    assert {:ok, {action, _token}} =
             PtcManager.Operations.claim_agent_action(invocation.agent_action_id)

    assert action.automation_definition_version_id == version.id

    assert {:ok, %{"outcome" => "no-changes"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    invocation = Repo.get!(Invocation, invocation.id)
    assert invocation.selected_agent_kind == "test-maintainer"
    assert invocation.selected_agent_name == "automation_a#{action.id}_f1"

    [run] = PtcManager.Operations.list_active_agent_runs()
    assert run.agent_name == invocation.selected_agent_name
    assert run.herdr_workspace == "generic-workspace"
  end

  test "a Claude profile trusts the snapshot for the worker before starting and revokes it after" do
    keys = [
      :dispatch_enabled,
      :generic_herdr_command,
      :agent_profiles,
      :herdr_run_as_user,
      :worktree_root,
      :worker_repository_trust_command,
      :worker_claude_trust_command,
      :worker_claude_trust_test_pid
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :generic_herdr_command, GenericHerdrCommand)
    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :worker_repository_trust_command, GitTrustCommand)
    # The fixture repository is the temporary directory itself, so its parent
    # plays the managed root that makes the workspace eligible for trust.
    Application.put_env(
      :ptc_manager,
      :worktree_root,
      System.tmp_dir!() |> Path.expand() |> Path.dirname()
    )

    Application.put_env(:ptc_manager, :worker_claude_trust_command, ClaudeTrustCommand)
    Application.put_env(:ptc_manager, :worker_claude_trust_test_pid, self())

    Application.put_env(:ptc_manager, :agent_profiles, %{
      "claude" => %{
        "enabled" => true,
        "args" => [
          "--dangerously-skip-permissions",
          "{{workspace_path}}",
          "{{workspace_path_toml}}"
        ]
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    repository = repository_fixture(%{github_name: "ptc_runner", local_path: System.tmp_dir!()})
    definition = Automations.get_definition(repository, "nightly_ci_investigation")

    attrs =
      definition.current_version
      |> Map.from_struct()
      |> Map.take([
        :target_type,
        :execution_profile,
        :github_access,
        :queue_lane,
        :resource_class,
        :lock_policy,
        :timeout_seconds,
        :result_type,
        :result_protocol_version,
        :prompt,
        :configuration_snapshot
      ])
      |> Map.put(:prompt, String.duplicate("Long context line.\n", 1_000))
      |> Map.put(:agent_selector, %{
        "mode" => "require",
        "preferred_kind" => "claude",
        "required_capabilities" => []
      })

    assert {:ok, _version} = Automations.create_version(definition, attrs, "test")
    trigger = Automations.get_definition(repository, definition.key).triggers |> hd()
    assert {:ok, invocation} = Automations.run_trigger(trigger, "maintainer")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, _worker} =
             PtcManager.Operations.create_worker(%{
               worker_key: "herdr:default",
               name: "Herdr default",
               status: "online",
               capabilities: %{"herdr" => true},
               last_heartbeat_at: now,
               worker_incarnation_id: "worker-test",
               herdr_incarnation_id: "herdr-test",
               coordinator_incarnation_id: PtcManager.RuntimeIncarnation.current()
             })

    assert {:ok, {action, _token}} =
             PtcManager.Operations.claim_agent_action(invocation.agent_action_id)

    assert {:ok, %{"outcome" => "no-changes"}} =
             PtcManager.MaintainerActions.GenericHerdrAdapter.run(action)

    workspace_path = Process.get({GenericHerdrCommand, :workspace_path})
    assert is_binary(workspace_path)
    assert_receive {:claude_trust, ["allow", ^workspace_path]}
    assert_receive {:claude_trust, ["revoke", ^workspace_path]}
    assert Repo.get!(Invocation, invocation.id).selected_agent_kind == "claude"
  end

  test "agent profile workspace placeholders preserve one argument and quote TOML paths" do
    assert ["--cwd=/tmp/a b", ~s(projects={"/tmp/a b"={trust_level="trusted"}})] ==
             PtcManager.MaintainerActions.GenericHerdrAdapter.expand_agent_args(
               [
                 "--cwd={{workspace_path}}",
                 ~s(projects={{{workspace_path_toml}}={trust_level="trusted"}})
               ],
               "/tmp/a b"
             )
  end
end
