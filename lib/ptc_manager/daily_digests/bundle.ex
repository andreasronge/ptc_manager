defmodule PtcManager.DailyDigests.Bundle do
  @moduledoc "Atomically publishes and verifies immutable daily-report input bundles."

  @manifest "manifest.json"
  @evidence "delivery.json"

  def publish(repository, digest, evidence, snapshot, identity) do
    with {:ok, root} <- root(),
         {:ok, json} <- Jason.encode(evidence, escape: :html_safe),
         :ok <- enforce_budget(json),
         directory <- bundle_path(root, repository.id, digest.id, identity),
         staging <- directory <> ".staging-" <> random(),
         :ok <- ensure_new_path(directory),
         :ok <- File.mkdir_p(staging),
         :ok <- File.write(Path.join(staging, @evidence), json, [:exclusive, :binary]),
         manifest <- manifest(repository, digest, snapshot, json),
         manifest_json <- Jason.encode!(manifest, escape: :html_safe),
         :ok <- File.write(Path.join(staging, @manifest), manifest_json, [:exclusive, :binary]),
         :ok <- File.rename(staging, directory),
         :ok <- seal(directory) do
      {:ok,
       %{
         path: directory,
         manifest_path: Path.join(directory, @manifest),
         manifest_sha256: hash(manifest_json),
         evidence_path: Path.join(directory, @evidence),
         evidence_sha256: hash(json),
         evidence_bytes: byte_size(json),
         manifest: manifest
       }}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      false -> {:error, :daily_digest_bundle_exists}
    end
  end

  def read(action) do
    snapshot = action.target_snapshot || %{}

    with path when is_binary(path) <- snapshot["evidence_manifest_path"],
         {:ok, root} <- root(),
         :ok <- safe_regular_file(path, root),
         {:ok, manifest_json} <- File.read(path),
         true <- hash(manifest_json) == snapshot["evidence_manifest_sha256"],
         {:ok, manifest} when is_map(manifest) <- Jason.decode(manifest_json),
         true <- manifest["repository"]["id"] == action.repository_id,
         evidence_path <- Path.join(Path.dirname(path), manifest["delivery"]["path"]),
         :ok <- safe_regular_file(evidence_path, Path.dirname(path)),
         {:ok, json} <- File.read(evidence_path),
         true <- byte_size(json) == manifest["delivery"]["bytes"],
         true <- hash(json) == manifest["delivery"]["sha256"],
         {:ok, evidence} when is_map(evidence) <- Jason.decode(json) do
      {:ok, evidence}
    else
      _ -> {:error, :daily_digest_evidence_mismatch}
    end
  end

  defp manifest(repository, digest, snapshot, json) do
    %{
      "schema_version" => 1,
      "repository" => %{
        "id" => repository.id,
        "full_name" => "#{repository.github_owner}/#{repository.github_name}"
      },
      "action" => %{"daily_digest_id" => digest.id},
      "window" => %{
        "started_at" => DateTime.to_iso8601(digest.window_started_at),
        "ended_at" => DateTime.to_iso8601(digest.window_ended_at)
      },
      "captured_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "source" => %{
        "default_branch" => snapshot["source_default_branch"],
        "head_sha" => snapshot["trusted_source_head_sha"],
        "github_observed_at" => snapshot["github_observed_at"]
      },
      "coverage" => %{"delivery" => "complete", "execution_logs" => "available_as_indexed"},
      "delivery" => %{"path" => @evidence, "bytes" => byte_size(json), "sha256" => hash(json)}
    }
  end

  defp safe_regular_file(path, root) do
    expanded = Path.expand(path)
    prefix = Path.expand(root) <> "/"

    with true <- Path.type(path) == :absolute,
         true <- String.starts_with?(expanded, prefix),
         {:ok, %{type: :regular}} <- File.lstat(expanded) do
      :ok
    else
      _ -> {:error, :unsafe_bundle_path}
    end
  end

  defp root do
    case Application.get_env(:ptc_manager, :daily_digest_bundle_root) do
      value when is_binary(value) and value != "" ->
        if Path.type(value) == :absolute do
          case File.mkdir_p(value) do
            :ok -> {:ok, Path.expand(value)}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :daily_digest_bundle_root_unavailable}
        end

      _ ->
        {:error, :daily_digest_bundle_root_unavailable}
    end
  end

  defp bundle_path(root, repository_id, digest_id, identity) do
    Path.join([
      root,
      "repository-#{repository_id}",
      "digest-#{digest_id}",
      "attempt-#{identity}-#{random()}"
    ])
  end

  defp enforce_budget(json) do
    limit = Application.get_env(:ptc_manager, :daily_digest_bundle_max_bytes, 32_000_000)

    if is_integer(limit) and limit >= 1_000_000 and byte_size(json) <= limit,
      do: :ok,
      else: {:error, :daily_digest_evidence_too_large}
  end

  defp seal(directory) do
    if Application.get_env(:ptc_manager, :daily_digest_bundle_read_only, true) do
      with :ok <- File.chmod(Path.join(directory, @evidence), 0o440),
           :ok <- File.chmod(Path.join(directory, @manifest), 0o440),
           do: File.chmod(directory, 0o550)
    else
      :ok
    end
  end

  defp ensure_new_path(path), do: if(File.exists?(path), do: {:error, :eexist}, else: :ok)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp normalize_error(:eexist), do: :daily_digest_bundle_exists
  defp normalize_error(:daily_digest_evidence_too_large), do: :daily_digest_evidence_too_large
  defp normalize_error(_), do: :daily_digest_bundle_write_failed
end
