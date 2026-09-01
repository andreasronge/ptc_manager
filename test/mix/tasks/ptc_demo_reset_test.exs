defmodule Mix.Tasks.Ptc.Demo.ResetTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Ptc.Demo.Reset

  test "accepts only the dedicated repository-local demo database" do
    expected = Path.join([File.cwd!(), "tmp", "ptc_manager_demo.db"])

    assert Reset.safe_demo_database?(expected)
    refute Reset.safe_demo_database?(Path.join(File.cwd!(), "ptc_manager_dev.db"))
    refute Reset.safe_demo_database?("/tmp/ptc_manager_demo.db")
    refute Reset.safe_demo_database?(nil)
  end

  test "detects an open demo database when lsof reports a process" do
    database = temporary_database!()
    File.touch!(database)

    runner = fn _command, args, _opts ->
      assert args == ["-t", "--", database]
      {"12345\n", 0}
    end

    assert Reset.database_status(database, runner, "/usr/bin/lsof") == :in_use
  end

  test "treats a missing demo database as a safe first run without invoking lsof" do
    database = temporary_database!()

    runner = fn _command, _args, _opts ->
      flunk("lsof must not run when no database files exist")
    end

    assert Reset.database_status(database, runner, nil) == :available
  end

  test "refuses to guess when the open-database probe is unavailable or fails" do
    database = temporary_database!()
    File.touch!(database)

    assert Reset.database_status(database, fn _, _, _ -> flunk() end, nil) ==
             {:error, "lsof is not installed"}

    assert {:error, "lsof exited with status 2:" <> _rest} =
             Reset.database_status(
               database,
               fn _, _, _ -> {"probe failed", 2} end,
               "/usr/bin/lsof"
             )

    assert {:error, "lsof exited with status 1:" <> _rest} =
             Reset.database_status(
               database,
               fn _, _, _ -> {"lsof: cannot stat file", 1} end,
               "/usr/bin/lsof"
             )

    assert {:error, "probe crashed"} =
             Reset.database_status(
               database,
               fn _, _, _ -> raise "probe crashed" end,
               "/usr/bin/lsof"
             )
  end

  test "demo mode overrides ambient effectful integration settings" do
    expression = """
    keys = [:demo_mode, :dispatch_enabled, :agent_actions_enabled, :daily_digest_enabled,
            :publication_enabled, :pr_reconcile_enabled, :implementation_agent_publishes_pr,
            :github_sync_interval_ms, :herdr_sync_interval_ms,
            :github_read_token, :repository_path]
    values = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})
    IO.puts("DEMO_CONFIG=" <> Jason.encode!(values))
    """

    env = [
      {"MIX_ENV", "dev"},
      {"PTC_DEMO_MODE", "true"},
      {"PTC_DISPATCH_ENABLED", "true"},
      {"PTC_AGENT_ACTIONS_ENABLED", "true"},
      {"PTC_DAILY_DIGEST_ENABLED", "true"},
      {"PTC_PUBLICATION_ENABLED", "true"},
      {"PTC_PR_RECONCILE_ENABLED", "true"},
      {"PTC_IMPLEMENTATION_AGENT_PUBLISHES_PR", "true"},
      {"PTC_GITHUB_SYNC_INTERVAL_MS", "5000"},
      {"PTC_HERDR_SYNC_INTERVAL_MS", "5000"},
      {"GITHUB_READ_TOKEN", "must-not-be-used"},
      {"PTC_REPOSITORY_PATH", "/must/not/be-used"}
    ]

    assert {output, 0} =
             System.cmd("mix", ["run", "--no-start", "-e", expression],
               env: env,
               stderr_to_stdout: true
             )

    [json] = Regex.run(~r/DEMO_CONFIG=(\{.*\})/, output, capture: :all_but_first)
    config = Jason.decode!(json)

    assert config["demo_mode"]

    for key <-
          ~w(dispatch_enabled agent_actions_enabled daily_digest_enabled publication_enabled pr_reconcile_enabled implementation_agent_publishes_pr) do
      refute config[key]
    end

    assert config["github_sync_interval_ms"] == 0
    assert config["herdr_sync_interval_ms"] == 0
    assert is_nil(config["github_read_token"])
    assert is_nil(config["repository_path"])
  end

  defp temporary_database! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-demo-test-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, "demo.db")
  end
end
