defmodule PtcManager.GitHub.IssueSnapshot do
  @moduledoc "Builds the canonical issue version used by sync and dispatch freshness checks."

  @max_projected_dependencies 100

  def normalize!(remote, repository_id) when is_map(remote) do
    body = remote["body"] || ""
    state = remote["state"] || "open"

    {workflow_label, workflow_label_conflict, workflow_labels} =
      workflow_label(remote["labels"] || [])

    updated_at = parse_datetime!(remote["updated_at"])

    canonical = %{
      "body" => body,
      "number" => remote["number"],
      "state" => state,
      "title" => remote["title"],
      "workflow_labels" => workflow_labels,
      "updated_at" => DateTime.to_iso8601(updated_at)
    }

    blocking_issue_numbers = blocking_issue_numbers(body, remote["number"])

    %{
      repository_id: repository_id,
      number: remote["number"],
      title: remote["title"],
      html_url: remote["html_url"],
      body: body,
      state: state,
      workflow_label: workflow_label,
      workflow_label_conflict: workflow_label_conflict,
      blocking_issue_numbers: Enum.take(blocking_issue_numbers, @max_projected_dependencies),
      dependency_overflow: length(blocking_issue_numbers) > @max_projected_dependencies,
      dependencies_projected: true,
      body_digest: digest(body),
      content_digest: canonical |> Jason.encode!() |> digest(),
      github_updated_at: updated_at
    }
  end

  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  def blocking_issue_numbers(body, issue_number) when is_binary(body) do
    ~r/\bblocked\s+by\s+#(\d+)\b/i
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [number] -> String.to_integer(number) end)
    |> Enum.filter(&(&1 > 0 and &1 <= 2_147_483_647 and &1 != issue_number))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def blocking_issue_numbers(_body, _issue_number), do: []

  def projected_blocking_issue_numbers(body, issue_number) do
    body
    |> blocking_issue_numbers(issue_number)
    |> Enum.take(@max_projected_dependencies)
  end

  defp workflow_label(labels) when is_list(labels) do
    managed =
      labels
      |> Enum.map(fn
        %{"name" => name} -> name
        name when is_binary(name) -> name
        _label -> nil
      end)
      |> Enum.filter(&(&1 in ["ptc:ready", "ptc:blocked", "ptc:needs-decision"]))
      |> Enum.uniq()
      |> Enum.sort()

    case managed do
      [label] -> {label, false, managed}
      [] -> {nil, false, managed}
      _labels -> {nil, true, managed}
    end
  end

  defp workflow_label(_labels), do: {nil, false, []}

  defp parse_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _ -> raise ArgumentError, "invalid GitHub updated_at"
    end
  end

  defp parse_datetime!(_value), do: raise(ArgumentError, "missing GitHub updated_at")
end
