defmodule PtcManager.ReviewWorkerContractTest do
  use ExUnit.Case, async: true

  @tag :nightly
  test "reviewer CLI arguments, structured results, output links and timeout fail closed" do
    {output, status} =
      System.cmd("python3", ["test/review_worker_contract.py"], stderr_to_stdout: true)

    assert status == 0, output
  end
end
