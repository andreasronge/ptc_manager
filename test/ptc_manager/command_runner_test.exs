defmodule PtcManager.CommandRunnerTest do
  use ExUnit.Case, async: false

  alias PtcManager.CommandRunner
  alias PtcManager.TestCommandRunner.System, as: SystemCommandRunner
  alias PtcManager.TestScenario

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-command-runner-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "system runner normalizes success, exit, and timeout" do
    assert {:ok, "ready\n"} =
             SystemCommandRunner.run("/bin/sh", ["-c", "printf 'ready\\n'"],
               stderr_to_stdout: true
             )

    assert {:error, {:exit, 7, "failed\n"}} =
             SystemCommandRunner.run("/bin/sh", ["-c", "printf 'failed\\n'; exit 7"],
               stderr_to_stdout: true
             )

    sleep = System.find_executable("sleep") || raise("sleep is required for this test")
    assert {:error, :timeout} = SystemCommandRunner.run(sleep, ["1"], timeout: 10)

    assert {:error, {:command_failed, :enoent}} =
             SystemCommandRunner.run("/definitely/missing/ptc-command", [],
               timeout: 100,
               stderr_to_stdout: true
             )
  end

  test "timeout closes the disposable command port and leaves the runner usable" do
    sleep = System.find_executable("sleep") || raise("sleep is required for this test")

    assert {:error, :timeout} = SystemCommandRunner.run(sleep, ["1"], timeout: 10)
    assert {:ok, "ready"} = SystemCommandRunner.run("/bin/sh", ["-c", "printf ready"], [])
  end

  test "a Git side effect can be observed after its acknowledgement is lost", %{root: root} do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    repository = Path.join(root, "ack-lost")
    :ok = TestScenario.operation_outcome(scenario, :run_command, :effect_then_error)

    assert {:error, {:uncertain, :scenario_command_ack_lost}} =
             CommandRunner.run(scenario, git!(), ["init", "--initial-branch=main", repository],
               stderr_to_stdout: true
             )

    assert File.dir?(Path.join(repository, ".git"))

    assert [%{operation: :run_command, outcome: %{mode: :effect_then_error}}] =
             TestScenario.trace(scenario)
  end

  test "failure before execution leaves no Git side effect", %{root: root} do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    repository = Path.join(root, "failed-before")
    :ok = TestScenario.operation_outcome(scenario, :run_command, :fail_before)

    assert {:error, {:run_command, :scenario_failed_before}} =
             CommandRunner.run(scenario, git!(), ["init", "--initial-branch=main", repository],
               stderr_to_stdout: true
             )

    refute File.exists?(repository)
  end

  test "acknowledgement-loss mode preserves a real command failure" do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    :ok = TestScenario.operation_outcome(scenario, :run_command, :effect_then_error)

    assert {:error, {:command_failed, :enoent}} =
             CommandRunner.run(scenario, "/definitely/missing/ptc-command", [],
               timeout: 100,
               stderr_to_stdout: true
             )

    assert [%{outcome: %{mode: :effect_then_error, result: {:error, _reason}}}] =
             TestScenario.trace(scenario)
  end

  test "pause after a Git side effect does not block scenario inspection", %{root: root} do
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()
    repository = Path.join(root, "paused")
    :ok = TestScenario.operation_outcome(scenario, :run_command, :pause_after_effect)

    task =
      Task.async(fn ->
        CommandRunner.run(
          scenario,
          git!(),
          ["init", "--initial-branch=main", repository],
          stderr_to_stdout: true
        )
      end)

    assert_receive {:scenario_paused_after_effect, reference, :run_command, _target}, 1_000
    assert File.dir?(Path.join(repository, ".git"))
    assert [%{operation: :run_command}] = TestScenario.trace(scenario)

    :ok = TestScenario.resume(scenario, reference)
    assert {:ok, output} = Task.await(task)
    assert output =~ "Initialized empty Git repository"
  end

  defp git!, do: System.find_executable("git") || raise("git is required for this test")
end
