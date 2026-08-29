defmodule PtcManager.GitHub.IssueSnapshot do
  @moduledoc "Builds the canonical issue version used by sync and dispatch freshness checks."

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

    %{
      repository_id: repository_id,
      number: remote["number"],
      title: remote["title"],
      html_url: remote["html_url"],
      body: body,
      state: state,
      workflow_label: workflow_label,
      workflow_label_conflict: workflow_label_conflict,
      body_digest: digest(body),
      content_digest: canonical |> Jason.encode!() |> digest(),
      github_updated_at: updated_at
    }
  end

  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

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
