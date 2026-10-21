defmodule PtcManager.Cluster.Signature do
  @moduledoc """
  HMAC-SHA256 signatures for peer requests and responses.

  A request signs its method, path (with query), timestamp, caller machine id,
  a random nonce, and the SHA-256 of its body. The response signs its status,
  the request's nonce, its own timestamp, the responding machine id, and the
  SHA-256 of its body, so a response cannot be replayed to another request.
  Timestamps must be within 60 seconds of the verifier's clock and every
  comparison is constant-time. The protocol is read-only, so no nonce is
  remembered; a future write endpoint must add a nonce store.
  """

  @skew_seconds 60

  @machine_header "x-ptc-machine"
  @timestamp_header "x-ptc-timestamp"
  @nonce_header "x-ptc-nonce"
  @signature_header "x-ptc-signature"

  def machine_header, do: @machine_header
  def timestamp_header, do: @timestamp_header
  def nonce_header, do: @nonce_header
  def signature_header, do: @signature_header
  def skew_seconds, do: @skew_seconds

  def new_nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc "Headers for a signed request."
  def request_headers(secret, method, path, caller, body \\ "", now \\ System.os_time(:second)) do
    nonce = new_nonce()
    timestamp = Integer.to_string(now)

    [
      {@machine_header, caller},
      {@timestamp_header, timestamp},
      {@nonce_header, nonce},
      {@signature_header,
       sign(secret, request_string(method, path, timestamp, caller, nonce, body))}
    ]
  end

  @doc "Verifies a request's headers; returns `{:ok, caller}` or `{:error, reason}`."
  def verify_request(secret, method, path, headers, body \\ "", now \\ System.os_time(:second)) do
    with {:ok, caller} <- header(headers, @machine_header),
         {:ok, timestamp} <- header(headers, @timestamp_header),
         {:ok, nonce} <- header(headers, @nonce_header),
         {:ok, signature} <- header(headers, @signature_header),
         :ok <- fresh(timestamp, now),
         :ok <-
           compare(
             signature,
             sign(secret, request_string(method, path, timestamp, caller, nonce, body))
           ) do
      {:ok, caller}
    end
  end

  @doc "Headers for a signed response to a request carrying `nonce`."
  def response_headers(secret, status, nonce, responder, body, now \\ System.os_time(:second)) do
    timestamp = Integer.to_string(now)

    [
      {@machine_header, responder},
      {@timestamp_header, timestamp},
      {@signature_header,
       sign(secret, response_string(status, nonce, timestamp, responder, body))}
    ]
  end

  @doc """
  Verifies a response to the request that carried `nonce`, expecting it from
  `responder`. Returns `{:ok, skew_seconds}`: the responder's clock minus ours.
  """
  def verify_response(
        secret,
        status,
        nonce,
        responder,
        headers,
        body,
        now \\ System.os_time(:second)
      ) do
    with {:ok, ^responder} <- header(headers, @machine_header),
         {:ok, timestamp} <- header(headers, @timestamp_header),
         {:ok, signature} <- header(headers, @signature_header),
         :ok <- fresh(timestamp, now),
         :ok <-
           compare(
             signature,
             sign(secret, response_string(status, nonce, timestamp, responder, body))
           ) do
      {:ok, String.to_integer(timestamp) - now}
    else
      {:ok, _other_machine} -> {:error, :wrong_responder}
      error -> error
    end
  end

  defp request_string(method, path, timestamp, caller, nonce, body) do
    Enum.join(
      [
        "ptc-peer-request-v1",
        String.upcase(method),
        path,
        timestamp,
        caller,
        nonce,
        digest(body)
      ],
      "\n"
    )
  end

  defp response_string(status, nonce, timestamp, responder, body) do
    Enum.join(
      [
        "ptc-peer-response-v1",
        Integer.to_string(status),
        nonce,
        timestamp,
        responder,
        digest(body)
      ],
      "\n"
    )
  end

  defp sign(secret, string),
    do: :crypto.mac(:hmac, :sha256, secret, string) |> Base.encode16(case: :lower)

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp header(headers, name) do
    case for(
           {key, value} <- headers,
           String.downcase(to_string(key)) == name,
           do: to_string(value)
         ) do
      [value] when value != "" and byte_size(value) <= 256 -> {:ok, value}
      _missing -> {:error, {:missing_header, name}}
    end
  end

  defp fresh(timestamp, now) do
    case Integer.parse(timestamp) do
      {value, ""} when abs(value - now) <= @skew_seconds -> :ok
      {_value, ""} -> {:error, :clock_skew}
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  defp compare(given, expected) do
    if byte_size(given) == byte_size(expected) and Plug.Crypto.secure_compare(given, expected),
      do: :ok,
      else: {:error, :bad_signature}
  end
end
