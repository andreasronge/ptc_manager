defmodule PtcManager.ManagedOperationContextTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.ManagedOperationContext

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

  defp job do
    %{
      id: 42,
      repository_id: 7,
      fencing_token: 3,
      worktree_allocation: %{worker_id: 11}
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
