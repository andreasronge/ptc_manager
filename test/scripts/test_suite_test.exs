defmodule PtcManager.Scripts.TestSuiteTest do
  use ExUnit.Case, async: true

  @suite Path.expand("../../scripts/ci/test-suite", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-manager-test-suite-#{System.unique_integer([:positive, :monotonic])}"
      )

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, bin: bin}
  end

  test "runs isolated partitions and reports the wall-clock budget", %{bin: bin} do
    fake_mix!(
      bin,
      "printf 'partition=%s args=%s\\n' \"$MIX_TEST_PARTITION\" \"$*\"\n"
    )

    assert {output, 0} = run_suite(bin, "10")
    assert output =~ "partition=1"
    assert output =~ "partition=2"
    assert output =~ "partition=3"
    assert output =~ "--exclude nightly"
    assert output =~ "Test suite passed"
  end

  test "defaults to four partitions so the measured suite retains budget headroom", %{bin: bin} do
    fake_mix!(bin, "printf 'partition=%s\n' \"$MIX_TEST_PARTITION\"\n")

    assert {output, 0} = run_suite(bin, "10", nil, nil)
    assert output =~ "partition=4"
  end

  test "fails when a partition exceeds the test budget", %{bin: bin} do
    fake_mix!(bin, "sleep 10\n")

    assert {output, 1} = run_suite(bin, "2")
    assert output =~ "failed or exceeded its 2s budget"
  end

  test "does not begin a partial VM teardown when a partition exceeds its budget", %{bin: bin} do
    fake_mix!(
      bin,
      "trap 'echo partial-vm-teardown; sleep 10' TERM\nwhile :; do sleep 1; done\n"
    )

    assert {output, 1} = run_suite(bin, "2")
    refute output =~ "partial-vm-teardown"
  end

  test "runs only the selected CI partition", %{bin: bin} do
    fake_mix!(bin, "printf 'partition=%s\\n' \"$MIX_TEST_PARTITION\"\n")

    assert {output, 0} = run_suite(bin, "10", "2")
    assert output =~ "partition=2"
    refute output =~ "partition=1"
    refute output =~ "partition=3"
  end

  test "rejects invalid partition selections", %{bin: bin} do
    fake_mix!(bin, "exit 99\n")

    for partition <- ["0", "4", "invalid"] do
      assert {_output, 2} = run_suite(bin, "10", partition)
    end
  end

  defp fake_mix!(bin, body) do
    path = Path.join(bin, "mix")
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp run_suite(bin, budget, partition \\ nil, partitions \\ "3") do
    System.cmd(@suite, [],
      env: [
        {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
        {"PTC_TEST_BUDGET_SECONDS", budget},
        {"PTC_TEST_PARTITIONS", partitions},
        {"PTC_TEST_PARTITION_ONLY", partition}
      ],
      stderr_to_stdout: true
    )
  end
end
