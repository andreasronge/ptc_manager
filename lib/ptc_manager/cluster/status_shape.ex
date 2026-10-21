defmodule PtcManager.Cluster.StatusShape do
  @moduledoc """
  Normalizes a peer's status document into the shape every consumer expects.

  `PtcManager.Cluster.Peer` has already refused a document whose ownership data
  is malformed. Everything else is display data from another machine, so a
  field of the wrong type becomes `nil` or is dropped here, once, and no page
  can be broken by one member's document.
  """

  def normalize(status) when is_map(status) do
    status
    |> Map.take(~w(protocol_version machine_id membership_revision intents _clock_skew_s))
    |> Map.merge(%{
      "machine_name" => string(status["machine_name"]),
      "os" => string(status["os"]),
      "captured_at" => string(status["captured_at"]),
      "deployed_sha" => string(status["deployed_sha"]),
      "operational_mode" => string(status["operational_mode"]),
      "inventory" => inventory(status["inventory"]),
      "agent_logins" => string_map(status["agent_logins"]),
      "execution_profiles" => string_map(status["execution_profiles"]),
      "capacity" => numbers(status["capacity"]),
      "repositories" => Enum.map(status["repositories"], &repository/1),
      "jobs" => work(status["jobs"]),
      "collection_runs" => work(status["collection_runs"])
    })
  end

  defp repository(repository) do
    %{
      "repository" => repository["repository"],
      "claim" => repository["claim"],
      "enabled" => repository["enabled"] == true,
      "claim_blockers" => strings(repository["claim_blockers"]),
      "requirements" => requirements(repository["requirements"]),
      "requirements_revision" => string(repository["requirements_revision"]),
      "console_url" => string(repository["console_url"])
    }
  end

  defp requirements(lines) when is_list(lines) do
    for %{"name" => name} = line when is_binary(name) <- lines do
      case line["version"] do
        # An unparsable requirement is kept as written: evaluation fails it.
        version when is_binary(version) ->
          %{"name" => name, "version" => version}

        _none ->
          %{"name" => name}
      end
    end
  end

  defp requirements(_lines), do: []

  defp work(items) when is_list(items) do
    for %{"repository" => repository} = item when is_binary(repository) <- items do
      %{
        "id" => integer(item["id"]),
        "repository" => repository,
        "issue_number" => integer(item["issue_number"]),
        "state" => string(item["state"]),
        "url" => string(item["url"])
      }
    end
  end

  defp work(_items), do: []

  defp inventory(inventory) when is_map(inventory) do
    Map.new(~w(pane setup), fn context -> {context, context(inventory[context])} end)
  end

  defp inventory(_inventory), do: %{"pane" => nil, "setup" => nil}

  defp context(%{"captured_at" => captured_at, "tools" => tools} = context)
       when is_binary(captured_at) and is_map(tools) do
    %{
      "captured_at" => captured_at,
      "stale" => context["stale"] == true,
      "os" => string(context["os"]),
      "arch" => string(context["arch"]),
      "cpu_count" => integer(context["cpu_count"]),
      "memory_bytes" => integer(context["memory_bytes"]),
      "disk_free_bytes" => integer(context["disk_free_bytes"]),
      "tools" => tools(tools)
    }
  end

  defp context(_context), do: nil

  defp tools(tools) do
    for {name, %{"status" => status} = tool} when is_binary(name) and is_binary(status) <- tools,
        into: %{} do
      {name,
       %{
         "status" => status,
         "version" => string(tool["version"]),
         "detail" => string(tool["detail"])
       }}
    end
  end

  defp numbers(map) when is_map(map) do
    for {key, value} when is_binary(key) and is_number(value) <- map, into: %{}, do: {key, value}
  end

  defp numbers(_map), do: %{}

  defp string_map(map) when is_map(map) do
    for {key, value} when is_binary(key) and is_binary(value) <- map, into: %{}, do: {key, value}
  end

  defp string_map(_map), do: %{}

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_list), do: []

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil
end
