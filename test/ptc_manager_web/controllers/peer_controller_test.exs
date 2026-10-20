defmodule PtcManagerWeb.PeerControllerTest do
  use PtcManagerWeb.ConnCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.Cluster.Signature

  @path "/api/peer/v1/status"

  defp signed(conn, caller, path \\ @path) do
    headers = Signature.request_headers(secret(), "GET", path, caller)
    nonce = Enum.find_value(headers, fn {k, v} -> if k == "x-ptc-nonce", do: v end)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    {conn, nonce}
  end

  defp verify!(conn, nonce) do
    assert {:ok, _skew} =
             Signature.verify_response(
               secret(),
               conn.status,
               nonce,
               "alpha",
               conn.resp_headers,
               conn.resp_body
             )

    Jason.decode!(conn.resp_body)
  end

  test "an unclustered console does not reveal the peer routes", %{conn: conn} do
    assert conn |> get(@path) |> json_response(404)
  end

  describe "on a member" do
    setup do
      join_cluster!(%{})
      :ok
    end

    test "an unsigned or tampered request is refused", %{conn: conn} do
      assert conn |> get(@path) |> json_response(401)

      {conn, _nonce} = signed(conn, "beta", "/api/peer/v1/other")
      assert conn |> get(@path) |> json_response(401)
    end

    test "a correctly signed request from a non-member gets a signed refusal", %{conn: conn} do
      {conn, nonce} = signed(conn, "delta")
      conn = get(conn, @path)
      assert conn.status == 403
      assert verify!(conn, nonce) == %{"member" => false}
    end

    test "a member gets the signed status document, without untrusted text", %{conn: conn} do
      # A member inserts repositories disabled; this one was claimed earlier.
      repository =
        repository_fixture(%{github_owner: "Acme", github_name: "Api"})
        |> PtcManager.Operations.Repository.changeset(%{enabled: true})
        |> PtcManager.Repo.update!()

      issue = issue_fixture(repository, %{title: "secret issue title", body: "secret body"})
      proposal_fixture(issue)
      {:ok, job} = PtcManager.Operations.approve_issue(issue.id, "maintainer")

      {conn, nonce} = signed(conn, "beta")
      conn = get(conn, @path)
      assert conn.status == 200
      status = verify!(conn, nonce)

      assert status["machine_id"] == "alpha"
      assert status["protocol_version"] == PtcManager.Cluster.protocol_version()
      assert status["membership_revision"] == PtcManager.Cluster.membership_revision()
      assert [%{"repository" => "acme/api", "claim" => "enabled"}] = status["repositories"]

      assert [%{"id" => id, "url" => "https://alpha.example.ts.net/jobs/" <> _}] = status["jobs"]
      assert id == job.id
      refute conn.resp_body =~ "secret issue title"
      refute conn.resp_body =~ "secret body"
      refute conn.resp_body =~ "untrusted"
    end
  end
end
