defmodule PtcManager.Operations.DependencyGraph do
  @moduledoc false

  def cycles(issues) when is_list(issues) do
    graph =
      Map.new(issues, fn issue ->
        {issue_key(issue),
         Enum.map(issue.dependencies, fn dependency ->
           {dependency.blocking_repository_full_name, dependency.blocking_issue_number}
         end)}
      end)

    Map.new(issues, fn issue -> {issue.id, shortest_cycle(graph, issue_key(issue))} end)
  end

  defp shortest_cycle(graph, start) do
    graph
    |> Map.get(start, [])
    |> Enum.map(&shortest_path(graph, &1, start, [start, &1]))
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&length/1, fn -> nil end)
  end

  defp shortest_path(_graph, start, start, path), do: path

  defp shortest_path(graph, current, target, path) do
    queue = :queue.from_list([{current, path}])
    walk(graph, queue, MapSet.new(path), target)
  end

  defp walk(graph, queue, visited, target) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        nil

      {{:value, {current, path}}, rest} ->
        graph
        |> Map.get(current, [])
        |> Enum.reduce_while({rest, visited}, fn neighbor, {next_queue, seen} ->
          cond do
            neighbor == target ->
              {:halt, {:found, path ++ [target]}}

            MapSet.member?(seen, neighbor) ->
              {:cont, {next_queue, seen}}

            true ->
              {:cont,
               {:queue.in({neighbor, path ++ [neighbor]}, next_queue), MapSet.put(seen, neighbor)}}
          end
        end)
        |> case do
          {:found, cycle} -> cycle
          {next_queue, seen} -> walk(graph, next_queue, seen, target)
        end
    end
  end

  defp issue_key(issue) do
    {String.downcase("#{issue.repository.github_owner}/#{issue.repository.github_name}"),
     issue.number}
  end
end
