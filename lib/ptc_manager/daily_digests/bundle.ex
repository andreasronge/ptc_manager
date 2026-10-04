defmodule PtcManager.DailyDigests.Bundle do
  @moduledoc "Atomically publishes and verifies immutable daily-report input bundles."

  import Ecto.Query
  alias PtcManager.{Repo, Operations.AgentAction}
  alias PtcManager.Operations.AgentRun

  @manifest "manifest.json"
  @evidence "delivery.json"

  def publish(repository, digest, evidence, snapshot, identity) do
    _ = cleanup_expired()

    with {:ok, root} <- root(),
         {:ok, json} <- Jason.encode(evidence, escape: :html_safe),
         :ok <- enforce_budget(json),
         manifest <- manifest(repository, digest, evidence, snapshot, json, identity),
         manifest_json <- Jason.encode!(manifest, escape: :html_safe),
         :ok <- enforce_manifest_budget(manifest_json),
         directory <- bundle_path(root, repository.id, digest.id, identity_label(identity)),
         staging <- directory <> ".staging-" <> random(),
         :ok <- ensure_new_path(directory),
         :ok <- File.mkdir_p(staging),
         :ok <- File.write(Path.join(staging, @evidence), json, [:exclusive, :binary]),
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
  catch
    :artifact_budget_exceeded -> {:error, :daily_digest_artifact_budget_exceeded}
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
  catch
    :artifact_budget_exceeded -> {:error, :daily_digest_artifact_budget_exceeded}
  end

  defp verify_artifact_index(%{"execution_artifacts" => %{"root" => root, "data" => data}})
       when is_binary(root) and is_list(data) do
    descriptors = Enum.map(data, &{Path.join(root, &1["manifest_path"] || ""), &1["source_id"]})

    if checked_entries(root, descriptors) == data,
      do: :ok,
      else: {:error, :daily_digest_artifact_mismatch}
  end

  defp verify_artifact_index(%{"execution_artifacts" => %{"root" => nil, "data" => []}}),
    do: :ok

  defp verify_artifact_index(_), do: {:error, :daily_digest_artifact_mismatch}

  defp manifest(repository, digest, evidence, snapshot, json, identity) do
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
        max_files = Application.get_env(:ptc_manager, :daily_digest_artifact_max_files, 1_000)

        if not is_integer(max_files) or max_files < 1 or length(ids) > max_files,
          do: throw(:artifact_budget_exceeded)

        deadline = System.monotonic_time(:millisecond) + 30_000

        paths =
          Enum.reduce(ids, [], fn {kind, id}, paths ->
            if System.monotonic_time(:millisecond) > deadline,
              do: throw(:artifact_budget_exceeded)

            found = artifact_entries(root, repository_id, kind, id)
            if length(paths) + length(found) > max_files, do: throw(:artifact_budget_exceeded)
            found ++ paths
          end)

        checked_entries(root, paths, deadline)
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

  defp artifact_entries(root, repository_id, :operation, id) do
    root
    |> Path.join("repository-#{repository_id}/*/operation-#{id}-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&{&1, "operation:#{id}"})
  end

  defp artifact_entries(root, _repository_id, :review, id) do
    root
    |> Path.join("reviews/round-#{id}/run-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&{&1, "review:#{id}"})
  end

  defp artifact_entries(root, repository_id, :setup, id) do
    root
    |> Path.join("repository-#{repository_id}/job-#{id}/workspace-setup-*/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&{&1, "setup:#{id}"})
  end

  defp artifact_entries(root, repository_id, :agent_run, id) do
    root
    |> Path.join("repository-#{repository_id}/job-*/agent-run-#{id}/manifest.json")
    |> Path.wildcard(match_dot: false)
    |> Enum.map(&{&1, "agent_run:#{id}"})
  end

  defp checked_entries(
         root,
         descriptors,
         deadline \\ System.monotonic_time(:millisecond) + 30_000
       ) do
    max_files = Application.get_env(:ptc_manager, :daily_digest_artifact_max_files, 1_000)
    max_bytes = Application.get_env(:ptc_manager, :daily_digest_artifact_max_bytes, 512_000_000)

    if not is_integer(max_files) or max_files < 1 or not is_integer(max_bytes) or max_bytes < 1 or
         length(descriptors) > max_files,
       do: throw(:artifact_budget_exceeded)

    Enum.reduce(descriptors, 0, fn {path, _}, total ->
      size =
        case if(safe_regular_file(path, root) == :ok,
               do: File.lstat(path),
               else: {:error, :unsafe}
             ) do
          {:ok, %{type: :regular, size: size}} when size <= 1_000_000 ->
            case File.read(path) do
              {:ok, json} ->
                case Jason.decode(json) do
                  {:ok, %{"streams" => streams}} when is_map(streams) ->
                    Enum.reduce(streams, size, fn
                      {_, %{"bytes" => bytes}}, sum when is_integer(bytes) and bytes >= 0 ->
                        sum + bytes

                      _, sum ->
                        sum
                    end)

                  _ ->
                    size
                end

              _ ->
                0
            end

          {:ok, %{size: size}} when size > 1_000_000 ->
            throw(:artifact_budget_exceeded)

          _ ->
            0
        end

      if total + size > max_bytes or System.monotonic_time(:millisecond) > deadline,
        do: throw(:artifact_budget_exceeded)

      total + size
    end)

    Enum.flat_map(descriptors, fn {path, source_id} ->
      artifact_entry(root, path, source_id, deadline)
    end)
  end

  defp artifact_entry(root, path, source_id, deadline) do
    with :ok <- safe_regular_file(path, root),
         {:ok, %{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(bytes),
         true <- manifest["kind"] in ~w(operation review workspace_setup provider_session),
         true <- manifest["kind"] == expected_kind(source_id),
         true <- manifest["coverage"] in ~w(complete partial unavailable error),
         {:ok, streams, stream_coverage} <-
           verify_streams(path, manifest["kind"], manifest["streams"], deadline) do
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

  defp expected_kind("operation:" <> _), do: "operation"
  defp expected_kind("review:" <> _), do: "review"
  defp expected_kind("setup:" <> _), do: "workspace_setup"
  defp expected_kind("agent_run:" <> _), do: "provider_session"
  defp expected_kind(_), do: nil

  defp verify_streams(_manifest_path, _kind, streams, _deadline) when not is_map(streams),
    do: {:error, :invalid_streams}

  defp verify_streams(manifest_path, kind, streams, deadline) do
    if Enum.any?(streams, fn {_, stream} -> not is_map(stream) end), do: throw(:invalid_streams)

    expected = %{
      "operation" => ~w(stdout stderr),
      "review" => ~w(stdout stderr),
      "workspace_setup" => ~w(combined),
      "provider_session" => ~w(session)
    }

    verified =
      Map.new(streams, fn {name, stream} ->
        relative = stream["path"]
        path = if is_binary(relative), do: Path.join(Path.dirname(manifest_path), relative)

        valid =
          with true <- is_binary(path),
               true <- Path.basename(relative) == relative,
               true <- Path.expand(Path.dirname(path)) == Path.expand(Path.dirname(manifest_path)),
               {:ok, %{type: :regular, size: size}} <- File.lstat(path),
               true <- size == stream["bytes"],
               true <- file_hash(path, deadline) == stream["sha256"] do
            true
          else
            _ -> false
          end

        {name, Map.put(stream, "verified", valid)}
      end)

    coverage =
      if Enum.sort(Map.keys(verified)) == Enum.sort(Map.get(expected, kind, [])) and
           Enum.all?(verified, fn {_name, stream} ->
             stream["verified"] and stream["coverage"] == "complete"
           end),
         do: "complete",
         else: "partial"

    {:ok, verified, coverage}
  catch
    :invalid_streams -> {:error, :invalid_streams}
  end

  defp combine_coverage(declared, _) when declared in ~w(unavailable error), do: declared
  defp combine_coverage("complete", "complete"), do: "complete"
  defp combine_coverage(_declared, "unavailable"), do: "unavailable"
  defp combine_coverage(_declared, "partial"), do: "partial"
  defp combine_coverage(nil, coverage), do: coverage
  defp combine_coverage(coverage, _), do: coverage

  defp file_hash(path, deadline) do
    path
    |> File.stream!(65_536, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn bytes, digest ->
      if System.monotonic_time(:millisecond) > deadline, do: throw(:artifact_budget_exceeded)
      :crypto.hash_update(digest, bytes)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  defp safe_regular_file(path, root) do
    expanded = Path.expand(path)
    prefix = Path.expand(root) <> "/"

    with true <- Path.type(path) == :absolute,
         true <- String.starts_with?(expanded, prefix),
         true <- safe_parents?(Path.dirname(expanded), Path.expand(root)),
         {:ok, %{type: :regular}} <- File.lstat(expanded) do
      :ok
    else
      _ -> {:error, :unsafe_bundle_path}
    end
  end

  defp safe_parents?(path, root) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> path == root or safe_parents?(Path.dirname(path), root)
      _ -> false
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

  defp enforce_manifest_budget(json) do
    if byte_size(json) <= 1_000_000, do: :ok, else: {:error, :daily_digest_manifest_too_large}
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
  defp normalize_error(:daily_digest_manifest_too_large), do: :daily_digest_manifest_too_large
  defp normalize_error(:eexist), do: :daily_digest_bundle_exists
  defp normalize_error(:daily_digest_evidence_too_large), do: :daily_digest_evidence_too_large
  defp normalize_error(_), do: :daily_digest_bundle_write_failed
end
