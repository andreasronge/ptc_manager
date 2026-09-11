defmodule PtcManager.Collections.Structure do
  @moduledoc """
  The deterministic shape a collection must have before PtcManager acts on it.

  A collection is an issue with GitHub sub-issues. Its members are the numbers
  GitHub reports as sub-issues; a member that PtcManager has synchronized also
  has an `issues` row, and one it has never seen open still counts through the
  node GitHub reported. The invariants here are checked after a structuring
  action, before a run starts, and when a maintainer accepts a changed
  membership, so every path agrees on what "well formed" means.
  """

  import Ecto.Query

  alias PtcManager.Operations.{DependencyGraph, Issue, IssueDependency, Repository}
  alias PtcManager.Repo

  @type member :: %{
          number: pos_integer(),
          state: String.t(),
          state_reason: String.t() | nil,
          repository_full_name: String.t(),
          issue: Issue.t() | nil
        }

  @doc "Every member GitHub reports, joined with its synchronized row when one exists."
  @spec members(Issue.t()) :: [member()]
  def members(%Issue{} = umbrella) do
    nodes = Issue.sub_issue_nodes(umbrella)
    numbers = Enum.map(nodes, & &1["number"])

    rows =
      Issue
      |> where(
        [issue],
        issue.repository_id == ^umbrella.repository_id and issue.number in ^numbers
      )
      |> preload([:repository, :dependencies])
      |> Repo.all()
      |> Map.new(&{&1.number, &1})

    Enum.map(nodes, fn node ->
      %{
        number: node["number"],
        state: node["state"],
        state_reason: node["state_reason"],
        repository_full_name: node["repository_full_name"],
        issue: Map.get(rows, node["number"])
      }
    end)
  end

  @doc """
  Checks the structure invariants of one collection.

  Same repository, no nested collection, no overflow, a workflow label on every
  open member, blockers that are members or closed issues, and no cycle. The
  first failing invariant is returned so the console can name it.
  """
  @spec validate(Issue.t()) :: :ok | {:error, term()}
  def validate(%Issue{structure_projected: false}), do: {:error, :issue_structure_unknown}

  def validate(%Issue{} = umbrella) do
    umbrella = Repo.preload(umbrella, :repository)
    members = members(umbrella)
    full_name = repository_full_name(umbrella.repository)
    member_numbers = MapSet.new(members, & &1.number)

    with :ok <- check(not Issue.sub_issues_overflow?(umbrella), :sub_issues_overflow),
         :ok <- check(members != [], :no_members),
         :ok <- each(members, &same_repository(&1, full_name)),
         :ok <- each(members, &not_nested/1),
         :ok <- each(members, &labelled_when_open/1),
         :ok <- each(members, &blockers_known(&1, member_numbers, full_name)),
         :ok <- no_cycles(members) do
      :ok
    end
  end

  @doc "The lowercase `owner/name` GitHub uses for this repository."
  def repository_full_name(%Repository{github_owner: owner, github_name: name}),
    do: String.downcase("#{owner}/#{name}")

  defp same_repository(%{repository_full_name: name, number: number}, full_name) do
    check(String.downcase(name || "") == full_name, {:cross_repository_member, number})
  end

  # A member whose own structure is unknown cannot be proven flat.
  defp not_nested(%{issue: %Issue{structure_projected: false}, number: number}),
    do: {:error, {:member_structure_unknown, number}}

  defp not_nested(%{issue: %Issue{} = issue, number: number}),
    do: check(not Issue.collection?(issue), {:nested_collection, number})

  defp not_nested(_member), do: :ok

  defp labelled_when_open(%{issue: %Issue{state: "open"} = issue, number: number}) do
    check(
      is_binary(issue.workflow_label) and not issue.workflow_label_conflict,
      {:member_without_workflow_label, number}
    )
  end

  # An open member PtcManager has never synchronized cannot be checked; that is
  # a synchronization gap the caller closes by syncing before validating.
  defp labelled_when_open(%{issue: nil, state: "open", number: number}),
    do: {:error, {:member_not_synchronized, number}}

  defp labelled_when_open(_member), do: :ok

  defp blockers_known(%{issue: %Issue{state: "open"} = issue, number: number}, members, full_name) do
    cond do
      not issue.dependencies_projected or issue.dependency_overflow or
          issue.dependency_unknown_count > 0 ->
        {:error, {:member_dependencies_unknown, number}}

      true ->
        each(issue.dependencies, fn dependency ->
          member? =
            dependency.blocking_repository_full_name == full_name and
              MapSet.member?(members, dependency.blocking_issue_number)

          closed? =
            dependency.lookup_state == "resolved" and dependency.blocking_state == "closed"

          check(member? or closed?, {:foreign_blocker, number, dependency.blocking_issue_number})
        end)
    end
  end

  defp blockers_known(_member, _members, _full_name), do: :ok

  defp no_cycles(members) do
    issues = for %{issue: %Issue{} = issue} <- members, do: issue

    case issues |> DependencyGraph.cycles() |> Enum.find(fn {_id, cycle} -> cycle end) do
      nil -> :ok
      {id, _cycle} -> {:error, {:dependency_cycle, Enum.find(issues, &(&1.id == id)).number}}
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  @doc "The highest issue number PtcManager knows in this repository, the baseline for created issues."
  def highest_issue_number(repository_id) do
    Issue
    |> where([issue], issue.repository_id == ^repository_id)
    |> select([issue], max(issue.number))
    |> Repo.one() || 0
  end

  @doc "Members whose numbers exceed the baseline: the ones an action can have created."
  def created_after(numbers, baseline) when is_list(numbers) and is_integer(baseline),
    do: Enum.filter(numbers, &(is_integer(&1) and &1 > baseline))

  @doc """
  The member numbers GitHub reports for the umbrella, as a MapSet.
  """
  def member_numbers(%Issue{} = umbrella),
    do: umbrella |> Issue.sub_issue_nodes() |> MapSet.new(& &1["number"])

  @doc "The dependencies of one member issue, loaded fresh."
  def dependencies(%Issue{id: id}) do
    IssueDependency |> where([dependency], dependency.issue_id == ^id) |> Repo.all()
  end
end
