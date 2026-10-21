defmodule PtcManager.Cluster.Overview do
  @moduledoc """
  The whole cluster from this member's point of view, built from its own
  status document and the poller's memory of every peer's. Pure: it reads
  nothing and decides nothing, so pages and the operator state can share it.
  """

  alias PtcManager.Machine.{Requirements, ToolInventory}

  @doc """
  `machines` is a list of `%{id, health, status, error, last_success_at}`, this
  member first. Returns repositories, each with its home, requirement result
  on every member, and live work; and the drift between members.
  """
  def build(machines, now \\ DateTime.utc_now()) do
    %{repositories: repositories(machines, now), drift: drift(machines)}
  end

  defp repositories(machines, now) do
    inventories =
      Map.new(machines, fn machine ->
        {machine.id, %{contexts: ToolInventory.from_summary(status(machine)["inventory"])}}
      end)

    machines
    |> Enum.flat_map(fn machine ->
      for repository <- List.wrap(status(machine)["repositories"]),
          do: {repository["repository"], machine.id, repository}
    end)
    |> Enum.group_by(&elem(&1, 0), fn {_key, id, repository} -> {id, repository} end)
    |> Enum.map(fn {key, entries} ->
      claims = Map.new(entries)
      homes = for {id, %{"claim" => claim}} <- claims, claim not in [nil, "none"], do: id

      # The requirements that count are the home's; without a home, any copy.
      requirements =
        case homes do
          [home | _rest] -> claims[home]["requirements"]
          [] -> entries |> List.first() |> elem(1) |> Map.get("requirements")
        end

      %{
        key: key,
        claims: claims,
        homes: Enum.sort(homes),
        requirements: List.wrap(requirements),
        results:
          Map.new(machines, fn machine ->
            evaluation =
              Requirements.evaluate(
                %{"tools" => List.wrap(requirements)},
                inventories[machine.id],
                now
              )

            {machine.id,
             %{satisfied?: evaluation.satisfied?, reason: Requirements.explain(evaluation)}}
          end),
        work:
          Enum.flat_map(machines, fn machine ->
            for item <-
                  List.wrap(status(machine)["jobs"]) ++
                    List.wrap(status(machine)["collection_runs"]),
                item["repository"] == key,
                do: Map.put(item, "machine_id", machine.id)
          end)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Differences that matter between members, flagged and never synced:
  membership revision, protocol version, and execution profiles; deployed
  revisions are listed when they differ. Capacity is expected to differ.
  """
  def drift([local | peers]) do
    mine = status(local)

    Enum.flat_map(peers, fn peer ->
      theirs = status(peer)

      if theirs == %{} do
        []
      else
        [
          differs(
            peer,
            "membership revision",
            mine["membership_revision"],
            theirs["membership_revision"],
            true
          ),
          differs(
            peer,
            "protocol version",
            mine["protocol_version"],
            theirs["protocol_version"],
            true
          ),
          differs(peer, "deployed revision", mine["deployed_sha"], theirs["deployed_sha"], false)
        ] ++
          profile_drift(
            peer,
            mine["execution_profiles"] || %{},
            theirs["execution_profiles"] || %{}
          )
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def drift([]), do: []

  defp profile_drift(peer, mine, theirs) do
    for name <- Enum.sort(Enum.uniq(Map.keys(mine) ++ Map.keys(theirs))),
        mine[name] != theirs[name],
        do: %{
          member: peer.id,
          kind: "execution profile #{name}",
          here: short(mine[name]),
          there: short(theirs[name]),
          flagged?: true
        }
  end

  defp differs(_peer, _kind, same, same, _flagged?), do: nil

  defp differs(peer, kind, here, there, flagged?),
    do: %{member: peer.id, kind: kind, here: short(here), there: short(there), flagged?: flagged?}

  defp short(value) when is_binary(value), do: String.slice(value, 0, 12)
  defp short(nil), do: "missing"
  defp short(value), do: to_string(value)

  defp status(%{status: status}) when is_map(status), do: status
  defp status(_machine), do: %{}
end
