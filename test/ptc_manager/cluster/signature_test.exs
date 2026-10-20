defmodule PtcManager.Cluster.SignatureTest do
  use ExUnit.Case, async: true

  alias PtcManager.Cluster.Signature

  @secret String.duplicate("k", 40)
  @now 1_800_000_000

  test "a signed request verifies and names its caller" do
    headers = Signature.request_headers(@secret, "GET", "/api/peer/v1/status", "beta", "", @now)

    assert {:ok, "beta"} =
             Signature.verify_request(
               @secret,
               "GET",
               "/api/peer/v1/status",
               headers,
               "",
               @now + 30
             )
  end

  test "any change to the signed parts, the secret, or the clock is refused" do
    headers = Signature.request_headers(@secret, "GET", "/api/peer/v1/status", "beta", "", @now)

    assert {:error, :bad_signature} =
             Signature.verify_request(@secret, "GET", "/api/peer/v1/other", headers, "", @now)

    assert {:error, :bad_signature} =
             Signature.verify_request(@secret, "POST", "/api/peer/v1/status", headers, "", @now)

    assert {:error, :bad_signature} =
             Signature.verify_request(
               @secret,
               "GET",
               "/api/peer/v1/status",
               headers,
               "body",
               @now
             )

    assert {:error, :bad_signature} =
             Signature.verify_request(
               String.duplicate("x", 40),
               "GET",
               "/api/peer/v1/status",
               headers,
               "",
               @now
             )

    forged = List.keyreplace(headers, "x-ptc-machine", 0, {"x-ptc-machine", "gamma"})

    assert {:error, :bad_signature} =
             Signature.verify_request(@secret, "GET", "/api/peer/v1/status", forged, "", @now)

    assert {:error, :clock_skew} =
             Signature.verify_request(
               @secret,
               "GET",
               "/api/peer/v1/status",
               headers,
               "",
               @now + 61
             )

    assert {:error, {:missing_header, "x-ptc-signature"}} =
             Signature.verify_request(
               @secret,
               "GET",
               "/api/peer/v1/status",
               List.keydelete(headers, "x-ptc-signature", 0),
               "",
               @now
             )
  end

  test "a response is bound to its request's nonce and to the member asked" do
    body = ~s({"ok":true})
    headers = Signature.response_headers(@secret, 200, "nonce-1", "beta", body, @now + 3)

    assert {:ok, 3} =
             Signature.verify_response(@secret, 200, "nonce-1", "beta", headers, body, @now)

    assert {:error, :bad_signature} =
             Signature.verify_response(@secret, 200, "nonce-2", "beta", headers, body, @now)

    assert {:error, :wrong_responder} =
             Signature.verify_response(@secret, 200, "nonce-1", "gamma", headers, body, @now)

    assert {:error, :bad_signature} =
             Signature.verify_response(@secret, 403, "nonce-1", "beta", headers, body, @now)

    assert {:error, :bad_signature} =
             Signature.verify_response(
               @secret,
               200,
               "nonce-1",
               "beta",
               headers,
               ~s({"ok":false}),
               @now
             )
  end
end
