defmodule PtcManager.Machine.Requirements do
  @moduledoc """
  The tools a repository's work needs, and whether this machine has them.

  Requirements are repository configuration in PtcManager, never content of
  the managed repository: `repositories.machine_requirements` holds
  `%{"tools" => [%{"name" => "docker-daemon"}, %{"name" => "docker-compose",
  "version" => ">= 2.24.0"}]}`. A line without `version` asks that the probe
  exited 0.

  `evaluate/3` is pure. A line is satisfied only when every execution context
  satisfies it, since agents and workspace setup both run repository commands.
  A failing context carries one reason: `no_inventory` (never probed), `stale`
  (probed too long ago), `missing` (not installed), `unreachable` (installed,
  but the probe failed or timed out, as `docker-daemon` does without daemon
  access), or `version` (present, but outside the requirement).
  """

  import Ecto.Changeset

  alias PtcManager.Machine.{ToolInventory, ToolProbes}

  @max_lines 20

  def empty, do: %{"tools" => []}

  def max_lines, do: @max_lines

  @doc "The requirement lines of a stored value; anything unreadable counts as none."
  def lines(%{"tools" => tools}) when is_list(tools), do: tools
  def lines(_requirements), do: []

  def any?(requirements), do: lines(requirements) != []

  @doc "A short stable digest of the requirements, for placement evidence and peers."
  def revision(requirements) do
    requirements
    |> lines()
    |> Enum.map(&[&1["name"], &1["version"]])
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Builds the stored value from submitted lines, dropping blank version fields.
  Validation is the changeset's.
  """
  def normalize(lines) when is_list(lines) do
    %{
      "tools" =>
        Enum.map(lines, fn line ->
          name = line |> Map.get("name", "") |> to_string() |> String.trim()
          version = line |> Map.get("version", "") |> to_string() |> String.trim()
          if version == "", do: %{"name" => name}, else: %{"name" => name, "version" => version}
        end)
    }
  end

  @doc "Validates the `:machine_requirements` field of a repository changeset."
  def validate(changeset) do
    validate_change(changeset, :machine_requirements, fn :machine_requirements, value ->
      case validation_error(value) do
        nil -> []
        message -> [machine_requirements: message]
      end
    end)
  end

  defp validation_error(%{"tools" => tools} = value)
       when is_list(tools) and map_size(value) == 1 do
    names = Enum.map(tools, &(is_map(&1) && &1["name"]))

    cond do
      length(tools) > @max_lines ->
        "may list at most #{@max_lines} tools"

      length(Enum.uniq(names)) != length(names) ->
        "lists a tool twice"

      true ->
        Enum.find_value(tools, &line_error/1)
    end
  end

  defp validation_error(_value), do: "must be a list of tool requirements"

  defp line_error(%{"name" => name} = line) when is_binary(name) do
    extra = Map.keys(line) -- ["name", "version"]

    cond do
      extra != [] ->
        "has an unknown field"

      not ToolProbes.known?(name) ->
        "names #{inspect(name)}, which no probe checks"

      Map.has_key?(line, "version") and
          not (is_binary(line["version"]) and
                   match?({:ok, _}, Version.parse_requirement(line["version"]))) ->
        "has an invalid version requirement for #{name} (use for example >= 2.24.0)"

      true ->
        nil
    end
  end

  defp line_error(_line), do: "has a line without a tool name"

  @doc """
  Evaluates requirements against an inventory (`PtcManager.Machine.Inventory.current/0`).

  Returns `%{satisfied?: boolean, lines: [%{"name", "version", "satisfied",
  "failures" => [%{"context", "reason", "detail"}]}]}`.
  """
  def evaluate(requirements, inventory, now \\ DateTime.utc_now()) do
    max_age_ms = ToolInventory.max_age_ms()

    lines =
      for line <- lines(requirements) do
        failures =
          Enum.flat_map(ToolInventory.contexts(), fn context ->
            case context_failure(line, Map.get(inventory.contexts, context), now, max_age_ms) do
              nil -> []
              failure -> [Map.put(failure, "context", context)]
            end
          end)

        %{
          "name" => line["name"],
          "version" => line["version"],
          "satisfied" => failures == [],
          "failures" => failures
        }
      end

    %{satisfied?: Enum.all?(lines, & &1["satisfied"]), lines: lines}
  end

  defp context_failure(_line, nil, _now, _max_age_ms),
    do: %{"reason" => "no_inventory", "detail" => nil}

  defp context_failure(line, parsed, now, max_age_ms) do
    if ToolInventory.stale?(parsed, now, max_age_ms) do
      %{"reason" => "stale", "detail" => DateTime.to_iso8601(parsed.captured_at)}
    else
      tool_failure(line, Map.get(parsed.tools, line["name"]))
    end
  end

  defp tool_failure(_line, nil), do: %{"reason" => "no_inventory", "detail" => nil}

  defp tool_failure(_line, %{status: "not_probed"}),
    do: %{"reason" => "no_inventory", "detail" => nil}

  defp tool_failure(_line, %{status: "missing"}), do: %{"reason" => "missing", "detail" => nil}

  defp tool_failure(%{"version" => requirement}, %{status: "ok", version: version})
       when is_binary(requirement) do
    # Both sides may come from another machine, so neither is trusted to parse.
    with true <- is_binary(version),
         {:ok, parsed_version} <- Version.parse(version),
         {:ok, parsed} <- Version.parse_requirement(requirement),
         true <- Version.match?(parsed_version, parsed) do
      nil
    else
      _mismatch -> %{"reason" => "version", "detail" => version}
    end
  end

  defp tool_failure(_line, %{status: "ok"}), do: nil
  defp tool_failure(_line, tool), do: %{"reason" => "unreachable", "detail" => tool[:detail]}

  @doc ~S"""
  One sentence for the first failing line, such as
  "docker-daemon not reachable (pane)", or nil when everything is satisfied.
  """
  def explain(%{lines: lines}) do
    lines
    |> Enum.reject(& &1["satisfied"])
    |> Enum.map(fn line ->
      contexts = line["failures"] |> Enum.map(& &1["context"]) |> Enum.join(", ")
      reason = line["failures"] |> List.first() |> Map.fetch!("reason")
      "#{line["name"]} #{reason_words(reason, line)} (#{contexts})"
    end)
    |> case do
      [] -> nil
      failures -> Enum.join(failures, "; ")
    end
  end

  defp reason_words("no_inventory", _line), do: "not probed yet"
  defp reason_words("stale", _line), do: "inventory is stale"
  defp reason_words("missing", _line), do: "not installed"
  defp reason_words("unreachable", _line), do: "not reachable"
  defp reason_words("version", line), do: "version does not match #{line["version"]}"
end
