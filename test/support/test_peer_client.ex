defmodule PtcManager.TestPeerClient do
  @moduledoc """
  An in-process peer client for `PtcManager.Cluster.Peer`.

  `members` maps a member id to a function receiving the request path and
  returning `{status, document}`, `:down`, or `{:raw, status, headers, body}`.
  Responses are signed the way a real member signs them, with the request's
  nonce, unless the function asks for a raw reply.
  """

  defstruct members: %{}, secret: nil

  alias PtcManager.Cluster
  alias PtcManager.Cluster.Signature

  def new(members, secret \\ Cluster.secret()), do: %__MODULE__{members: members, secret: secret}

  def get(%__MODULE__{} = client, url, headers, _timeout_ms) do
    {member_id, base} =
      Enum.find(Cluster.members(), fn {_id, base} -> String.starts_with?(url, base) end)

    path = String.replace_prefix(url, base, "")

    nonce =
      Enum.find_value(headers, fn {key, value} ->
        if key == Signature.nonce_header(), do: value
      end)

    case Map.fetch(client.members, member_id) do
      :error ->
        {:error, :econnrefused}

      {:ok, respond} ->
        case respond.(path, headers) do
          :down ->
            {:error, :econnrefused}

          {:raw, status, response_headers, body} ->
            {:ok, status, response_headers, body}

          {status, document} ->
            body = Jason.encode!(document)

            {:ok, status,
             Signature.response_headers(client.secret, status, nonce, member_id, body), body}
        end
    end
  end

  @doc "A minimal, compatible status document for `member_id`."
  def status(member_id, overrides \\ %{}) do
    Map.merge(
      %{
        "protocol_version" => Cluster.protocol_version(),
        "machine_id" => member_id,
        "machine_name" => member_id,
        "membership_revision" => Cluster.membership_revision(),
        "deployed_sha" => String.duplicate("a", 40),
        "operational_mode" => "active",
        "repositories" => [],
        "intents" => [],
        "inventory" => %{"pane" => nil, "setup" => nil},
        "agent_logins" => %{},
        "execution_profiles" => %{},
        "jobs" => [],
        "collection_runs" => []
      },
      overrides
    )
  end
end
