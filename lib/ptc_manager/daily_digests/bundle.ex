defmodule PtcManager.DailyDigests.Bundle do
  @moduledoc "Atomically publishes and verifies immutable daily-report input bundles."

  import Ecto.Query
  alias PtcManager.{Repo, Operations.AgentAction}
  alias PtcManager.Operations.{AgentRun, WorktreeAllocation}
  alias PtcManager.Repository.WorkerHelper

  @manifest "manifest.json"
  @evidence "delivery.json"

  def publish(repository, digest, evidence, snapshot, identity) do
    _ = cleanup_expired()

    with {:ok, root} <- root(),
         {:ok, json} <- Jason.encode(evidence, escape: :html_safe),
         :ok <- enforce_budget(json),
         directory <- bundle_path(root, repository.id, digest.id, identity_label(identity)),
         staging <- directory <> ".staging-" <> random(),
         :ok <- ensure_new_path(directory),
         :ok <- File.mkdir_p(staging),
         :ok <- File.write(Path.join(staging, @evidence), json, [:exclusive, :binary]),
         manifest <- manifest(repository, digest, evidence, snapshot, json, identity),
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

  def release(snapshot) when is_map(snapshot) do
    with path when is_binary(path) <- snapshot["evidence_manifest_path"],
         {:ok, root} <- root(),
         :ok <- safe_regular_file(path, root),
         directory <- Path.dirname(path),
         :ok <- make_writable(directory),
         {:ok, _} <- File.rm_rf(directory) do
      :ok
    else
      nil -> :ok
      _ -> {:error, :daily_digest_bundle_cleanup_failed}
    end
  end

  def cleanup_expired(now \\ DateTime.utc_now()) do
    with {:ok, root} <- root() do
      days = Application.get_env(:ptc_manager, :daily_digest_bundle_retention_days, 90)
      cutoff = DateTime.to_unix(now) - days * 86_400

      referenced =
        Repo.all(from a in AgentAction, select: a.target_snapshot)
        |> Enum.map(& &1["evidence_manifest_path"])
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      root
      |> Path.join("repository-*/digest-*/attempt-*")
      |> Path.wildcard()
      |> Enum.each(fn directory ->
        manifest = Path.join(directory, @manifest)

        case File.stat(directory, time: :posix) do
          {:ok, %{mtime: mtime}} when mtime < cutoff ->
            unless MapSet.member?(referenced, manifest) do
              with :ok <- make_writable(directory), do: File.rm_rf(directory)
            end

          _ ->
            :ok
        end
      end)

      cleanup_execution_artifacts(cutoff)

      :ok
    end
  end

  defp cleanup_execution_artifacts(cutoff) do
    case Application.get_env(:ptc_manager, :execution_artifact_root) do
      root when is_binary(root) and root != "" ->
        referenced = referenced_execution_manifests()

        ["repository-*/*/*/manifest.json", "reviews/round-*/run-*/manifest.json"]
        |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
        |> Enum.each(fn manifest ->
          case File.stat(manifest, time: :posix) do
            {:ok, %{mtime: mtime}} when mtime < cutoff ->
              relative = Path.relative_to(manifest, root)

              unless MapSet.member?(referenced, relative) do
                manifest |> Path.dirname() |> make_writable()
                manifest |> Path.dirname() |> File.rm_rf()
              end

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp referenced_execution_manifests do
    Repo.all(from a in AgentAction, select: a.target_snapshot)
    |> Enum.map(& &1["evidence_manifest_path"])
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn path ->
      with {:ok, bytes} <- File.read(path),
           {:ok, manifest} <- Jason.decode(bytes) do
        Enum.map(get_in(manifest, ["execution_artifacts", "data"]) || [], & &1["manifest_path"])
      else
        _ -> []
      end
    end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  def read(action) do
    snapshot = action.target_snapshot || %{}

    with path when is_binary(path) <- snapshot["evidence_manifest_path"],
         {:ok, root} <- root(),
         :ok <- safe_regular_file(path, root),
         {:ok, manifest_json} <- File.read(path),
         true <- hash(manifest_json) == snapshot["evidence_manifest_sha256"],
         {:ok, manifest} when is_map(manifest) <- Jason.decode(manifest_json),
         :ok <- verify_artifact_index(manifest),
         true <- manifest["repository"]["id"] == action.repository_id,
         true <-
           manifest["action"] == %{
             "id" => action.id,
             "attempt" => action.attempt_count,
             "daily_digest_id" => action.target_id
           },
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

  defp verify_artifact_index(%{"execution_artifacts" => %{"root" => root, "data" => data}})
       when is_binary(root) and is_list(data) do
    if Enum.all?(data, fn stored ->
         path = Path.join(root, stored["manifest_path"] || "")
         artifact_entry(root, path, stored["source_id"]) == [stored]
       end),
       do: :ok,
       else: {:error, :daily_digest_artifact_mismatch}
  end

  defp verify_artifact_index(%{"execution_artifacts" => %{"root" => nil, "data" => []}}),
    do: :ok

  defp verify_artifact_index(_), do: {:error, :daily_digest_artifact_mismatch}

  defp manifest(repository, digest, evidence, snapshot, json, identity) do
    job_ids = job_ids(evidence)
    acquire_job_sessions(repository.id, job_ids)
    artifacts = artifact_index(repository.id, evidence)

    %{
      "schema_version" => 1,
      "repository" => %{
        "id" => repository.id,
        "full_name" => "#{repository.github_owner}/#{repository.github_name}"
      },
      "action" => %{
        "id" => identity.action_id,
        "attempt" => identity.attempt,
        "daily_digest_id" => digest.id
      },
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
      "coverage" => %{"delivery" => "complete", "execution_logs" => artifacts.coverage},
      "execution_artifacts" => %{
        "root" => artifacts.root,
        "data" => artifacts.data,
        "missing_source_ids" => artifacts.missing
      },
      "delivery" => %{"path" => @evidence, "bytes" => byte_size(json), "sha256" => hash(json)}
    }
  end

  defp identity_label(%{action_id: id, attempt: attempt}), do: "#{id}-#{attempt}"

  defp artifact_index(repository_id, evidence) do
    root = Application.get_env(:ptc_manager, :execution_artifact_root)
    ids = expected_artifact_ids(evidence)

    entries =
      if is_binary(root) and Path.type(root) == :absolute do
        Enum.flat_map(ids, fn {kind, id} -> artifact_entries(root, repository_id, kind, id) end)
      else
        []
      end

    found = MapSet.new(entries, & &1["source_id"])

    missing =
      ids
      |> Enum.map(fn {kind, id} -> "#{kind}:#{id}" end)
      |> Enum.reject(&MapSet.member?(found, &1))

    coverage =
      cond do
        ids == [] -> "not_applicable"
        entries == [] -> "unavailable"
        missing == [] and Enum.all?(entries, &(&1["coverage"] == "complete")) -> "complete"
        true -> "partial"
      end

    %{root: root, data: entries, missing: missing, coverage: coverage}
  end

  defp artifact_source_ids(evidence) do
    pulls = get_in(evidence, ["pull_requests", "data"]) || []

    pulls
    |> Enum.flat_map(fn pull -> get_in(pull, ["attempts", "data"]) || [] end)
    |> Enum.flat_map(fn attempt ->
      operations = get_in(attempt, ["managed_operations", "data"]) || []
      reviews = get_in(attempt, ["reviews", "data"]) || []

      [{:setup, attempt["job_id"]}] ++
        Enum.map(operations, &{:operation, &1["id"]}) ++
        Enum.map(reviews, &{:review, &1["id"]})
    end)
    |> Enum.filter(fn {_kind, id} -> is_integer(id) end)
    |> Enum.uniq()
  end

  defp job_ids(evidence) do
    pulls = get_in(evidence, ["pull_requests", "data"]) || []

    pulls
    |> Enum.flat_map(fn pull -> get_in(pull, ["attempts", "data"]) || [] end)
    |> Enum.map(& &1["job_id"])
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp expected_artifact_ids(evidence) do
    jobs = job_ids(evidence)

    runs =
      if jobs == [],
        do: [],
        else:
          Repo.all(from r in AgentRun, where: r.job_id in ^jobs, select: r.id)
          |> Enum.map(&{:agent_run, &1})

    Enum.uniq(artifact_source_ids(evidence) ++ runs)
  end

  defp acquire_job_sessions(_repository_id, []), do: :ok

  defp acquire_job_sessions(repository_id, job_ids) do
    root = Application.get_env(:ptc_manager, :execution_artifact_root)

    if WorkerHelper.worker_boundary?() and is_binary(root) and root != "" do
      Repo.all(
        from run in AgentRun,
          join: allocation in WorktreeAllocation,
          on: allocation.job_id == run.job_id,
          where: run.job_id in ^job_ids and not is_nil(run.external_key),
          select: {run.id, run.job_id, run.external_key, allocation.agent_kind}
      )
      |> Enum.each(fn {run_id, job_id, external_key, kind} ->
        session_id = external_key |> String.split(":") |> List.last()

        destination =
          Path.join([root, "repository-#{repository_id}", "job-#{job_id}", "agent-run-#{run_id}"])

        max_bytes = Application.get_env(:ptc_manager, :execution_artifact_max_bytes, 256_000_000)

        _ =
          WorkerHelper.run("/usr/local/bin/ptc-manager-worker-review", [
            "archive-session",
            kind,
            session_id,
            destination,
            Integer.to_string(max_bytes)
          ])
      end)
    end

    :ok
  end

  defp artifact_entries(root, repository_id, :operation, id) do
    root
    |> Path.join("repository-#{repository_id}/*/operation-#{id}-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.flat_map(&artifact_entry(root, &1, "operation:#{id}"))
  end

  defp artifact_entries(root, _repository_id, :review, id) do
    root
    |> Path.join("reviews/round-#{id}/run-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.flat_map(&artifact_entry(root, &1, "review:#{id}"))
  end

  defp artifact_entries(root, repository_id, :setup, id) do
    root
    |> Path.join("repository-#{repository_id}/job-#{id}/workspace-setup-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.flat_map(&artifact_entry(root, &1, "setup:#{id}"))
  end

  defp artifact_entries(root, repository_id, :agent_run, id) do
    root
    |> Path.join("repository-#{repository_id}/job-*/agent-run-#{id}/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.flat_map(&artifact_entry(root, &1, "agent_run:#{id}"))
  end

  defp artifact_entry(root, path, source_id) do
    with {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(bytes),
         {:ok, streams, stream_coverage} <- verify_streams(path, manifest["streams"]) do
      [
        %{
          "source_id" => source_id,
          "manifest_path" => Path.relative_to(path, root),
          "manifest_bytes" => byte_size(bytes),
          "manifest_sha256" => hash(bytes),
          "coverage" => combine_coverage(manifest["coverage"], stream_coverage),
          "streams" => streams
        }
      ]
    else
      _ -> []
    end
  end

  defp verify_streams(_manifest_path, streams) when not is_map(streams),
    do: {:ok, %{}, "unavailable"}

  defp verify_streams(manifest_path, streams) do
    verified =
      Map.new(streams, fn {name, stream} ->
        relative = stream["path"]
        path = if is_binary(relative), do: Path.join(Path.dirname(manifest_path), relative)

        valid =
          with true <- is_binary(path),
               true <- Path.expand(Path.dirname(path)) == Path.expand(Path.dirname(manifest_path)),
               {:ok, %{type: :regular, size: size}} <- File.lstat(path),
               true <- size == stream["bytes"],
               true <- file_hash(path) == stream["sha256"] do
            true
          else
            _ -> false
          end

        {name, Map.put(stream, "verified", valid)}
      end)

    coverage =
      if Enum.all?(verified, fn {_name, stream} ->
           stream["verified"] and stream["coverage"] == "complete"
         end),
         do: "complete",
         else: "partial"

    {:ok, verified, coverage}
  end

  defp combine_coverage("complete", "complete"), do: "complete"
  defp combine_coverage(_declared, "unavailable"), do: "unavailable"
  defp combine_coverage(_declared, "partial"), do: "partial"
  defp combine_coverage(nil, coverage), do: coverage
  defp combine_coverage(coverage, _), do: coverage

  defp file_hash(path) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
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

  defp make_writable(directory) do
    case System.cmd("/bin/chmod", ["-R", "u+w", directory], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :chmod_failed}
    end
  end

  defp ensure_new_path(path), do: if(File.exists?(path), do: {:error, :eexist}, else: :ok)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp normalize_error(:eexist), do: :daily_digest_bundle_exists
  defp normalize_error(:daily_digest_evidence_too_large), do: :daily_digest_evidence_too_large
  defp normalize_error(_), do: :daily_digest_bundle_write_failed
end
