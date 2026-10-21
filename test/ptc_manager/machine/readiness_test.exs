defmodule PtcManager.Machine.ReadinessTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Machine.{Gate, HelperManifest, Readiness}
  alias PtcManager.{Dispatch, Operations, ResourceOperationBroker}
  alias PtcManager.Operations.Job

  @settings [
    :host_profile,
    :host_readiness,
    :dispatch_enabled,
    :result_reconcile_interval_ms,
    :implementation_agent_publishes_pr,
    :herdr_run_as_user,
    :resource_operation_wrapper,
    :resource_operation_socket_path,
    :resource_operation_context_dir,
    :execution_artifact_root,
    :planning_snapshot_root,
    :daily_digest_bundle_root,
    :tool_inventory_dir,
    :health_snapshot_path,
    :review_helper,
    :worker_agent_login_helper,
    :deployment_trigger_command,
    :github_app_id,
    :github_app_installation_id,
    :github_app_private_key_path,
    :github_push_timeout_binary,
    :github_publish_staging_root
  ]

  setup do
    previous = Map.new(@settings, &{&1, Application.fetch_env(:ptc_manager, &1)})
    report = Readiness.current()

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:ptc_manager, key, value)
        {key, :error} -> Application.delete_env(:ptc_manager, key)
      end)

      :persistent_term.put({Readiness, :report}, report)
    end)

    root = Path.join(System.tmp_dir!(), "ptc-readiness-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: service_root(root)}
  end

  # A macOS service root with every path and helper as a release installs it.
  defp service_root(root) do
    for directory <- ~w(bin run data/operation-contexts data/execution-artifacts
                         data/planning-snapshots data/daily-digest-bundles data/tool-inventory),
        do: File.mkdir_p!(Path.join(root, directory))

    for helper <- Map.keys(HelperManifest.digests()) do
      target = Path.join([root, "bin", helper])
      File.cp!(Path.expand(Path.join("deploy", helper)), target)
      File.chmod!(target, 0o755)
    end

    put(
      host_profile: :macos,
      herdr_run_as_user: nil,
      dispatch_enabled: false,
      resource_operation_wrapper: Path.join(root, "bin/ptc-operation"),
      resource_operation_socket_path: nil,
      resource_operation_context_dir: Path.join(root, "data/operation-contexts"),
      execution_artifact_root: Path.join(root, "data/execution-artifacts"),
      planning_snapshot_root: Path.join(root, "data/planning-snapshots"),
      daily_digest_bundle_root: Path.join(root, "data/daily-digest-bundles"),
      tool_inventory_dir: Path.join(root, "data/tool-inventory"),
      health_snapshot_path: Path.join(root, "data/health.json"),
      review_helper: Path.join(root, "bin/ptc-manager-worker-review"),
      worker_agent_login_helper: Path.join(root, "bin/ptc-manager-worker-agent-login"),
      deployment_trigger_command: Path.join(root, "bin/macos-deploy-host")
    )

    root
  end

  defp put(settings),
    do: Enum.each(settings, fn {k, v} -> Application.put_env(:ptc_manager, k, v) end)

  defp check(key, opts \\ []) do
    Enum.find(
      Readiness.evaluate(Keyword.put_new(opts, :inventory, %{agent_logins: %{}})),
      &(&1.key == key)
    )
  end

  test "a complete macOS service root passes every check", %{root: _root} do
    for check <- Readiness.evaluate(inventory: %{agent_logins: %{}}) do
      assert check.status in [:ok, :skipped], inspect(check)
    end
  end

  test "paths fail when a host path is unusable", %{root: root} do
    assert %{status: :ok} = check(:paths)

    # A root created on first use may be absent; one that must exist may not.
    File.rm_rf!(Path.join(root, "data/daily-digest-bundles"))
    assert %{status: :ok} = check(:paths)
    File.write!(Path.join(root, "data/daily-digest-bundles"), "not a directory")
    assert %{status: :failed, sentence: "daily_digest_bundle_root" <> _} = check(:paths)
    File.rm!(Path.join(root, "data/daily-digest-bundles"))
    File.rm_rf!(Path.join(root, "data/execution-artifacts"))

    assert %{status: :failed, blocking: true, sentence: sentence} = check(:paths)
    assert sentence =~ "execution_artifact_root (PTC_EXECUTION_ARTIFACT_ROOT)"

    put(host_profile: :development)
    assert %{status: :skipped} = check(:paths)
  end

  test "helpers fail when an installed copy differs from this release", %{root: root} do
    assert %{status: :ok} = check(:helpers)
    File.write!(Path.join(root, "bin/macos-deploy-host"), "#!/bin/sh\nexit 0\n")

    assert %{status: :failed, sentence: sentence} = check(:helpers)
    assert sentence =~ "macos-deploy-host differs from the copy packaged in this release"

    put(host_profile: :linux)
    assert %{status: :skipped} = check(:helpers)
  end

  test "the wrapper self-test and the broker ping run when a broker is configured",
       %{root: root} do
    assert %{status: :skipped} = check(:operation_wrapper)
    assert %{status: :skipped} = check(:operation_broker)

    # Short enough for a Unix socket wherever the suite's temporary root is.
    socket = Path.join("/tmp", "ptc-ready-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(socket) end)
    put(resource_operation_socket_path: socket)
    assert %{status: :failed, sentence: sentence} = check(:operation_broker)
    assert sentence =~ "did not answer"

    put(resource_operation_socket_path: "/tmp/" <> String.duplicate("x", 200) <> ".sock")

    assert %{status: :failed, sentence: "The operation broker did not answer" <> _} =
             check(:operation_broker)

    put(resource_operation_socket_path: socket)

    start_supervised!({ResourceOperationBroker, name: :readiness_broker, path: socket})
    assert %{status: :ok} = check(:operation_broker)
    assert %{status: :ok} = check(:operation_wrapper)
    assert File.ls!(Path.join(root, "data/operation-contexts")) == []

    broken = Path.join(root, "bin/broken-wrapper")
    File.write!(broken, "#!/bin/sh\necho no >&2\nexit 3\n")
    File.chmod!(broken, 0o755)
    put(resource_operation_wrapper: broken)

    assert %{status: :failed, sentence: "ptc-operation self-test exited 3: no"} =
             check(:operation_wrapper)
  end

  test "reconciliation is required while dispatching, blocking except on Linux" do
    assert %{status: :skipped} = check(:reconcile)
    put(dispatch_enabled: true, result_reconcile_interval_ms: 0)
    assert %{status: :failed, blocking: true} = check(:reconcile)

    put(host_profile: :linux)
    assert %{status: :failed, blocking: false} = check(:reconcile)

    put(result_reconcile_interval_ms: 10_000)
    assert %{status: :ok} = check(:reconcile)
  end

  test "publication needs its selected mode configured" do
    put(dispatch_enabled: true, result_reconcile_interval_ms: 10_000)
    put(implementation_agent_publishes_pr: false, github_app_id: nil)
    assert %{status: :failed, sentence: sentence} = check(:publication)
    assert sentence =~ "github_app_id"

    put(
      github_app_id: "1",
      github_app_installation_id: "2",
      github_app_private_key_path: "/key.pem",
      github_push_timeout_binary: "/usr/bin/timeout",
      github_publish_staging_root: "/tmp/staging"
    )

    assert %{status: :ok} = check(:publication)

    put(implementation_agent_publishes_pr: true, herdr_run_as_user: "ptc-worker")
    assert %{status: :skipped} = check(:publication)
  end

  test "a signed-out agent kind fails readiness" do
    assert %{status: :ok} =
             check(:agent_login, inventory: %{agent_logins: %{"codex" => "signed_in"}})

    assert %{status: :failed, sentence: "Signed out: claude. Sign in as the agent identity."} =
             check(:agent_login, inventory: %{agent_logins: %{"claude" => "signed_out"}})
  end

  test "a host that is not ready admits nothing and says why on queued jobs" do
    put(host_readiness: true, host_profile: :macos)
    failing = %{key: :reconcile, status: :failed, blocking: true, sentence: "no reconcile"}
    Readiness.put_report(%{checks: [failing], evaluated_at: DateTime.utc_now()})

    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")

    refute Readiness.ready?()
    assert Gate.check(repository) == {:error, :host_not_ready}
    assert Gate.waiting?(:host_not_ready)
    assert repository.id in Gate.unsatisfied_repository_ids()
    assert Gate.blocked_reasons()[repository.id] == :host_not_ready

    assert {:ok, :empty} = Dispatch.run_once()
    queued = Repo.get!(Job, job.id)
    assert queued.state == "queued"
    assert queued.dispatch_blocked_reason == "host_not_ready"
    assert Operations.dispatch_blocked_words(queued) =~ "not ready"

    # The reason is written once and changes only when the gate's does.
    assert Operations.record_dispatch_blocked(%{repository.id => :host_not_ready}) == 0
    assert Operations.record_dispatch_blocked(%{repository.id => :cluster_fenced}) == 1
    assert Repo.get!(Job, job.id).dispatch_blocked_reason == "cluster_fenced"
    assert Operations.record_dispatch_blocked(%{}) == 1
    assert is_nil(Repo.get!(Job, job.id).dispatch_blocked_reason)

    Readiness.put_report(%{checks: [], evaluated_at: DateTime.utc_now()})
    assert Readiness.ready?()
    assert Gate.check(repository) == :ok
  end

  test "a pre-lease error is recorded on the queued job, never after its lease" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")

    assert Operations.record_dispatch_error(job.id, :dispatch_capacity) == 1
    assert Operations.record_dispatch_error(job.id, :dispatch_capacity) == 0
    assert Repo.get!(Job, job.id).dispatch_blocked_reason == ":dispatch_capacity"

    job |> Job.changeset(%{state: "working"}) |> Repo.update!()
    assert Operations.record_dispatch_error(job.id, :worktree_create_failed) == 0
    assert Repo.get!(Job, job.id).dispatch_blocked_reason == ":dispatch_capacity"
  end

  test "cancelling a queued job clears its blocked reason" do
    repository = repository_fixture()
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "maintainer")
    Operations.record_dispatch_error(job.id, :dispatch_capacity)

    assert {:ok, cancelled} = Operations.cancel_queued_job(job.id, "maintainer")
    assert is_nil(cancelled.dispatch_blocked_reason)
  end

  test "identical dispatch failures back off and a change resets the delay" do
    alias PtcManager.Dispatch.Poller
    state = %{task_ref: nil, last_error: nil, delay_ms: nil}

    state = Poller.observe({:error, :busy}, state)
    assert state.delay_ms == 5_000
    state = Poller.observe({:error, :busy}, state)
    assert state.delay_ms == 10_000

    state =
      Enum.reduce(1..6, state, fn _attempt, state -> Poller.observe({:error, :busy}, state) end)

    assert state.delay_ms == 60_000
    state = Poller.observe({:error, :other}, state)
    assert state.delay_ms == 5_000
    state = Poller.observe({:ok, :empty}, state)
    assert {state.last_error, state.delay_ms} == {nil, 5_000}
  end
end
