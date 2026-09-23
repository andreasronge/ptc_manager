defmodule PtcManager.HerdrTranscriptTest do
  use ExUnit.Case, async: true

  alias PtcManager.Herdr.Transcript
  alias PtcManager.Operations.AgentRun

  defmodule FakeCommand do
    def run(["agent", "read", "impl_j3_f1", "--lines", "120"], 10_000) do
      {:ok, "\e[31mRunning tests\e[0m\nResult: 42 passed\n"}
    end
  end

  defmodule FailedCommand do
    def run(_args, _timeout), do: {:error, {:herdr_exit, 1, "private diagnostic"}}
  end

  defmodule UnnamedAgentCommand do
    def run(["agent", "read", "w55:p1", "--lines", "120"], 10_000),
      do: {:ok, "Claude is idle\n"}
  end

  test "reads a bounded terminal snapshot without terminal escape sequences" do
    run = %AgentRun{agent_name: "impl_j3_f1"}

    assert {:ok, output} = Transcript.read(run, FakeCommand)
    assert output == "Running tests\nResult: 42 passed"
  end

  test "does not expose command diagnostics when a terminal is unavailable" do
    assert {:error, "This agent terminal is no longer available."} =
             Transcript.read(%AgentRun{agent_name: "impl_j3_f1"}, FailedCommand)
  end

  test "reads an unmanaged agent through its pane when its kind is not a unique name" do
    run = %AgentRun{agent_name: "claude", herdr_pane: "w55:p1"}
    assert {:ok, "Claude is idle"} = Transcript.read(run, UnnamedAgentCommand)
  end
end
