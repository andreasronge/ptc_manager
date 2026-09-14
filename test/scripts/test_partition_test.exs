defmodule PtcManager.Scripts.TestPartitionTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/ci/test-partition", __DIR__)
  @weights Path.expand("../../scripts/ci/test-weights", __DIR__)
  @test_root Path.expand("../../test", __DIR__)

  test "every test file lands in exactly one of the partitions" do
    partitions = 5

    assigned =
      for partition <- 1..partitions,
          file <- partition_files(partition, partitions),
          do: file

    all_files =
      @test_root
      |> Path.join("**/*_test.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, Path.dirname(@test_root)))
      |> Enum.sort()

    assert Enum.sort(assigned) == all_files
    assert length(assigned) == length(all_files)
  end

  test "weights spread the heaviest files across partitions instead of stacking them" do
    root = temporary_directory()
    weights = Path.join(root, "weights")

    File.write!(
      weights,
      "# comment\n9000\ttest/ptc_manager/deployments_test.exs\n8000\ttest/ptc_manager/maintainer_actions_test.exs\n"
    )

    first = partition_files(1, 2, weights)
    second = partition_files(2, 2, weights)

    assert "test/ptc_manager/deployments_test.exs" in first
    assert "test/ptc_manager/maintainer_actions_test.exs" in second
    assert first ++ second != []
    assert Enum.sort(first ++ second) == Enum.sort(partition_files(1, 1, weights))
  end

  test "the checked-in weights file names only files that exist" do
    listed =
      @weights
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(fn line ->
        [milliseconds, path] = String.split(line, "\t")
        assert String.match?(milliseconds, ~r/^\d+$/), "weight for #{path} is not an integer"
        path
      end)

    missing = Enum.reject(listed, &File.regular?(Path.join(Path.dirname(@test_root), &1)))
    assert missing == [], "weights list files that no longer exist: #{inspect(missing)}"
  end

  test "rejects a partition outside the configured count" do
    assert {_output, 2} = System.cmd(@script, ["3", "2"], stderr_to_stdout: true)
    assert {_output, 2} = System.cmd(@script, ["0", "2"], stderr_to_stdout: true)
    assert {_output, 2} = System.cmd(@script, ["x", "2"], stderr_to_stdout: true)
  end

  defp partition_files(partition, partitions, weights \\ @weights) do
    {output, 0} =
      System.cmd(@script, [Integer.to_string(partition), Integer.to_string(partitions), weights])

    String.split(output, "\n", trim: true)
  end

  defp temporary_directory do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-test-partition-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
