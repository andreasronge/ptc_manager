defmodule PtcManager.DailyDigests.Input do
  @moduledoc "Exact, bounded daily evidence bytes and their persisted provenance."
  alias PtcManager.DeliveryEvidence

  alias PtcManager.DailyDigests.Bundle

  def prepare(repository, digest, selection, observed_at) do
    with {:ok, evidence} <-
           DeliveryEvidence.build(
             repository,
             %{started_at: digest.window_started_at, ended_at: digest.window_ended_at},
             selection,
             observed_at: observed_at,
             max_bytes:
               Application.get_env(:ptc_manager, :daily_digest_bundle_max_bytes, 32_000_000)
           ),
         {:ok, json} <- Jason.encode(evidence, escape: :html_safe) do
      {:ok,
       %{
         json: json,
         snapshot: %{
           "trusted_evidence_sha256" => hash(json),
           "evidence_bytes" => byte_size(json),
           "projection_schema_version" => evidence["schema_version"],
           "github_observed_at" => evidence["github_observed_at"],
           "source_default_branch" => evidence["default_branch"],
           "trusted_source_head_sha" => evidence["source_head_sha"],
           "trusted_change_count" => evidence["change_count"],
           "trusted_pull_request_numbers" => selection["pull_request_numbers"],
           "trusted_selection_limits" => evidence["limits"],
           "window_started_at" => DateTime.to_iso8601(digest.window_started_at),
           "window_ended_at" => DateTime.to_iso8601(digest.window_ended_at)
         }
       }}
    else
      {:error, :encoded_byte_limit} -> {:error, :daily_digest_evidence_too_large}
      {:error, :invalid_byte_limit} -> {:error, :daily_digest_invalid_byte_limit}
      {:error, reason} -> {:error, {:daily_digest_projection_invalid, reason}}
    end
  end

  def publish(repository, digest, input, identity) do
    with {:ok, bundle} <-
           Bundle.publish(repository, digest, Jason.decode!(input.json), input.snapshot, identity) do
      snapshot =
        input.snapshot
        |> Map.put("evidence_manifest_path", bundle.manifest_path)
        |> Map.put("evidence_manifest_sha256", bundle.manifest_sha256)
        |> Map.put("evidence_path", bundle.evidence_path)

      {:ok, input |> Map.put(:snapshot, snapshot) |> Map.put(:bundle, bundle)}
    end
  end

  def block(%{snapshot: snapshot}) do
    "<daily_delivery_bundle>\n" <>
      Jason.encode!(
        Map.take(
          snapshot,
          ~w(evidence_manifest_path evidence_manifest_sha256 evidence_path trusted_evidence_sha256)
        ),
        escape: :html_safe
      ) <>
      "\n</daily_delivery_bundle>"
  end

  def read(action) do
    snapshot = action.target_snapshot || %{}

    with {:ok, evidence} <- Bundle.read(action),
         true <- is_map(evidence),
         true <- evidence["schema_version"] == 1 and snapshot["projection_schema_version"] == 1,
         true <- evidence["repository"]["id"] == action.repository_id,
         true <- evidence["source_head_sha"] == snapshot["trusted_source_head_sha"],
         true <- evidence["change_count"] == snapshot["trusted_change_count"],
         true <- evidence["default_branch"] == snapshot["source_default_branch"],
         true <- evidence["github_observed_at"] == snapshot["github_observed_at"],
         true <- evidence["limits"] == snapshot["trusted_selection_limits"],
         true <-
           evidence["window"] == %{
             "started_at" => snapshot["window_started_at"],
             "ended_at" => snapshot["window_ended_at"]
           },
         true <-
           Enum.map(evidence["pull_requests"]["data"], & &1["number"]) ==
             snapshot["trusted_pull_request_numbers"] do
      {:ok, evidence}
    else
      _ -> {:error, :daily_digest_evidence_mismatch}
    end
  end

  def validate_prompt(prompt) when is_binary(prompt) do
    with {:ok, cap} <- limit(:daily_digest_prompt_max_bytes, 100_000, 300_000),
         true <- byte_size(prompt) <= cap do
      :ok
    else
      _ -> {:error, :daily_digest_prompt_too_large}
    end
  end

  defp limit(key, default, ceiling) do
    case Application.get_env(:ptc_manager, key, default) do
      value when is_integer(value) and value > 0 and value <= ceiling -> {:ok, value}
      _ -> {:error, :invalid_limit}
    end
  end

  defp hash(json), do: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)
end
