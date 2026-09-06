defmodule PtcManager.HealthSnapshotEvidence do
  @moduledoc "Validates privileged runtime evidence before a health automation may run."

  @maximum_budget_seconds 21_600

  def read(path \\ configured_path(), now \\ DateTime.utc_now())

  def read(path, %DateTime{} = now) when is_binary(path) do
    with {:ok, body} <- read_file(path),
         {:ok, snapshot} <- decode(body) do
      validate(snapshot, now)
    end
  end

  def validate(snapshot, now \\ DateTime.utc_now())

  def validate(snapshot, %DateTime{} = now) when is_map(snapshot) do
    with :ok <- validate_shape(snapshot),
         {:ok, captured_at} <- captured_at(snapshot),
         {:ok, budget} <- freshness_budget(snapshot),
         :ok <- fresh?(captured_at, budget, now) do
      {:ok, snapshot}
    end
  end

  def validate(_snapshot, %DateTime{}), do: {:error, :health_snapshot_malformed}

  def configured_path do
    Application.get_env(
      :ptc_manager,
      :health_snapshot_path,
      "/var/lib/ptc_manager-output/ptc-health.json"
    )
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :health_snapshot_missing}
      {:error, _reason} -> {:error, :health_snapshot_unreadable}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
      _invalid -> {:error, :health_snapshot_malformed}
    end
  end

  defp validate_shape(snapshot) do
    list_sections = ~w(
      capacity_settings
      live_agent_runs
      live_agent_actions
      live_resource_operations
      recent_resource_operations
      live_jobs
    )

    with true <- Enum.all?(list_sections, &is_list(snapshot[&1])),
         %{
           "window" => window,
           "line_limit" => line_limit,
           "at_limit" => at_limit,
           "total_lines" => total_lines,
           "session_noise_lines" => session_noise_lines,
           "error_lines" => error_lines
         } <- snapshot["service_log_volume"],
         true <- is_binary(window),
         true <- positive_integer?(line_limit),
         true <- is_boolean(at_limit),
         true <- non_negative_integer?(total_lines),
         true <- non_negative_integer?(session_noise_lines),
         true <- non_negative_integer?(error_lines) do
      :ok
    else
      _invalid -> {:error, :health_snapshot_malformed}
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp captured_at(%{"captured_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, captured_at, 0} -> {:ok, captured_at}
      _invalid -> {:error, :health_snapshot_malformed}
    end
  end

  defp captured_at(_snapshot), do: {:error, :health_snapshot_malformed}

  defp freshness_budget(%{"freshness_budget_seconds" => budget})
       when is_integer(budget) and budget > 0 and budget <= @maximum_budget_seconds,
       do: {:ok, budget}

  defp freshness_budget(_snapshot), do: {:error, :health_snapshot_malformed}

  defp fresh?(captured_at, budget, now) do
    age = DateTime.diff(now, captured_at, :second)

    cond do
      age < 0 -> {:error, :health_snapshot_future_dated}
      age > budget -> {:error, :health_snapshot_expired}
      true -> :ok
    end
  end
end
