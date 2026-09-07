defmodule PtcManager.Reviews.Requirements do
  @moduledoc "Bounded issue-linked evidence fetched through the read-only GitHub boundary."
  alias PtcManager.Reviews.Context

  def capture(job, client \\ Application.fetch_env!(:ptc_manager, :github_client)) do
    repository = job.repository
    scope = {String.downcase(repository.github_owner), String.downcase(repository.github_name)}
    root = {elem(scope, 0), elem(scope, 1), {:issue, job.issue.number}}
    frozen = job.execution_settings["issue_body"] || job.issue.body || ""
    collect([root], MapSet.new(), [], frozen, client, 9, scope)
  end

  defp collect([], _seen, texts, _frozen, _client, _left, _scope),
    do: {:ok, Enum.join(Enum.reverse(texts), "\n\n")}

  defp collect(_pending, _seen, texts, _frozen, _client, 0, _scope),
    do:
      {:ok,
       Enum.join(
         Enum.reverse(["Additional linked context omitted after the nine-source limit." | texts]),
         "\n\n"
       )}

  defp collect([reference | rest], seen, texts, frozen, client, left, scope) do
    if MapSet.member?(seen, reference) do
      collect(rest, seen, texts, frozen, client, left, scope)
    else
      {owner, name, target} = reference
      repository = %PtcManager.Operations.Repository{github_owner: owner, github_name: name}

      if {String.downcase(owner), String.downcase(name)} != scope do
        note =
          "Linked context outside the approved repository was not fetched: #{owner}/#{name} #{inspect(target)}"

        collect(rest, MapSet.put(seen, reference), [note | texts], "", client, left - 1, scope)
      else
        case client.review_context(repository, target) do
          {:ok, data} ->
            source = render(data)
            links = references(frozen, owner, name) ++ references(source, owner, name)

            collect(
              rest ++ links,
              MapSet.put(seen, reference),
              [source | texts],
              "",
              client,
              left - 1,
              scope
            )

          {:error, _} ->
            {:error, {:review_requirements_unavailable, owner <> "/" <> name, inspect(target)}}
        end
      end
    end
  end

  def references(text, owner, name) do
    urls =
      Regex.scan(
        ~r{https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/(?:issues|pull)/([1-9][0-9]*)},
        text
      )
      |> Enum.map(fn [_, owner, name, number] ->
        {owner, name, {:issue, String.to_integer(number)}}
      end)

    local =
      Regex.scan(~r{(?<![\w/])#([1-9][0-9]*)\b}, text)
      |> Enum.map(fn [_, number] -> {owner, name, {:issue, String.to_integer(number)}} end)

    blobs =
      Regex.scan(
        ~r{https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/blob/([^\s<>()#?]+)},
        text
      )
      |> Enum.flat_map(fn [_, owner, name, path] ->
        path = path |> String.replace(~r/[.,;:!"'\]\}]+$/, "") |> URI.decode()

        if String.valid?(path) and String.contains?(path, "/"),
          do: [{owner, name, {:blob, path}}],
          else: []
      end)

    Enum.uniq(urls ++ local ++ blobs)
  end

  defp render(data) do
    comments = get_in(data, ["comments", "nodes"]) || []

    [
      data["url"] || "Linked repository document",
      data["title"] || "",
      Context.bounded(data["body"] || data["text"] || "", 20_000),
      Enum.map_join(Enum.take(comments, 20), "\n", fn comment ->
        "#{comment["url"]}\n" <> Context.bounded(comment["body"] || "", 2_000)
      end),
      if(get_in(data, ["comments", "pageInfo", "hasPreviousPage"]),
        do: "Earlier comments omitted.",
        else: ""
      )
    ]
    |> Enum.join("\n")
  end
end
