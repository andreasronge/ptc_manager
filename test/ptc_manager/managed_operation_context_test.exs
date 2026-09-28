defmodule PtcManager.ManagedOperationContextTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.ManagedOperationContext
  alias PtcManager.AgentEnvironmentVariables

  defmodule TransientPaneCommand do
    def run(["pane", "run", pane_id, command]) do
      send(Process.get(:managed_context_test_pid), {:pane_run, pane_id, command})
      {:ok, "{}"}
    end

    def run(["pane", "wait-output" | _rest] = args) do
      test_pid = Process.get(:managed_context_test_pid)
      attempt = Process.get(:managed_context_wait_attempt, 0) + 1
      Process.put(:managed_context_wait_attempt, attempt)
      send(test_pid, {:pane_wait, attempt, args})

      if attempt == 1 do
        {:error,
         {:herdr_exit, 1,
          Jason.encode!(%{
            "id" => "cli:pane:wait-output",
            "error" => %{
              "code" => "timeout",
              "message" => "timed out waiting for output match"
            }
          })}}
      else
        {:ok, ~s({"result":{"matched":true}})}
      end
    end

    def run(["pane", "read" | _rest] = args) do
      send(Process.get(:managed_context_test_pid), {:pane_read, args})
      {:ok, ~s({"result":{"text":"shell prompt without the marker"}})}
    end
  end

  defmodule SnapshotRecoveryPaneCommand do
    def run(["pane", "run", pane_id, command]) do
      [context_id] =
        Regex.run(~r/'PTC_OPERATION_CONTEXT_READY' '([^']+)'/, command, capture: :all_but_first)

      Process.put(:managed_context_marker, "PTC_OPERATION_CONTEXT_READY:#{context_id}")
      send(Process.get(:managed_context_test_pid), {:pane_run, pane_id, command})
      {:ok, "{}"}
    end

    def run(["pane", "wait-output" | _rest] = args) do
      send(Process.get(:managed_context_test_pid), {:pane_wait, 1, args})

      {:error,
       {:herdr_exit, 1,
        Jason.encode!(%{
          "id" => "cli:pane:wait-output",
          "error" => %{
            "code" => "timeout",
            "message" => "timed out waiting for output match"
          }
        })}}
    end

    def run(["pane", "read" | _rest] = args) do
      marker = Process.get(:managed_context_marker)
      send(Process.get(:managed_context_test_pid), {:pane_read, args})
      {:ok, Jason.encode!(%{"result" => %{"text" => "#{marker}\\n$"}})}
    end
  end

  defmodule TerminalPaneCommand do
    def run(["pane", "run", _pane_id, _command]), do: {:ok, "{}"}

    def run(["pane", "wait-output" | _rest]) do
      send(Process.get(:managed_context_test_pid), :terminal_wait)

      {:error,
       {:herdr_exit, 1, ~s({"id":"cli:pane:wait-output","error":{"code":"pane_not_found"}})}}
    end

    def run(["pane", "read" | _rest]), do: flunk("pane read must not run")
  end

  defmodule UnusedPaneCommand do
    def run(_args), do: flunk("dispatch must stop before touching the implementation pane")
  end

  setup do
    previous_socket = Application.get_env(:ptc_manager, :resource_operation_socket_path)
    previous_directory = Application.get_env(:ptc_manager, :resource_operation_context_dir)

    directory =
      Path.join(System.tmp_dir!(), "ptc-managed-context-#{System.unique_integer([:positive])}")

    Application.put_env(:ptc_manager, :resource_operation_socket_path, "/tmp/test.sock")
    Application.put_env(:ptc_manager, :resource_operation_context_dir, directory)
    Process.put(:managed_context_test_pid, self())

    on_exit(fn ->
      restore_env(:resource_operation_socket_path, previous_socket)
      restore_env(:resource_operation_context_dir, previous_directory)
      File.rm_rf!(directory)
    end)

    :ok
  end

  test "issued context reserves a higher soft memory limit for verify" do
    assert {:ok, context} =
             ManagedOperationContext.issue(%{
               owner_type: "job",
               owner_id: 1,
               repository_id: 1,
               worker_id: 1,
               pane_id: "verify:pane",
               fencing_token: 1
             })

    assert context.payload["verify_operation_memory_high_bytes"] == 2_577_399_808
    assert context.payload["verify_agent_memory_high_bytes"] == 2_952_790_016
    assert context.payload["operation_memory_max_bytes"] == 2_684_354_560

    assert context.payload["verify_operation_memory_high_bytes"] <
             Application.fetch_env!(:ptc_manager, :verify_agent_memory_high_bytes)

    assert Application.fetch_env!(:ptc_manager, :verify_agent_memory_high_bytes) ==
             2_952_790_016
  end

  test "retries the output wait without rerunning the pane command" do
    assert {:ok, context} =
             ManagedOperationContext.prepare_job(TransientPaneCommand, "w9:p1", job())

    assert_receive {:pane_run, "w9:p1", first_command}
    assert_receive {:pane_wait, 1, first_wait}
    assert_receive {:pane_read, read_args}
    assert_receive {:pane_wait, 2, second_wait}

    assert first_wait == second_wait
    assert Enum.member?(first_wait, "visible")
    assert Enum.member?(read_args, "visible")

    marker = "PTC_OPERATION_CONTEXT_READY:#{context.payload["context_id"]}"
    refute first_command =~ marker
    assert first_command =~ "PTC_OPERATION_CONTEXT_READY"
    assert first_command =~ context.payload["context_id"]
    refute_receive {:pane_run, "w9:p1", _command}
  end

  test "implementation pane command sources a protected environment file without exposing values" do
    repository = repository_fixture()

    {:ok, _variable} =
      AgentEnvironmentVariables.put(
        repository.id,
        %{
          "name" => "OPENROUTER_API_KEY",
          "value" => "secret with ' quotes"
        },
        "maintainer"
      )

    assert {:ok, context} =
             ManagedOperationContext.prepare_job(
               SnapshotRecoveryPaneCommand,
               "environment:pane",
               job(repository.id)
             )

    assert_receive {:pane_run, "environment:pane", command}
    environment_path = Path.rootname(context.path, ".json") <> ".env"

    assert command =~ "set -a && . '#{environment_path}' && set +a"
    refute command =~ "secret with"
    assert File.read!(environment_path) == "OPENROUTER_API_KEY='secret with '\\'' quotes'\n"
    assert {:ok, %{mode: mode}} = File.stat(environment_path)
    assert Bitwise.band(mode, 0o777) == 0o440

    shell =
      ManagedOperationContext.shell_command(context.path, context.payload,
        environment: environment_path
      )

    {output, 0} = System.cmd("sh", ["-c", shell <> " && printf '%s' \"$OPENROUTER_API_KEY\""])
    assert output =~ "secret with ' quotes"
  end

  test "both plain and cgroup commands source the environment before managed exports" do
    environment_path = "/protected/pane.env"
    payload = %{"context_id" => "context-id", "cgroups" => false}

    plain =
      ManagedOperationContext.shell_command("/protected/pane.json", payload,
        environment: environment_path
      )

    assert plain =~ "set -a && . '/protected/pane.env' && set +a && export"

    cgroup =
      ManagedOperationContext.shell_command(
        "/protected/pane.json",
        %{payload | "cgroups" => true},
        environment: environment_path
      )

    assert cgroup =~ "set -a && . '/protected/pane.env' && set +a && export"
    assert cgroup =~ "PTC_CONTEXT_PATH='/protected/pane.json'"
    assert cgroup =~ "PTC_CONTEXT_ID='context-id'"
    assert cgroup =~ "&& . '/usr/local/libexec/ptc-manager-agent-context'"
    refute cgroup =~ "ptc-manager-agent-context' '/protected/pane.json'"
  end

  test "cgroup pane context is passed through exported variables under dash" do
    dash = System.find_executable("dash") || flunk("dash is required for the pane-shell contract")
    directory = Path.join(System.tmp_dir!(), "managed-context-dash-#{System.unique_integer()}")
    context_script = Path.join(directory, "agent-context")
    environment_path = Path.join(directory, "pane.env")
    capture_path = Path.join(directory, "captured")
    previous = Application.get_env(:ptc_manager, :resource_operation_agent_context)

    File.mkdir_p!(directory)

    File.write!(
      context_script,
      """
      [ -z "${1:-}" ] || exit 41
      printf '%s|%s|%s|%s|%s' \
        "$PTC_CONTEXT_PATH" "$PTC_CONTEXT_ID" \
        "$PTC_AGENT_MEMORY_HIGH" "$PTC_AGENT_MEMORY_MAX" \
        "$PTC_OPERATION_WRAPPER" >"$PTC_TEST_CAPTURE"
      """
    )

    File.write!(
      environment_path,
      "PTC_TEST_CAPTURE='#{capture_path}'\nPTC_CONTEXT_ID='untrusted-environment-value'\n"
    )

    Application.put_env(:ptc_manager, :resource_operation_agent_context, context_script)

    on_exit(fn ->
      restore_env(:resource_operation_agent_context, previous)
      File.rm_rf!(directory)
    end)

    command =
      ManagedOperationContext.shell_command(
        "/protected/pane.json",
        %{"context_id" => "trusted-context", "cgroups" => true},
        environment: environment_path
      )

    assert {output, 0} = System.cmd(dash, ["-c", command], stderr_to_stdout: true)
    assert output =~ "PTC_OPERATION_CONTEXT_READY:trusted-context"

    assert File.read!(capture_path) ==
             "/protected/pane.json|trusted-context|2952790016|3221225472|/usr/local/bin/ptc-operation"
  end

  test "an environment-file write failure prevents implementation dispatch" do
    repository = repository_fixture()

    {:ok, _variable} =
      AgentEnvironmentVariables.put(
        repository.id,
        %{"name" => "TOKEN", "value" => "secret"},
        "maintainer"
      )

    digest = :crypto.hash(:sha256, "unwritable:pane") |> Base.url_encode64(padding: false)

    environment_path =
      Path.join(
        Application.fetch_env!(:ptc_manager, :resource_operation_context_dir),
        "pane-#{digest}.env"
      )

    File.mkdir_p!(environment_path)

    assert {:error, {:environment_file_write_failed, _reason}} =
             ManagedOperationContext.prepare_job(
               UnusedPaneCommand,
               "unwritable:pane",
               job(repository.id)
             )
  end

  test "accepts a marker visible in a terminal snapshot after wait-output times out" do
    assert {:ok, context} =
             ManagedOperationContext.prepare_job(SnapshotRecoveryPaneCommand, "w9:p1", job())

    assert Process.get(:managed_context_marker) ==
             "PTC_OPERATION_CONTEXT_READY:#{context.payload["context_id"]}"

    assert_receive {:pane_wait, 1, wait_args}
    assert_receive {:pane_read, read_args}
    assert Enum.member?(wait_args, "visible")
    assert Enum.member?(read_args, "visible")
    refute_receive {:pane_wait, 2, _args}
  end

  test "does not retry a non-timeout Herdr error" do
    assert {:error, {:herdr_exit, 1, output}} =
             ManagedOperationContext.prepare_job(TerminalPaneCommand, "w9:p1", job())

    assert output =~ "pane_not_found"
    assert_receive :terminal_wait
    refute_receive :terminal_wait
  end

  defp job(repository_id \\ 7) do
    %{
      id: 42,
      repository_id: repository_id,
      fencing_token: 3,
      worktree_allocation: %{worker_id: 11}
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
