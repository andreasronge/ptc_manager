defmodule PtcManager.Cluster.Peer do
  @moduledoc """
  Signed, read-only requests to another member's console.

  Every request is signed with the cluster secret and every response must
  carry a valid signature from the member asked, bound to the request's nonce.
  Server authentication is the member's `ts.net` certificate, verified with
  the system trust store. The HTTP client is swappable through
  `PtcManager.Gateway`, so tests can answer in-process.
  """

  alias PtcManager.{Cluster, Gateway, Machine}
  alias PtcManager.Cluster.Signature

  @timeout_ms 5_000
  @max_body_bytes 4_000_000

  def status_path, do: "/api/peer/v1/status"

  def settings_path(owner, name),
    do: "/api/peer/v1/repositories/#{URI.encode(owner)}/#{URI.encode(name)}/settings"

  @claim_states ~w(enabled live_work pending none)

  @doc """
  Fetches a member's status document. A document without well-formed
  ownership data is refused, so a malformed answer can neither clear a claim
  nor lift a fence.
  """
  def fetch_status(member_id, opts \\ []) do
    with {:ok, status} <- fetch(member_id, status_path(), opts) do
      if valid_status?(status, member_id),
        do: {:ok, PtcManager.Cluster.StatusShape.normalize(status)},
        else: {:error, :invalid_status}
    end
  end

  defp valid_status?(status, member_id) do
    status["machine_id"] == member_id and is_integer(status["protocol_version"]) and
      is_binary(status["membership_revision"]) and
      is_list(status["repositories"]) and
      Enum.all?(status["repositories"], fn
        %{"repository" => key, "claim" => claim} -> canonical_key?(key) and claim in @claim_states
        _other -> false
      end) and
      unique_keys?(status["repositories"]) and
      is_list(status["intents"]) and
      Enum.all?(status["intents"], &match?(%{"repository" => key} when is_binary(key), &1)) and
      Enum.all?(status["intents"], &canonical_key?(&1["repository"]))
  end

  # One lowercase owner/name per repository, so every consumer reads the
  # same claim for it.
  defp canonical_key?(key) when is_binary(key),
    do: key == String.downcase(key) and match?([_owner, _name], String.split(key, "/"))

  defp canonical_key?(_key), do: false

  defp unique_keys?(repositories) do
    keys = Enum.map(repositories, & &1["repository"])
    length(keys) == length(Enum.uniq(keys))
  end

  @doc """
  GETs `path` from a member. Returns `{:ok, decoded}` for a signed 200,
  `{:error, :not_a_member}` for the member's signed refusal of this machine,
  or `{:error, reason}`.
  """
  def fetch(member_id, path, opts \\ []) do
    with base when is_binary(base) <- Cluster.base_url(member_id) || {:error, :unknown_member},
         secret when is_binary(secret) <- Cluster.secret() || {:error, :not_clustered} do
      caller = Keyword.get(opts, :as, Machine.id())
      headers = Signature.request_headers(secret, "GET", path, caller)
      nonce = header(headers, Signature.nonce_header())
      client = Keyword.get(opts, :client, client())
      timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

      case Gateway.call(client, :get, [base <> path, headers, timeout]) do
        {:ok, status, response_headers, body} when byte_size(body) <= @max_body_bytes ->
          case Signature.verify_response(secret, status, nonce, member_id, response_headers, body) do
            {:ok, skew} -> decode(status, body, skew)
            {:error, reason} -> {:error, {:bad_response_signature, reason}}
          end

        {:ok, _status, _headers, _body} ->
          {:error, :response_too_large}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(200, body, skew) do
    case Jason.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, Map.put(document, "_clock_skew_s", skew)}
      _invalid -> {:error, :invalid_document}
    end
  end

  defp decode(403, body, _skew) do
    case Jason.decode(body) do
      {:ok, %{"member" => false}} -> {:error, :not_a_member}
      _other -> {:error, {:http, 403}}
    end
  end

  defp decode(status, _body, _skew), do: {:error, {:http, status}}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if key == name, do: value end)
  end

  defp client, do: Application.get_env(:ptc_manager, :cluster_http_client, __MODULE__.Http)

  defmodule Http do
    @moduledoc false

    def get(url, headers, timeout_ms) do
      request =
        {String.to_charlist(url),
         Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)}

      http_options =
        [timeout: timeout_ms, connect_timeout: min(timeout_ms, 5_000), autoredirect: false] ++
          ssl(url)

      case :httpc.request(:get, request, http_options, body_format: :binary) do
        {:ok, {{_version, status, _reason}, response_headers, body}} ->
          {:ok, status, Enum.map(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end),
           body}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp ssl("https://" <> _rest) do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 4,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    end

    defp ssl(_plain_loopback), do: []
  end
end
