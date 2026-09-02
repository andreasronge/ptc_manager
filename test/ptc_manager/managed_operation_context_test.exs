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
  end

  defmodule TerminalPaneCommand do
    def run(["pane", "run", _pane_id, _command]), do: {:ok, "{}"}

    def run(["pane", "wait-output" | _rest]) do
      send(Process.get(:managed_context_test_pid), :terminal_wait)

      {:error,
       {:herdr_exit, 1, ~s({"id":"cli:pane:wait-output","error":{"code":"pane_not_found"}})}}
    end
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

  test "retries an idempotent pane handshake after Herdr misses the first marker" do
    assert {:ok, context} =
             ManagedOperationContext.prepare_job(TransientPaneCommand, "w9:p1", job())

    assert_receive {:pane_run, "w9:p1", first_command}
    assert_receive {:pane_wait, 1, first_wait}
    assert_receive {:pane_run, "w9:p1", second_command}
    assert_receive {:pane_wait, 2, second_wait}

    assert first_command == second_command
    assert first_wait == second_wait
    assert first_command =~ "PTC_OPERATION_CONTEXT_READY:#{context.payload["context_id"]}"
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
