defmodule PtcManager.HostMetrics do
  @moduledoc "Reads bounded host-capacity signals for the maintainer operations view."

  @type cpu_sample :: %{total: non_neg_integer(), idle: non_neg_integer()}

  def snapshot(previous_cpu_sample \\ nil) do
    cpu_sample = cpu_sample()
    memory = memory()
    disk = disk()

    %{
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second),
      cpu_percent: cpu_percent(previous_cpu_sample, cpu_sample),
      cpu_sample: cpu_sample,
      load_average: load_average(),
      cores: System.schedulers_online(),
      memory_used_bytes: memory.used,
      memory_total_bytes: memory.total,
      memory_percent: percent(memory.used, memory.total),
      disk_used_bytes: disk.used,
      disk_total_bytes: disk.total,
      disk_percent: percent(disk.used, disk.total),
      disk_path: disk.path
    }
  end

  defp cpu_sample do
    with {:ok, contents} <- File.read("/proc/stat"),
         line when is_binary(line) <- contents |> String.split("\n") |> List.first(),
         ["cpu" | values] <- String.split(line),
         numbers when length(numbers) >= 4 <- Enum.map(values, &String.to_integer/1) do
      idle = Enum.at(numbers, 3, 0) + Enum.at(numbers, 4, 0)
      %{total: Enum.sum(numbers), idle: idle}
    else
      _failure -> nil
    end
  rescue
    _error -> nil
  end

  defp cpu_percent(%{total: previous_total, idle: previous_idle}, %{total: total, idle: idle}) do
    total_delta = total - previous_total
    idle_delta = idle - previous_idle

    if total_delta > 0 do
      ((total_delta - idle_delta) * 100 / total_delta) |> clamp_percent() |> Float.round(1)
    end
  end

  defp cpu_percent(_previous, _current), do: nil

  defp memory do
    values =
      case File.read("/proc/meminfo") do
        {:ok, contents} ->
          Map.new(String.split(contents, "\n", trim: true), fn line ->
            case Regex.run(~r/^([^:]+):\s+(\d+)\s+kB$/, line, capture: :all_but_first) do
              [key, value] -> {key, String.to_integer(value) * 1_024}
              _other -> {line, 0}
            end
          end)

        _failure ->
          %{}
      end

    total = Map.get(values, "MemTotal", 0)
    available = Map.get(values, "MemAvailable", total)
    %{total: total, used: max(total - available, 0)}
  rescue
    _error -> %{total: 0, used: 0}
  end

  defp disk do
    path = disk_path()

    case System.cmd("df", ["-Pk", path], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_filesystem, total_kb, used_kb, _available, _capacity | _mountpoint] ->
            %{
              total: String.to_integer(total_kb) * 1_024,
              used: String.to_integer(used_kb) * 1_024,
              path: path
            }

          _unexpected ->
            %{total: 0, used: 0, path: path}
        end

      _failure ->
        %{total: 0, used: 0, path: path}
    end
  rescue
    _error -> %{total: 0, used: 0, path: disk_path()}
  end

  defp disk_path do
    Application.get_env(:ptc_manager, :worktree_root) ||
      Application.get_env(:ptc_manager, :repository_path) || "/"
  end

  defp load_average do
    with {:ok, contents} <- File.read("/proc/loadavg"),
         [one, five, fifteen | _rest] <- String.split(contents) do
      %{one: String.to_float(one), five: String.to_float(five), fifteen: String.to_float(fifteen)}
    else
      _failure -> nil
    end
  rescue
    _error -> nil
  end

  defp percent(_used, 0), do: nil
  defp percent(used, total), do: (used * 100 / total) |> clamp_percent() |> Float.round(1)
  defp clamp_percent(value), do: value |> max(0.0) |> min(100.0)
end
