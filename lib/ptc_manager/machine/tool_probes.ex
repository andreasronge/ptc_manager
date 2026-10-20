defmodule PtcManager.Machine.ToolProbes do
  @moduledoc """
  The catalog of tool probes the inventory runs.

  Each probe is an argv list run without a shell, plus the regular expression
  whose first capture group is the version. The built-in catalog covers the
  tools repository gates have needed; `PTC_TOOL_PROBES_JSON` adds more, so a
  new tool needs no code change and the console never stores a command.
  """

  @max_probes 24
  @max_argv 16
  @name_pattern ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @version ~S"(\d+\.\d+(?:\.\d+)?)"

  @built_in [
    # `docker version` contacts the daemon even for the client half, so the
    # client is probed without it.
    %{name: "docker", argv: ["docker", "--version"], version_regex: ~S"version (\d+\.\d+\.\d+)"},
    # The server half answers only when the identity can reach the daemon, so
    # exit 0 here is the reachability test that `docker` alone cannot give.
    %{
      name: "docker-daemon",
      argv: ["docker", "version", "--format", "{{.Server.Version}}"],
      version_regex: @version
    },
    %{
      name: "docker-compose",
      argv: ["docker", "compose", "version", "--short"],
      version_regex: @version
    },
    %{name: "deno", argv: ["deno", "--version"], version_regex: ~S"deno (\d+\.\d+\.\d+)"},
    %{name: "elixir", argv: ["elixir", "--version"], version_regex: ~S"Elixir (\d+\.\d+\.\d+)"},
    %{name: "node", argv: ["node", "--version"], version_regex: @version},
    %{name: "git", argv: ["git", "--version"], version_regex: @version},
    %{name: "gh", argv: ["gh", "--version"], version_regex: ~S"gh version (\d+\.\d+\.\d+)"},
    %{name: "psql", argv: ["psql", "--version"], version_regex: @version},
    %{
      name: "redis-server",
      argv: ["redis-server", "--version"],
      version_regex: ~S"v=(\d+\.\d+\.\d+)"
    },
    %{name: "cerbos", argv: ["cerbos", "--version"], version_regex: @version}
  ]

  def max_probes, do: @max_probes

  @doc "The built-in probes plus the configured extras, in catalog order."
  def catalog do
    case validate_extra(Application.get_env(:ptc_manager, :tool_probes_extra, [])) do
      {:ok, extra} -> @built_in ++ extra
      {:error, reason} -> raise ArgumentError, "invalid PTC_TOOL_PROBES_JSON: #{reason}"
    end
  end

  def names, do: Enum.map(catalog(), & &1.name)

  def known?(name), do: name in names()

  def fetch(name), do: Enum.find(catalog(), &(&1.name == name))

  @doc "The document the probe script reads: names and argv, never regexes."
  def catalog_document do
    %{probes: Enum.map(catalog(), &Map.take(&1, [:name, :argv]))}
  end

  @doc """
  Validates extra probes decoded from `PTC_TOOL_PROBES_JSON`: a list of objects
  with `name`, `argv`, and `version_regex`.
  """
  def validate_extra(nil), do: {:ok, []}

  def validate_extra(extra) when is_list(extra) do
    built_in = Enum.map(@built_in, & &1.name)

    extra
    |> Enum.reduce_while({:ok, [], built_in}, fn probe, {:ok, probes, seen} ->
      case validate_probe(probe, seen) do
        {:ok, probe} -> {:cont, {:ok, [probe | probes], [probe.name | seen]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, probes, _seen} when length(probes) + length(@built_in) > @max_probes ->
        {:error, "the catalog holds at most #{@max_probes} probes"}

      {:ok, probes, _seen} ->
        {:ok, Enum.reverse(probes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_extra(_extra), do: {:error, "expected a JSON array of probes"}

  defp validate_probe(%{"name" => name, "argv" => argv, "version_regex" => regex}, seen) do
    cond do
      not (is_binary(name) and Regex.match?(@name_pattern, name)) ->
        {:error, "probe names are lowercase letters, digits, and hyphens"}

      name in seen ->
        {:error, "probe #{name} is defined twice"}

      not (is_list(argv) and argv != [] and length(argv) <= @max_argv and
               Enum.all?(argv, &(is_binary(&1) and &1 != ""))) ->
        {:error, "probe #{name} needs an argv of 1 to #{@max_argv} nonblank strings"}

      not (is_binary(regex) and match?({:ok, _}, Regex.compile(regex))) ->
        {:error, "probe #{name} has an invalid version_regex"}

      true ->
        {:ok, %{name: name, argv: argv, version_regex: regex}}
    end
  end

  defp validate_probe(_probe, _seen),
    do: {:error, "each probe needs name, argv, and version_regex"}
end
