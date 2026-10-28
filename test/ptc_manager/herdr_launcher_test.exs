defmodule PtcManager.HerdrLauncherTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)
  @script Path.join(@project_root, "deploy/launchd/run-herdr.example")

  setup do
    root = Path.join(System.tmp_dir!(), "ptc-run-herdr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # Agent panes inherit the Herdr server's environment. A pane that sees the
  # console's operation socket path starts a second broker in its own test run
  # and unlinks the live socket; one that sees its secrets can sign as it.
  test "the Herdr server does not inherit the console's environment", %{root: root} do
    seen = Path.join(root, "environment")
    herdr = Path.join(root, "herdr")
    File.write!(herdr, "#!/bin/sh\necho \"$@\" > #{seen}.args\nenv > #{seen}\n")
    File.chmod!(herdr, 0o755)

    env_file = Path.join(root, "manager.env")

    File.write!(env_file, """
    export PTC_HERDR_BINARY=#{herdr}
    export PTC_HERDR_SESSION=default
    export PTC_OPERATION_SOCKET_PATH=#{root}/operations.sock
    export PTC_CLUSTER_SECRET=cluster-secret
    export PTC_MANAGER_PASSWORD=manager-password
    export SECRET_KEY_BASE=secret-key-base
    """)

    assert {_output, 0} =
             System.cmd("/bin/sh", [@script],
               env: [
                 {"PTC_MANAGER_ENV_FILE", env_file},
                 {"HOME", root},
                 {"PATH", "/usr/bin:/bin"}
               ]
             )

    assert File.read!(seen <> ".args") == "--session default server\n"

    environment = File.read!(seen)
    assert environment =~ "HOME=#{root}\n"
    assert environment =~ "PATH=/usr/bin:/bin\n"
    refute environment =~ "PTC_"
    refute environment =~ "secret"
    refute environment =~ "password"
  end
end
