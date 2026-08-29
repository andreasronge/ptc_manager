defmodule PtcManager.HerdrSyncTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Herdr.{Client, Sync}
  alias PtcManager.Operations.{AgentRun, Worker}
  alias PtcManager.Repo

  defmodule FakeClient do
    @behaviour PtcManager.Herdr
    def list_agents, do: Process.get(:herdr_result)
  end

  test "decodes supported Herdr result envelopes" do
    assert {:ok, [%{"pane_id" => "w1:p1"}]} =
             Client.decode_agents(~s({"result":{"agents":[{"pane_id":"w1:p1"}]}}))

    assert {:error, :invalid_herdr_json} = Client.decode_agents("not json")
  end

  test "reconciles current agents and marks missing activity lost" do
    Process.put(
      :herdr_result,
      {:ok,
       [
         %{
           "agent" => "Codex manager",
           "agent_status" => "working",
           "pane_id" => "w1:p1",
           "workspace_id" => "ptc-manager",
           "agent_session" => %{"value" => "agent-123"}
         }
       ]}
    )

    assert {:ok, %{agent_count: 1, lost_count: 0}} =
             Sync.sync(client: FakeClient, session: "test")

    worker = Repo.get_by!(Worker, worker_key: "herdr:test")
    run = Repo.one!(AgentRun)
    assert worker.status == "online"
    assert run.role == "manager"
    assert run.state == "working"
    assert run.external_key == "test:agent-123"

    Process.put(:herdr_result, {:ok, []})

    assert {:ok, %{agent_count: 0, lost_count: 1}} =
             Sync.sync(client: FakeClient, session: "test")

    lost_run = Repo.get!(AgentRun, run.id)
    assert lost_run.state == "lost"
    assert lost_run.ended_at
  end

  test "preserves terminal history and creates a new attempt when an agent restarts" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    finished = Repo.one!(AgentRun)

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    assert Repo.get!(AgentRun, finished.id).ended_at == finished.ended_at

    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "history")
    assert Repo.aggregate(AgentRun, :count) == 2
    assert Repo.one!(from run in AgentRun, where: run.state == "working")
  end

  test "marks stale active agents lost when Herdr cannot be reached" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "outage")

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 1}}} =
             Sync.sync(client: FakeClient, session: "outage", stale_after_ms: 0)

    assert Repo.one!(AgentRun).state == "lost"
    assert Repo.get_by!(Worker, worker_key: "herdr:outage").status == "degraded"
  end

  test "reconciles a lost agent to its later authoritative terminal state" do
    Process.put(:herdr_result, {:ok, [remote_agent("working")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "recovered")

    Process.put(:herdr_result, {:error, :offline})

    assert {:error, {:offline, %{lost_count: 1}}} =
             Sync.sync(client: FakeClient, session: "recovered", stale_after_ms: 0)

    lost_run = Repo.one!(AgentRun)

    Process.put(:herdr_result, {:ok, [remote_agent("done")]})
    assert {:ok, _summary} = Sync.sync(client: FakeClient, session: "recovered")

    recovered_run = Repo.get!(AgentRun, lost_run.id)
    assert recovered_run.state == "done"
    assert recovered_run.ended_at == lost_run.ended_at
  end

  defp remote_agent(state) do
    %{
      "agent" => "Codex implementer",
      "agent_status" => state,
      "pane_id" => "w1:p1",
      "agent_session" => %{"value" => "agent-history"}
    }
  end
end
