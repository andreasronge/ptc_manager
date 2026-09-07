defmodule PtcManager.DeliveryMetrics do
  @moduledoc "Bounded, optional command telemetry; missing data never means zero."
  import Ecto.Changeset

  @keys ~w(cpu_usage_usec cpu_user_usec cpu_system_usec cpu_throttled_usec memory_high_events oom_kills io_read_bytes io_write_bytes allowed_cpus cpu_quota_millicores memory_limit_bytes)
  def validate(changeset) do
    validate_change(changeset, :resource_metrics, fn field, value ->
      if is_map(value) and map_size(value) <= length(@keys) and
           Enum.all?(value, fn {k, v} ->
             k in @keys and is_integer(v) and v >= 0 and v <= 9_000_000_000_000_000
           end), do: [], else: [{field, "must contain bounded nonnegative resource counters"}]
    end)
  end

  def average_cores(%{resource_metrics: %{"cpu_usage_usec" => cpu}, run_duration_ms: ms})
      when is_integer(ms) and ms > 0,
      do: Float.round(cpu / (ms * 1000), 2)

  def average_cores(_), do: nil
end
