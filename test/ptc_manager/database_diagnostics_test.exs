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
            %{
              total_time: System.convert_time_unit(2, :millisecond, :native),
              query_time: System.convert_time_unit(2, :millisecond, :native)
            },
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
    assert log =~ "statement=select"
    assert log =~ "transaction_id="
    refute log =~ "SELECT *"
    refute log =~ "value ="
  end

  test "labels supervised database workloads in their task process" do
    log =
      capture_log(fn ->
        task =
          DatabaseDiagnostics.async_nolink(
            PtcManager.TaskSupervisor,
            "result_reconciliation",
            fn ->
              DatabaseDiagnostics.handle_event(
                [:ptc_manager, :repo, :query],
                %{total_time: System.convert_time_unit(2, :millisecond, :native)},
                %{query: "SELECT secret FROM jobs", source: "jobs", result: {:ok, %{}}},
                nil
              )
            end
          )

        assert Task.await(task) == :ok
      end)

    assert log =~ "result_reconciliation"
    assert log =~ ~s(source="jobs")
    refute log =~ "SELECT secret"
  end

  test "production defaults keep the connection alive beyond the SQLite writer wait" do
    repo_config =
      "config/config.exs"
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:ptc_manager)
      |> Keyword.fetch!(PtcManager.Repo)

    assert repo_config[:write_lock_wait] >= 15_000
    assert repo_config[:queue_target] == repo_config[:write_lock_wait]
    assert repo_config[:queue_interval] <= div(repo_config[:write_lock_wait], 4)
    assert repo_config[:timeout] >= repo_config[:write_lock_wait] * 3 + 5_000
    # A connection holds exqlite's mutex while it waits inside SQLite, so that
    # wait stays a short slice of the writer's wait.
    assert repo_config[:busy_timeout] <= 250
  end

  test "production runtime pairs custom SQLite and connection timeouts" do
    config =
      read_production_runtime(%{
        "PTC_DATABASE_BUSY_TIMEOUT_MS" => "23000",
        "PTC_DATABASE_TIMEOUT_MS" => "74000"
      })

    repo_config = config |> Keyword.fetch!(:ptc_manager) |> Keyword.fetch!(PtcManager.Repo)
    assert repo_config[:write_lock_wait] == 23_000
    assert repo_config[:queue_target] == 23_000
    assert repo_config[:queue_interval] == 2_000
    assert repo_config[:timeout] == 74_000
  end

  test "production runtime uses safe defaults for blank timeout variables" do
    config =
      read_production_runtime(%{
        "PTC_DATABASE_BUSY_TIMEOUT_MS" => "",
        "PTC_DATABASE_TIMEOUT_MS" => ""
      })

    repo_config = config |> Keyword.fetch!(:ptc_manager) |> Keyword.fetch!(PtcManager.Repo)
    assert repo_config[:write_lock_wait] == 15_000
    assert repo_config[:queue_target] == 15_000
    assert repo_config[:queue_interval] == 2_000
    assert repo_config[:timeout] == 50_000
  end

  test "production runtime rejects a connection deadline that cannot honor the writer wait" do
    assert_raise RuntimeError, ~r/must cover DBConnection's doubled queue target/, fn ->
      read_production_runtime(%{
        "PTC_DATABASE_BUSY_TIMEOUT_MS" => "15000",
        "PTC_DATABASE_TIMEOUT_MS" => "49999"
      })
    end
  end

  test "logs a failed writer acquisition without leaving an open transaction" do
    log =
      capture_log(fn ->
        emit_failed_writer_event()

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

  test "reports pool checkout separately from SQLite writer acquisition" do
    log =
      capture_log(fn ->
        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{
            total_time: System.convert_time_unit(7, :millisecond, :native),
            queue_time: System.convert_time_unit(7, :millisecond, :native)
          },
          %{query: "begin", result: {:error, %DBConnection.ConnectionError{message: "busy"}}},
          nil
        )
      end)

    assert log =~ "SQLite pool checkout was slow"
    refute log =~ "SQLite writer acquisition was slow"
  end

  test "reports other open transaction owners when a writer is blocked" do
    parent = self()

    holder =
      spawn(fn ->
        DatabaseDiagnostics.with_context("snapshot_holder", fn ->
          DatabaseDiagnostics.handle_event(
            [:ptc_manager, :repo, :query],
            %{total_time: 0},
            %{query: "begin", result: {:ok, %{command: :begin}}},
            nil
          )

          DatabaseDiagnostics.with_phase("run_reconciliation", fn ->
            send(parent, :holder_started)
            receive do: (:finish -> :ok)
          end)

          DatabaseDiagnostics.handle_event(
            [:ptc_manager, :repo, :query],
            %{total_time: 0},
            %{query: "rollback", result: {:ok, %{command: :rollback}}},
            nil
          )
        end)
      end)

    assert_receive :holder_started

    log =
      capture_log(fn ->
        DatabaseDiagnostics.with_context("blocked_writer", fn ->
          emit_failed_writer_event()
        end)
      end)

    send(holder, :finish)
    assert log =~ "open_transactions="
    assert log =~ "snapshot_holder"
    assert log =~ "run_reconciliation"
    refute log =~ "blocked_writer" <> inspect(holder)
  end

  test "dead transaction owners are removed from diagnostics" do
    owner =
      spawn(fn ->
        DatabaseDiagnostics.handle_event(
          [:ptc_manager, :repo, :query],
          %{total_time: 0},
          %{query: "begin", result: {:ok, %{command: :begin}}},
          nil
        )
      end)

    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    refute Enum.any?(DatabaseDiagnostics.open_transactions(), &(&1.pid == owner))
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

  defp emit_failed_writer_event do
    duration = System.convert_time_unit(5, :millisecond, :native)

    DatabaseDiagnostics.handle_event(
      [:ptc_manager, :repo, :query],
      %{total_time: duration, query_time: duration},
      %{query: "begin", result: {:error, %Exqlite.Error{message: "database is locked"}}},
      nil
    )
  end

  defp read_production_runtime(overrides) do
    required = %{
      "DATABASE_PATH" => "/tmp/ptc-manager-runtime-config-test.db",
      "PTC_MANAGER_PASSWORD" => "runtime-config-password",
      "SECRET_KEY_BASE" => String.duplicate("s", 64)
    }

    environment = Map.merge(required, overrides)
    previous = Map.new(environment, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(environment, fn {name, value} -> System.put_env(name, value) end)
      Config.Reader.read!("config/runtime.exs", env: :prod)
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
