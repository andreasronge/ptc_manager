defmodule PtcManager.MachineUsage do
  @moduledoc """
  Keeps a bounded history of how busy the machine has been.

  A sampler records one row every thirty seconds with the CPU, memory, and
  build-disk percentages plus the agent and expensive-operation slots occupied
  at that moment. Rows older than fourteen days are pruned. Charts read bucketed
  averages, so the last week is 168 hourly points rather than twenty thousand
  raw rows, and a bucket without any sample is reported as a gap rather than as
  zero load.
  """

  import Ecto.Query

  alias PtcManager.MachineUsage.Sample
  alias PtcManager.Repo

  @topic "machine_usage"
  @retention_days 14
  @default_range "24h"
  @ranges [
    {"1h", %{label: "Last hour", seconds: 3_600, bucket_seconds: 30}},
    {"24h", %{label: "Last day", seconds: 86_400, bucket_seconds: 300}},
    {"7d", %{label: "Last week", seconds: 604_800, bucket_seconds: 3_600}}
  ]

  def subscribe, do: Phoenix.PubSub.subscribe(PtcManager.PubSub, @topic)

  def retention_days, do: @retention_days

  def ranges, do: Enum.map(@ranges, fn {key, range} -> Map.put(range, :key, key) end)

  @doc "Resolves a range key from the URL, falling back to the default when it is unknown."
  def range(key) do
    case List.keyfind(@ranges, key, 0) do
      {key, range} -> Map.put(range, :key, key)
      nil -> range(@default_range)
    end
  end

  def default_range_key, do: @default_range

  def record_sample(attrs) when is_map(attrs) do
    %Sample{}
    |> Sample.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, sample} ->
        Phoenix.PubSub.broadcast(PtcManager.PubSub, @topic, {:machine_usage_sampled, sample})
        {:ok, sample}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days, :day)
    {count, _rows} = Repo.delete_all(from(sample in Sample, where: sample.sampled_at < ^cutoff))
    count
  end

  def count_samples, do: Repo.aggregate(Sample, :count)

  @doc """
  Returns the usage timeline for a range as evenly spaced buckets ending at the
  current bucket. Each point carries bucket averages, or `nil` values and
  `sampled?: false` when no sample fell into that bucket.
  """
  def series(range_key, opts \\ []) do
    range = range(range_key)
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    bucket = range.bucket_seconds
    now_unix = DateTime.to_unix(now)
    to_unix = div(now_unix, bucket) * bucket + bucket
    from_unix = to_unix - range.seconds
    count = div(range.seconds, bucket)
    rows = bucketed_rows(from_unix, to_unix, bucket)

    points =
      for index <- 0..(count - 1) do
        at_unix = from_unix + index * bucket

        case Map.get(rows, at_unix) do
          nil ->
            %{
              at: DateTime.from_unix!(at_unix),
              sampled?: false,
              cpu: nil,
              memory: nil,
              disk: nil,
              load: nil,
              light: nil,
              heavy: nil,
              operations: nil
            }

          row ->
            %{
              at: DateTime.from_unix!(at_unix),
              sampled?: true,
              cpu: row.cpu,
              memory: row.memory,
              disk: row.disk,
              load: row.load,
              light: row.light,
              heavy: row.heavy,
              operations: row.operations
            }
        end
      end

    %{
      range: range,
      from: DateTime.from_unix!(from_unix),
      to: DateTime.from_unix!(to_unix),
      now: now,
      bucket_seconds: bucket,
      points: points,
      sample_count: rows |> Map.values() |> Enum.map(& &1.samples) |> Enum.sum()
    }
  end

  defp bucketed_rows(from_unix, to_unix, bucket) do
    from = DateTime.from_unix!(from_unix)
    to = DateTime.from_unix!(to_unix)

    Sample
    |> where([sample], sample.sampled_at >= ^from and sample.sampled_at < ^to)
    |> group_by([sample], fragment("(strftime('%s', ?) / ?)", sample.sampled_at, ^bucket))
    |> select([sample], %{
      at: fragment("(strftime('%s', ?) / ?) * ?", sample.sampled_at, ^bucket, ^bucket),
      cpu: avg(sample.cpu_percent),
      memory: avg(sample.memory_percent),
      disk: avg(sample.disk_percent),
      load: avg(sample.load_one),
      light: avg(sample.active_light_agents),
      heavy: avg(sample.active_heavy_agents),
      operations: avg(sample.active_operations),
      samples: count(sample.id)
    })
    |> Repo.all()
    |> Map.new(fn row -> {row.at, row} end)
  end
end
