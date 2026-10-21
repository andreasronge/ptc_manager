defmodule PtcManagerWeb.PeerAuth do
  @moduledoc """
  Authenticates the peer protocol: every request must be signed with the
  cluster secret by a machine in this member's map, within the allowed clock
  skew. An unclustered console answers 404, so nothing reveals the routes. A
  correctly signed request from a machine outside the map gets a signed 403
  `{"member": false}`, which tells the caller to stop admitting work.
  """

  import Plug.Conn

  alias PtcManager.Cluster
  alias PtcManager.Cluster.Signature

  def init(opts), do: opts

  def call(conn, _opts) do
    if Cluster.enabled?() do
      path =
        if conn.query_string == "",
          do: conn.request_path,
          else: conn.request_path <> "?" <> conn.query_string

      case Signature.verify_request(Cluster.secret(), conn.method, path, conn.req_headers) do
        {:ok, caller} ->
          nonce = conn |> get_req_header(Signature.nonce_header()) |> List.first()
          conn = assign(conn, :peer_nonce, nonce)

          if Cluster.member?(caller),
            do: assign(conn, :peer_caller, caller),
            else: conn |> send_signed(403, %{"member" => false}) |> halt()

        {:error, _reason} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
          |> halt()
      end
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{errors: %{detail: "Not Found"}}))
      |> halt()
    end
  end

  @doc "Sends `document` as JSON with a response signature bound to the request's nonce."
  def send_signed(conn, status, document) do
    body = Jason.encode!(document)

    conn =
      Signature.response_headers(
        Cluster.secret(),
        status,
        conn.assigns.peer_nonce,
        PtcManager.Machine.id(),
        body
      )
      |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
