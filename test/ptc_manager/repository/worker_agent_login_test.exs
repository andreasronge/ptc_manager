defmodule PtcManager.Repository.WorkerAgentLoginTest do
  use ExUnit.Case, async: false

  alias PtcManager.Repository.WorkerAgentLogin

  @project_root Path.expand("../../..", __DIR__)
  @helper Path.join(@project_root, "deploy/ptc-manager-worker-agent-login")

  defmodule LoginCommand do
    def login_command(args) do
      send(Application.fetch_env!(:ptc_manager, :worker_agent_login_test_pid), {:login, args})
      Application.get_env(:ptc_manager, :worker_agent_login_test_result, {"", 0})
    end
  end

  setup do
    keys = [
      :herdr_run_as_user,
      :worker_agent_login_command,
      :worker_agent_login_test_pid,
      :worker_agent_login_test_result
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :herdr_run_as_user, "ptc-manager-worker")
    Application.put_env(:ptc_manager, :worker_agent_login_command, LoginCommand)
    Application.put_env(:ptc_manager, :worker_agent_login_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    :ok
  end

  test "a signed-in kind starts" do
    assert :ok = WorkerAgentLogin.verify("claude")
    assert_receive {:login, ["claude"]}
  end

  # The failure this exists for. A signed-out CLI starts, prints its login
  # prompt and waits for nobody, so the run has to be refused before the pane
  # exists rather than timed out an hour later.
  test "a signed-out kind is refused and named" do
    Application.put_env(:ptc_manager, :worker_agent_login_test_result, {"", 3})

    assert {:error, {:agent_signed_out, "claude"}} = WorkerAgentLogin.verify("claude")
  end

  test "a wrapper that fails for another reason is not reported as signed out" do
    Application.put_env(:ptc_manager, :worker_agent_login_test_result, {"broken", 2})

    assert {:error, {:worker_agent_login_failed, "claude", 2, "broken"}} =
             WorkerAgentLogin.verify("claude")
  end

  test "a kind with no login of its own asks nothing" do
    assert :ok = WorkerAgentLogin.verify("unknown-kind")
    refute_receive {:login, _args}
  end

  # A development machine starts no managed pane, so it must never shell out to
  # a helper that only exists on the worker.
  test "a machine that is not the worker boundary asks nothing" do
    Application.delete_env(:ptc_manager, :herdr_run_as_user)

    assert :ok = WorkerAgentLogin.verify("claude")
    refute_receive {:login, _args}
  end

  test "the helper parses as POSIX shell and refuses an unknown kind" do
    assert {"", 0} = System.cmd("sh", ["-n", @helper], stderr_to_stdout: true)

    assert {output, 2} = System.cmd("sh", [@helper, "nonsense"], stderr_to_stdout: true)
    assert output =~ "unknown agent kind: nonsense"

    assert {usage, 2} = System.cmd("sh", [@helper], stderr_to_stdout: true)
    assert usage =~ "expected one agent kind"
  end
end
