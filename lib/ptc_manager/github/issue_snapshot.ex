defmodule PtcManager.GitHub.IssueSnapshot do
  @moduledoc "Builds the canonical issue version used by sync and dispatch freshness checks."

  def normalize!(remote, repository_id) when is_map(remote) do
    body = remote["body"] || ""
    state = remote["state"] || "open"
    updated_at = parse_datetime!(remote["updated_at"])

    canonical = %{
      "body" => body,
      "number" => remote["number"],
      "state" => state,
      "title" => remote["title"],
      "updated_at" => DateTime.to_iso8601(updated_at)
    }

    %{
      repository_id: repository_id,
      number: remote["number"],
      title: remote["title"],
      html_url: remote["html_url"],
      body: body,
      state: state,
      body_digest: digest(body),
      content_digest: canonical |> Jason.encode!() |> digest(),
      github_updated_at: updated_at
    }
  end

  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp parse_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _ -> raise ArgumentError, "invalid GitHub updated_at"
    end
  end

  defp parse_datetime!(_value), do: raise(ArgumentError, "missing GitHub updated_at")
end
