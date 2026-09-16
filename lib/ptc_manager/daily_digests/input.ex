defmodule PtcManager.DailyDigests.Input do
  @moduledoc "Exact, bounded daily evidence bytes and their persisted provenance."
  alias PtcManager.DeliveryEvidence

  @open "<daily_delivery_evidence>\n"
  @close "\n</daily_delivery_evidence>"

  def prepare(repository, digest, selection, observed_at) do
    with {:ok, cap} <- limit(:daily_digest_evidence_max_bytes, 90_000, 240_000),
         {:ok, evidence} <-
           DeliveryEvidence.build(
             repository,
             %{started_at: digest.window_started_at, ended_at: digest.window_ended_at},
             selection,
             observed_at: observed_at,
             max_bytes: cap
           ),
         {:ok, json} <- Jason.encode(evidence, escape: :html_safe),
         true <- byte_size(json) <= cap do
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
      _ -> {:error, :daily_digest_projection_invalid_or_oversized}
    end
  end

  def block(%{json: json, snapshot: snapshot}) do
    "<daily_delivery_provenance>\n" <>
      Jason.encode!(snapshot, escape: :html_safe) <>
      "\n</daily_delivery_provenance>\n" <> @open <> json <> @close
  end

  def read(action) do
    snapshot = action.target_snapshot || %{}

    with prompt when is_binary(prompt) <- action.prompt,
         [_prefix, rest] <- String.split(prompt, @open),
         [json, _suffix] <- String.split(rest, @close),
         true <- byte_size(json) == snapshot["evidence_bytes"],
         true <- hash(json) == snapshot["trusted_evidence_sha256"],
         {:ok, evidence} <- Jason.decode(json),
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
