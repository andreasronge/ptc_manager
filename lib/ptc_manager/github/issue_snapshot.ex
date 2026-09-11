defmodule PtcManager.GitHub.IssueSnapshot do
  @moduledoc "Builds the canonical issue version used by sync and dispatch freshness checks."

  alias PtcManager.Operations.Repository

  @max_projected_dependencies 100

  def normalize!(remote, %Repository{} = repository) when is_map(remote) do
    normalize!(remote, repository.id, repository_full_name(repository))
  end

  def normalize!(remote, repository_id) when is_map(remote) and is_integer(repository_id) do
    normalize!(remote, repository_id, issue_repository_full_name(remote))
  end

  defp normalize!(remote, repository_id, repository_full_name) do
    body = remote["body"] || ""
    state = remote["state"] || "open"

    {workflow_label, workflow_label_conflict, workflow_labels} =
      workflow_label(remote["labels"] || [])

    assignee_logins = assignee_logins(remote["assignees"] || [])

    updated_at = parse_datetime!(remote["updated_at"])
    created_at = parse_optional_datetime(remote["created_at"])
    blocking_issues = blocking_issues(remote, repository_full_name)
    dependency_unknown_count = normalize_unknown_count(remote["blocked_by_unknown_count"])

    dependency_overflow =
      remote["blocked_by_overflow"] == true or
        length(blocking_issues) > @max_projected_dependencies

    structure = structure(remote, repository_full_name)

    canonical =
      %{
        "body" => body,
        "number" => remote["number"],
        "state" => state,
        "title" => remote["title"],
        "workflow_labels" => workflow_labels,
        "updated_at" => DateTime.to_iso8601(updated_at)
      }
      |> maybe_put_assignees(assignee_logins)
      |> maybe_put_state_reason(normalize_state_reason(remote["state_reason"]))
      |> maybe_put_blockers(blocking_issues)
      |> maybe_put_dependency_counts(dependency_unknown_count, dependency_overflow)
      |> maybe_put_structure(structure)

    %{
      parent_issue_number: structure.parent_issue_number,
      sub_issues: structure.sub_issues,
      structure_projected: structure.structure_projected,
      repository_id: repository_id,
      number: remote["number"],
      title: remote["title"],
      html_url: remote["html_url"],
      body: body,
      state: state,
      github_state_reason: normalize_state_reason(remote["state_reason"]),
      workflow_label: workflow_label,
      workflow_label_conflict: workflow_label_conflict,
      github_assignees: %{"logins" => assignee_logins},
      github_assignment_projected: true,
      blocking_issues: Enum.take(blocking_issues, @max_projected_dependencies),
      dependency_overflow: dependency_overflow,
      dependency_unknown_count: dependency_unknown_count,
      dependencies_projected: true,
      body_digest: digest(body),
      content_digest: canonical |> Jason.encode!() |> digest(),
      github_author_login: author_login(remote["author_login"]),
      github_labels: %{"names" => label_names(remote["labels"] || [])},
      github_created_at: created_at,
      github_comment_count: comment_count(remote["comments"]),
      comments_checked_at:
        if(is_integer(comment_count(remote["comments"])), do: DateTime.utc_now()),
      github_updated_at: updated_at
    }
  end

  defp comment_count(n) when is_integer(n) and n >= 0, do: n
  defp comment_count(_), do: nil

  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  def blocking_issues(remote, default_repository_full_name) when is_map(remote) do
    remote
    |> Map.get("blocked_by")
    |> then(fn blockers -> if is_list(blockers), do: blockers, else: [] end)
    |> Enum.map(&normalize_blocker(&1, default_repository_full_name))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1.repository_full_name, &1.number})
    |> Enum.sort_by(&{&1.repository_full_name, &1.number})
  end

  def blocking_issues(_remote, _default_repository_full_name), do: []

  defp normalize_blocker(blocker, default_repository_full_name) when is_map(blocker) do
    with number when is_integer(number) and number > 0 <- blocker["number"],
         full_name when is_binary(full_name) <-
           issue_repository_full_name(blocker) || default_repository_full_name,
         normalized_full_name when normalized_full_name != "" <- normalize_full_name(full_name) do
      %{
        repository_full_name: normalized_full_name,
        number: number,
        github_id: blocker["id"],
        node_id: blocker["node_id"],
        title: blocker["title"],
        html_url:
          blocker["html_url"] || "https://github.com/#{normalized_full_name}/issues/#{number}",
        state: normalize_state(blocker["state"]),
        state_reason: normalize_state_reason(blocker["state_reason"])
      }
    else
      _invalid -> nil
    end
  end

  defp normalize_blocker(_blocker, _default_repository_full_name), do: nil

  defp issue_repository_full_name(%{"repository" => %{"full_name" => full_name}})
       when is_binary(full_name),
       do: normalize_full_name(full_name)

  defp issue_repository_full_name(%{"repository_url" => repository_url})
       when is_binary(repository_url) do
    case Regex.run(~r{/repos/([^/]+/[^/]+)$}, repository_url, capture: :all_but_first) do
      [full_name] -> normalize_full_name(full_name)
      _no_match -> nil
    end
  end

  defp issue_repository_full_name(%{"html_url" => html_url}) when is_binary(html_url) do
    case Regex.run(~r{github\.com/([^/]+/[^/]+)/issues/\d+}, html_url, capture: :all_but_first) do
      [full_name] -> normalize_full_name(full_name)
      _no_match -> nil
    end
  end

  defp issue_repository_full_name(_issue), do: nil

  defp repository_full_name(repository),
    do: normalize_full_name("#{repository.github_owner}/#{repository.github_name}")

  defp normalize_full_name(full_name), do: full_name |> String.trim() |> String.downcase()
  defp normalize_state(state) when state in ["open", "closed"], do: state
  defp normalize_state(_state), do: nil

  defp normalize_unknown_count(count) when is_integer(count) and count >= 0, do: count
  defp normalize_unknown_count(_count), do: 0

  defp normalize_state_reason(reason) when reason in ["completed", "not_planned", "duplicate"],
    do: reason

  defp normalize_state_reason(_reason), do: nil

  defp assignee_logins(assignees) when is_list(assignees) do
    assignees
    |> Enum.map(fn
      %{"login" => login} when is_binary(login) -> String.trim(login)
      _assignee -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp assignee_logins(_assignees), do: []

  defp maybe_put_assignees(canonical, []), do: canonical
  defp maybe_put_assignees(canonical, logins), do: Map.put(canonical, "assignees", logins)

  defp maybe_put_state_reason(canonical, nil), do: canonical
  defp maybe_put_state_reason(canonical, reason), do: Map.put(canonical, "state_reason", reason)

  defp maybe_put_blockers(canonical, []), do: canonical

  defp maybe_put_blockers(canonical, blockers) do
    Map.put(
      canonical,
      "blocked_by",
      Enum.map(blockers, fn blocker ->
        Map.take(blocker, [
          :repository_full_name,
          :number,
          :github_id,
          :node_id,
          :state,
          :state_reason
        ])
      end)
    )
  end

  @max_projected_sub_issues 100

  # Parent and sub-issue relations, projected only when GitHub answered them.
  # A cross-repository parent is recorded as "no same-repository parent", and a
  # sub-issue keeps its repository so a collection can refuse foreign members.
  defp structure(%{"structure_projected" => true} = remote, repository_full_name) do
    nodes =
      remote
      |> get_in(["sub_issues", "nodes"])
      |> then(fn nodes -> if is_list(nodes), do: nodes, else: [] end)
      |> Enum.map(&normalize_sub_issue(&1, repository_full_name))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&{&1["repository_full_name"], &1["number"]})
      |> Enum.sort_by(&{&1["repository_full_name"], &1["number"]})

    total =
      case get_in(remote, ["sub_issues", "total"]) do
        total when is_integer(total) and total >= length(nodes) -> total
        _total -> length(nodes)
      end

    overflow =
      get_in(remote, ["sub_issues", "overflow"]) == true or
        total > @max_projected_sub_issues or total > length(nodes)

    %{
      parent_issue_number: parent_issue_number(remote["parent"], repository_full_name),
      sub_issues: %{
        "nodes" => Enum.take(nodes, @max_projected_sub_issues),
        "total" => total,
        "overflow" => overflow
      },
      structure_projected: true
    }
  end

  defp structure(_remote, _repository_full_name) do
    %{
      parent_issue_number: nil,
      sub_issues: %{"nodes" => [], "total" => 0},
      structure_projected: false
    }
  end

  defp parent_issue_number(%{"number" => number} = parent, repository_full_name)
       when is_integer(number) and number > 0 do
    case issue_repository_full_name(parent) do
      nil -> number
      ^repository_full_name -> number
      _other_repository -> nil
    end
  end

  defp parent_issue_number(_parent, _repository_full_name), do: nil

  defp normalize_sub_issue(node, repository_full_name) when is_map(node) do
    with number when is_integer(number) and number > 0 <- node["number"],
         state when state in ["open", "closed"] <- normalize_state(node["state"]) do
      %{
        "number" => number,
        "state" => state,
        "state_reason" => normalize_state_reason(node["state_reason"]),
        "repository_full_name" => issue_repository_full_name(node) || repository_full_name
      }
    else
      _invalid -> nil
    end
  end

  defp normalize_sub_issue(_node, _repository_full_name), do: nil

  defp maybe_put_structure(canonical, %{structure_projected: false}), do: canonical

  defp maybe_put_structure(canonical, structure) do
    canonical
    |> then(fn canonical ->
      if structure.parent_issue_number,
        do: Map.put(canonical, "parent", structure.parent_issue_number),
        else: canonical
    end)
    |> then(fn canonical ->
      case structure.sub_issues["nodes"] do
        [] ->
          canonical

        nodes ->
          Map.put(
            canonical,
            "sub_issues",
            Enum.map(nodes, &Map.take(&1, ["repository_full_name", "number", "state"]))
          )
      end
    end)
  end

  defp maybe_put_dependency_counts(canonical, 0, false), do: canonical

  defp maybe_put_dependency_counts(canonical, unknown_count, overflow) do
    canonical
    |> Map.put("blocked_by_unknown_count", unknown_count)
    |> Map.put("blocked_by_overflow", overflow)
  end

  # GitHub matches label names case-insensitively, so `PTC:blocked` is the same
  # label as `ptc:blocked`. Recognising only the lowercase spelling would leave
  # such an issue with no workflow label at all, and every approval gate reads
  # `nil` as "GitHub says nothing", which is the opposite of blocked.
  defp workflow_label(labels) when is_list(labels) do
    managed =
      labels
      |> Enum.map(fn
        %{"name" => name} when is_binary(name) -> String.downcase(String.trim(name))
        name when is_binary(name) -> String.downcase(String.trim(name))
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

  # Also outside the canonical map. Only the three ptc: labels decide anything,
  # and `workflow_labels` already carries those into the content digest; a
  # maintainer's own label must not make every proposal stale.
  defp label_names(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.trim(name)
      name when is_binary(name) -> String.trim(name)
      _label -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp label_names(_labels), do: []

  # Also outside the canonical map: GitHub cannot change who opened an issue.
  defp author_login(login) when is_binary(login) do
    case String.trim(login) do
      "" -> nil
      login -> login
    end
  end

  defp author_login(_login), do: nil

  # Deliberately outside the canonical map: an issue's creation time never
  # changes, so it cannot make a proposal stale and must not enter the digest.
  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil
end
