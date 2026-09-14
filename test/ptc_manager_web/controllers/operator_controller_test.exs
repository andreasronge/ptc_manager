defmodule PtcManagerWeb.OperatorControllerTest do
  use PtcManagerWeb.ConnCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.Job
  alias PtcManager.Repo

  @token "test-operator-token-0123456789abcdef"

  setup do
    previous = Application.get_env(:ptc_manager, :operator_token)
    on_exit(fn -> restore_env(:operator_token, previous) end)
    :ok
  end

  test "answers 404 when no token is configured, so the routes stay invisible", %{conn: conn} do
    Application.delete_env(:ptc_manager, :operator_token)

    for path <- [~p"/api/operator/state", ~p"/api/operator/stalls"] do
      assert conn |> bearer(@token) |> get(path) |> json_response(404)
    end
  end

  test "refuses a missing, wrong, or query-string token", %{conn: conn} do
    assert conn |> get(~p"/api/operator/state") |> json_response(401)
    assert conn |> bearer("wrong") |> get(~p"/api/operator/state") |> json_response(401)
    assert conn |> bearer(@token <> "x") |> get(~p"/api/operator/state") |> json_response(401)

    response = conn |> get("/api/operator/state?token=#{@token}")
    assert json_response(response, 401)
    assert get_resp_header(response, "www-authenticate") == ["Bearer"]
  end

  test "serves the state projection with every section", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 12, workflow_label: "ptc:ready"})
    {:ok, _job} = Operations.approve_issue_directly(issue.id, "maintainer")

    body = conn |> bearer(@token) |> get(~p"/api/operator/state") |> json_response(200)

    assert %{
             "captured_at" => _,
             "operational_mode" => "active",
             "deployments" => [],
             "capacity" => %{"operation_capacity" => _, "herdr_online" => false},
             "resource_operations" => [],
             "workers" => [],
             "agent_runs" => [],
             "audit_events" => [_ | _],
             "repositories" => [%{"jobs" => [%{"issue_number" => 12, "state" => "queued"}]}]
           } = body

    refute Map.has_key?(body, "prompt")
  end

  test "serves stalls with the console's words under untrusted", %{conn: conn} do
    repository = repository_fixture()
    issue = issue_fixture(repository, %{number: 13, workflow_label: "ptc:ready"})
    {:ok, job} = Operations.approve_issue_directly(issue.id, "maintainer")

    job
    |> Job.changeset(%{
      state: "failed",
      stop_report: %{"reason_code" => "environment_broken", "summary" => "No network"},
      stop_reported_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()

    assert %{"stalls" => [stall]} =
             conn |> bearer(@token) |> get(~p"/api/operator/stalls") |> json_response(200)

    assert %{
             "kind" => "stop_unacknowledged",
             "severity" => "attention",
             "target_type" => "job",
             "untrusted" => %{"detail" => detail}
           } = stall

    assert stall["target_id"] == job.id
    assert detail =~ "No network"
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
