defmodule PtcManager.ReviewWorkerContractTest do
  use ExUnit.Case, async: true

  for script <- ["review_worker_contract.py", "delivery_metrics_contract.py"] do
    @tag :nightly
    test "offline wrapper contract: #{script}" do
      {output, status} =
        System.cmd("python3", ["test/" <> unquote(script)], stderr_to_stdout: true)

      assert status == 0, output
    end
  end
end
