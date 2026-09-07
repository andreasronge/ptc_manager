defmodule PtcManager.Reviews.Adapter do
  @moduledoc "Invokes an independently selected reviewer and reads only its structured result file."
  alias PtcManager.Repository.WorkerHelper
  @helper "/usr/local/bin/ptc-manager-worker-review"

  def review(round) do
    job =
      PtcManager.Repo.get!(PtcManager.Operations.Job, round.job_id)
      |> PtcManager.Repo.preload(:repository)

    alias PtcManager.Reviews.Snapshots

    with true <- round.input["contract_version"] == 2,
         {:ok, snapshot} <- Snapshots.prepare(round, job.repository) do
      try do
        run_review(round, snapshot.path)
      after
        Snapshots.cleanup(round.id)
      end
    else
      false -> {:error, {:preparation, :review_contract_changed_retry_required}}
      {:error, reason} -> {:error, {:preparation, reason}}
    end
  end

  defp run_review(round, snapshot_path) do
    directory = Application.fetch_env!(:ptc_manager, :agent_action_output_dir)

    name =
      "review-#{round.id}-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    request = Path.join(directory, name <> ".request.json")
    result = Path.join(directory, name <> ".result.json")

    body = %{
      settings: round.input["settings"],
      evidence:
        Map.drop(round.input, ["settings", "schema", "source_snapshot", "snapshot_cleanup_error"]),
      repository_path: snapshot_path,
      contract_version: 2,
      schema: round.input["schema"]
    }

    try do
      with :ok <- File.write(request, Jason.encode!(body), [:exclusive]),
           :ok <- File.chmod(request, 0o640),
           {_output, 0} <- WorkerHelper.run(@helper, ["review", request, result]),
           {data, 0} <- WorkerHelper.run(@helper, ["read-result", result]),
           {:ok, decoded} <- Jason.decode(data),
           true <- PtcManager.Reviews.valid_result?(decoded) do
        {:ok, decoded}
      else
        {output, status} when is_binary(output) and is_integer(status) ->
          {:error,
           {:reviewer_command_failed, status, String.slice(String.trim(output), -3_000, 3_000)}}

        {:error, reason} ->
          {:error, {:reviewer_request_failed, reason}}

        _ ->
          {:error, :invalid_review_result}
      end
    after
      File.rm(request)
      File.rm(result)
    end
  end

  def models(kind) when kind in ~w(codex claude cursor) do
    case WorkerHelper.run(@helper, ["models", kind]) do
      {data, 0} ->
        with {:ok, %{"models" => models} = catalog} <- Jason.decode(data),
             true <- is_list(models) and length(models) <= 500,
             true <- Enum.all?(models, &valid_model?/1),
             true <-
               is_nil(catalog["note"]) or
                 (is_binary(catalog["note"]) and byte_size(catalog["note"]) <= 500) do
          {:ok, Map.take(catalog, ["models", "kind", "source", "note"])}
        else
          _ -> {:error, :model_catalog_unavailable}
        end

      _ ->
        {:error, :model_catalog_unavailable}
    end
  end

  defp valid_model?(%{"id" => id, "name" => name}),
    do: is_binary(id) and is_binary(name) and byte_size(id) <= 120 and byte_size(name) <= 300

  defp valid_model?(_), do: false
end
