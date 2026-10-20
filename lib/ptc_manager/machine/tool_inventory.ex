defmodule PtcManager.Machine.ToolInventory do
  @moduledoc """
  Parses one execution context's probe snapshot into evaluated tool lines.

  The probe script records raw exit statuses and output; this module decides
  what they mean. A tool is `ok` when its probe exited 0, `failed` when it ran
  and exited otherwise (for `docker-daemon` that means the daemon is not
  reachable), `missing` when the executable was not found, `timed_out`, or
  `error` for any other spawn failure. Versions are normalized to semver
  (`v1.2` becomes `1.2.0`) so requirements compare with `Version.match?/2`.
  The snapshot is written by the job identity, so it is data: unknown probes
  are ignored and every string is bounded.
  """

  alias PtcManager.Machine.ToolProbes

  @contexts ~w(pane setup)
  @detail_limit 200

  def contexts, do: @contexts

  @doc "Parses a decoded snapshot document for `context` against the catalog."
  def parse(document, context, catalog \\ ToolProbes.catalog())

  def parse(%{"probes" => probes, "captured_at" => captured_at} = document, context, catalog)
      when is_list(probes) and context in @contexts do
    with true <- is_binary(captured_at),
         {:ok, captured_at, _offset} <- DateTime.from_iso8601(captured_at) do
      results =
        for %{"name" => name} = result when is_binary(name) <- probes,
            into: %{},
            do: {name, result}

      {:ok,
       %{
         context: context,
         captured_at: DateTime.truncate(captured_at, :second),
         os: bounded(document["os"], 32),
         arch: bounded(document["arch"], 32),
         cpu_count: non_negative(document["cpu_count"]),
         memory_bytes: non_negative(document["memory_bytes"]),
         disk_free_bytes: non_negative(document["disk_free_bytes"]),
         tools:
           Map.new(catalog, fn probe ->
             {probe.name, tool(Map.get(results, probe.name), probe)}
           end)
       }}
    else
      _invalid -> {:error, :invalid_captured_at}
    end
  end

  def parse(_document, _context, _catalog), do: {:error, :invalid_snapshot}

  defp tool(nil, _probe), do: %{status: "not_probed", version: nil, detail: nil}

  defp tool(%{"error" => "not_found"}, _probe),
    do: %{status: "missing", version: nil, detail: "not found on PATH"}

  defp tool(%{"error" => error}, _probe) when is_binary(error) and error != "",
    do: %{status: "error", version: nil, detail: bounded(error, @detail_limit)}

  defp tool(%{"timed_out" => true}, _probe),
    do: %{status: "timed_out", version: nil, detail: "timed out"}

  defp tool(%{"exit_status" => 0} = result, probe) do
    output = string(result["stdout"]) <> "\n" <> string(result["stderr"])
    %{status: "ok", version: version(output, probe.version_regex), detail: nil}
  end

  defp tool(%{"exit_status" => status} = result, _probe) when is_integer(status) do
    detail =
      [result["stderr"], result["stdout"]]
      |> Enum.map(&first_line/1)
      |> Enum.find(&(&1 != ""))

    %{status: "failed", version: nil, detail: bounded("exit #{status}: #{detail}", @detail_limit)}
  end

  defp tool(_result, _probe), do: %{status: "error", version: nil, detail: "invalid result"}

  @doc "Extracts and normalizes the first version the probe's expression captures."
  def version(output, regex) when is_binary(output) and is_binary(regex) do
    with {:ok, expression} <- Regex.compile(regex),
         [_match, captured | _rest] <- Regex.run(expression, output) do
      normalize_version(captured)
    else
      [match] -> normalize_version(match)
      _no_version -> nil
    end
  end

  @doc "`v1.2` -> `1.2.0`; `1.2.3-desktop.2` keeps its pre-release; nonsense -> nil."
  def normalize_version(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim_leading("v")

    value =
      case Regex.run(~r/\A(\d+)\.(\d+)(.*)\z/s, value) do
        [_all, major, minor, rest] ->
          if String.starts_with?(rest, "."), do: value, else: "#{major}.#{minor}.0#{rest}"

        _other ->
          value
      end

    case Version.parse(value) do
      {:ok, version} -> to_string(version)
      :error -> nil
    end
  end

  def normalize_version(_value), do: nil

  @doc "Whether a context snapshot is older than the allowed age."
  def stale?(%{captured_at: captured_at}, now, max_age_ms) do
    DateTime.diff(now, captured_at, :millisecond) > max_age_ms
  end

  def stale?(_context, _now, _max_age_ms), do: true

  def max_age_ms,
    do: Application.get_env(:ptc_manager, :tool_inventory_max_age_ms, 1_800_000)

  @doc """
  A JSON-shaped summary of parsed contexts, the form both this console and a
  peer's status document render: `%{context => nil | %{"captured_at", "stale",
  "os", "arch", "cpu_count", "memory_bytes", "disk_free_bytes", "tools"}}`.
  """
  def summary(contexts, now \\ DateTime.utc_now(), max_age_ms \\ max_age_ms()) do
    Map.new(@contexts, fn context ->
      case Map.get(contexts, context) do
        nil ->
          {context, nil}

        parsed ->
          {context,
           %{
             "captured_at" => DateTime.to_iso8601(parsed.captured_at),
             "stale" => stale?(parsed, now, max_age_ms),
             "os" => parsed.os,
             "arch" => parsed.arch,
             "cpu_count" => parsed.cpu_count,
             "memory_bytes" => parsed.memory_bytes,
             "disk_free_bytes" => parsed.disk_free_bytes,
             "tools" =>
               Map.new(parsed.tools, fn {name, tool} ->
                 {name,
                  %{"status" => tool.status, "version" => tool.version, "detail" => tool.detail}}
               end)
           }}
      end
    end)
  end

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""

  defp first_line(value) when is_binary(value),
    do: value |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp first_line(_value), do: ""

  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded(_value, _limit), do: nil

  defp non_negative(value) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value), do: nil
end
