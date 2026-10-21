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
    # Session archives and operation logs stay under the service root, not /var/lib.
    assert config[:execution_artifact_root] == "/tmp/ptc-macos-runtime/data/execution-artifacts"
  end
end
