defmodule PtcManager.MacOSRuntimeTest do
  use ExUnit.Case, async: false
  @moduletag skip: :os.type() != {:unix, :darwin}

  test "macOS host commands override production Linux defaults" do
    env = %{
      "PTC_MACOS_SERVICE_ROOT" => "/tmp/ptc-macos-runtime",
      "PTC_MANAGER_PASSWORD" => "runtime-test-password",
      "DATABASE_PATH" => "/tmp/runtime-test.db",
      "SECRET_KEY_BASE" => String.duplicate("a", 64)
    }

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(env)
    config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
    host = "/tmp/ptc-macos-runtime/bin/macos-deploy-host"
    assert config[:deployment_trigger_command] == host
    assert config[:deployment_status_command] == host
    assert config[:deployment_trigger_args] == ["trigger", "/tmp/ptc-macos-runtime"]
    assert config[:host_profile] == :macos

    # Every host path stays under the service root, not /usr/local or /var/lib.
    for {key, relative} <- [
          resource_operation_wrapper: "bin/ptc-operation",
          resource_operation_socket_path: "run/operations.sock",
          resource_operation_context_dir: "data/operation-contexts",
          execution_artifact_root: "data/execution-artifacts",
          planning_snapshot_root: "data/planning-snapshots",
          daily_digest_bundle_root: "data/daily-digest-bundles",
          tool_inventory_dir: "data/tool-inventory",
          health_snapshot_path: "data/health.json"
        ] do
      assert config[key] == Path.join("/tmp/ptc-macos-runtime", relative), inspect(key)
    end

    assert config[:resource_operation_cgroups] == false
  end

  test "a dispatching macOS host reconciles finished jobs by default" do
    with_environment(%{"PTC_DISPATCH_ENABLED" => "true"}, fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
      assert config[:result_reconcile_interval_ms] == 10_000
    end)

    with_environment(
      %{"PTC_DISPATCH_ENABLED" => "true", "PTC_RESULT_RECONCILE_INTERVAL_MS" => "0"},
      fn ->
        config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
        assert config[:result_reconcile_interval_ms] == 0
      end
    )

    with_environment(%{"PTC_DISPATCH_ENABLED" => nil}, fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
      assert config[:result_reconcile_interval_ms] == 0
    end)
  end

  test "importing external pull requests follows PR reconciliation unless set" do
    for {pr, external, expected} <- [
          {"true", nil, true},
          {"true", "false", false},
          {"false", nil, false},
          {"false", "true", false}
        ] do
      with_environment(
        %{"PTC_PR_RECONCILE_ENABLED" => pr, "PTC_EXTERNAL_PR_RECONCILE_ENABLED" => external},
        fn ->
          config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
          assert config[:external_pr_reconcile_enabled] == expected, inspect({pr, external})
        end
      )
    end
  end

  test "an explicit environment variable still wins over the service root" do
    with_environment(%{"PTC_OPERATION_SOCKET_PATH" => "/tmp/elsewhere.sock"}, fn ->
      config = Config.Reader.read!("config/runtime.exs", env: :prod)[:ptc_manager]
      assert config[:resource_operation_socket_path] == "/tmp/elsewhere.sock"
    end)
  end

  test "a macOS release refuses settings it cannot honour" do
    for {overrides, message} <- [
          {%{"PTC_MACOS_SERVICE_ROOT" => nil}, ~r/needs PTC_MACOS_SERVICE_ROOT/},
          {%{"PTC_MACOS_SERVICE_ROOT" => "relative/root"}, ~r/needs PTC_MACOS_SERVICE_ROOT/},
          {%{"PTC_HERDR_RUN_AS_USER" => "worker"}, ~r/PTC_HERDR_RUN_AS_USER is not supported/},
          {%{"PTC_OPERATION_CGROUPS" => "true"}, ~r/PTC_OPERATION_CGROUPS=true is not supported/}
        ] do
      with_environment(overrides, fn ->
        assert_raise RuntimeError, message, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end
      end)
    end
  end

  defp with_environment(overrides, fun) do
    env =
      Map.merge(
        %{
          "PTC_MACOS_SERVICE_ROOT" => "/tmp/ptc-macos-runtime",
          "PTC_MANAGER_PASSWORD" => "runtime-test-password",
          "DATABASE_PATH" => "/tmp/runtime-test.db",
          "SECRET_KEY_BASE" => String.duplicate("a", 64)
        },
        overrides
      )

    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)

    try do
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
