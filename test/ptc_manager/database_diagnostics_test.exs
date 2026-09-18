defmodule PtcManager.DatabaseDiagnosticsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PtcManager.DatabaseDiagnostics

  setup do
    previous = Application.get_env(:ptc_manager, :database_slow_query_ms)
    Application.put_env(:ptc_manager, :database_slow_query_ms, 0)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ptc_manager, :database_slow_query_ms)
      else
        Application.put_env(:ptc_manager, :database_slow_query_ms, previous)
      end
    end)
  end

  test "logs the workload and bounded timing without SQL text or parameters" do
    log =
      capture_log(fn ->
        DatabaseDiagnostics.with_context("test_workload", fn ->
          DatabaseDiagnostics.handle_event(
            [:ptc_manager, :repo, :query],
            %{total_time: System.convert_time_unit(2, :millisecond, :native)},
            %{query: "begin", result: {:ok, %{command: :begin}}},
            nil
          )

          DatabaseDiagnostics.handle_event(
            [:ptc_manager, :repo, :query],
            %{total_time: System.convert_time_unit(3, :millisecond, :native)},
            %{
              query: "SELECT * FROM secrets WHERE value = ?",
              source: "secrets",
              result: {:ok, %{command: :select}}
            },
            nil
          )

          DatabaseDiagnostics.handle_event(
            [:ptc_manager, :repo, :query],
            %{total_time: 0},
            %{query: "commit", result: {:ok, %{command: :commit}}},
            nil
          )
        end)
      end)

    assert log =~ "SQLite writer acquisition was slow"
    assert log =~ "SQLite query was slow"
    assert log =~ "SQLite transaction was slow"
    assert log =~ "test_workload"
    assert log =~ ~s(source="secrets")
    refute log =~ "SELECT *"
    refute log =~ "value ="
  end

  test "logs a failed writer acquisition without leaving an open transaction" do
    log =
      capture_log(fn ->
        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: System.convert_time_unit(5, :millisecond, :native)},
          %{query: "begin", result: {:error, %Exqlite.Error{message: "database is locked"}}},
          nil
        )

        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "rollback", result: {:ok, %{command: :rollback}}},
          nil
        )
      end)

    assert log =~ "SQLite writer acquisition was slow"
    assert log =~ "Exqlite.Error"
    refute log =~ "SQLite transaction was slow"
  end

  test "a nested transaction preserves the outer transaction duration" do
    log =
      capture_log(fn ->
        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "begin", result: {:ok, %{command: :begin}}},
          nil
        )

        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "begin", result: {:ok, %{command: :begin}}},
          nil
        )

        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "commit", result: {:ok, %{command: :commit}}},
          nil
        )

        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "commit", result: {:ok, %{command: :commit}}},
          nil
        )
      end)

    assert log =~ "SQLite transaction was slow"
    assert length(Regex.scan(~r/SQLite transaction was slow/, log)) == 1
  end
end
