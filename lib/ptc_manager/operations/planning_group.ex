defmodule PtcManager.Operations.PlanningGroup do
  @moduledoc """
  Decides which Planning group one issue belongs to, and why an issue can start.

  Planning orders its groups by what the maintainer can do next rather than by
  GitHub's update time. The classification is pure so it can be unit tested
  without a LiveView, and the approval predicate lives here so the page and the
  classifier can never disagree about which issues are ready.
  """

  @stale_after_days 30

  @groups [
    ready: "Ready to start",
    needs_decision: "Needs your decision",
    collections: "Collections",
    follow_ups: "Suggested follow-ups",
    not_prepared: "Not prepared",
    blocked: "Blocked",
    in_delivery: "In delivery",
    waiting: "Waiting",
    stale: "Stale"
  ]

  @collapsed_by_default [:in_delivery, :waiting, :stale]

  @doc "Every Planning group in display order."
  def order, do: Keyword.keys(@groups)

  @doc "The heading shown above one group."
  def label(group), do: Keyword.fetch!(@groups, group)

  @doc "One sentence saying what the maintainer is looking at."
  def description(:ready), do: "Every deterministic check passes. Approving starts an agent."
  def description(:needs_decision), do: "An answer from you unblocks these."

  def description(:collections),
    do: "Issues with GitHub sub-issues. Their members are implemented; they are not."

  def description(:follow_ups), do: "Retrospectives that proposed work nobody has tracked yet."
  def description(:not_prepared), do: "No fresh, ready analysis. Prepare or fix them directly."
  def description(:blocked), do: "GitHub or a dependency says these cannot start yet."
  def description(:in_delivery), do: "Already being implemented; the Delivery board owns them."
  def description(:waiting), do: "Parked with one of your own labels."
  def description(:stale), do: "No GitHub activity for #{@stale_after_days} days."

  @doc "Groups that open closed, because they need no decision right now."
  def collapsed_by_default, do: @collapsed_by_default

  @doc "The age after which an unprepared or blocked issue is considered stale."
  def stale_after_days, do: @stale_after_days

  @doc """
  Returns the group of one dashboard issue item.

  The first matching rule wins, and the rules are ordered by how strongly they
  determine what happens next: work that already started, work you explicitly
  parked, work waiting on you, then readiness. Parking is an inactive-planning
  placement; it never hides an active job or open managed or external pull
  request.

  Options: `:now`, `:stale_after_days`, and `:parked_labels` (the label names
  this repository configured with the `park` role).
  """
  def classify(item, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_days = Keyword.get(opts, :stale_after_days, @stale_after_days)
    parked_labels = Keyword.get(opts, :parked_labels, [])

    cond do
      in_delivery?(item) -> :in_delivery
      parked?(item, parked_labels) -> :waiting
      needs_decision?(item) -> :needs_decision
      collection?(item) -> :collections
      approvable?(item) -> :ready
      blocked?(item) -> stale_or(:blocked, item, now, stale_after_days)
      true -> stale_or(:not_prepared, item, now, stale_after_days)
    end
  end

  @doc """
  True when GitHub reports one of the repository's parked label names.

  GitHub matches label names case-insensitively, so this comparison does too.
  """
  def parked?(_item, []), do: false

  def parked?(item, parked_labels) do
    reported = MapSet.new(issue_labels(item.issue), &String.downcase/1)
    Enum.any?(parked_labels, &MapSet.member?(reported, String.downcase(&1)))
  end

  @doc """
  The author login to show, or nil when there is nothing worth showing.

  Nothing is shown while the viewer login is unknown, because an issue is not
  external just because PtcManager has not yet asked GitHub who it is.
  """
  def external_author(%{issue: issue}), do: author_of(issue, issue.repository)

  @doc "The label names GitHub last reported on this issue."
  def issue_labels(%{github_labels: %{"names" => names}}) when is_list(names), do: names
  def issue_labels(_issue), do: []

  @doc "True when the private analysis still describes the synchronized issue."
  def fresh?(%{proposal: nil}), do: false

  def fresh?(%{issue: issue, proposal: proposal}) do
    issue.content_digest == proposal.source_digest and
      DateTime.compare(issue.github_updated_at, proposal.source_updated_at) == :eq
  end

  @doc """
  True when every deterministic approval gate passes for a prepared issue.

  `Operations.approve_issue/3` re-checks all of this inside its transaction;
  this predicate exists so Planning can show the same answer before the click.
  """
  def approvable?(
        %{issue: %{state: "open"}, proposal: %{readiness: "ready"}, active_job: nil} = item
      ),
      do: fresh?(item) and startable?(item)

  def approvable?(_item), do: false

  @doc """
  True when everything except a fresh, ready proposal allows implementation.

  This is what "Fix directly" needs: the same gates minus the two proposal ones.
  """
  def startable?(%{issue: %{state: "open"}, active_job: nil} = item) do
    not item.issue.workflow_label_conflict and
      not claimed?(item.issue) and
      item.issue.github_assignment_projected and
      item.issue.workflow_label in [nil, "ptc:ready"] and
      item.issue.dependencies_projected and
      item.issue.structure_projected and
      not collection?(item) and
      not item.issue.dependency_overflow and
      item.issue.dependency_unknown_count == 0 and
      is_nil(item.dependency_cycle) and
      Enum.all?(item.dependencies, &dependency_completed?/1)
  end

  def startable?(_item), do: false

  @doc "True when GitHub reports sub-issues, so the issue is a collection and never implemented itself."
  def collection?(%{issue: issue}), do: PtcManager.Operations.Issue.collection?(issue)

  @doc "True when GitHub reports an assignee, PtcManager's advisory work claim."
  def claimed?(%{github_assignees: %{"logins" => [_login | _rest]}}), do: true
  def claimed?(_issue), do: false

  @doc "True when a prerequisite was closed without being completed."
  def dependencies_need_decision?(dependencies) do
    Enum.any?(dependencies, &closed_without_completion?/1)
  end

  defp author_of(%{github_author_login: author}, %{github_viewer_login: viewer})
       when is_binary(author) and is_binary(viewer) and author != viewer,
       do: author

  defp author_of(_issue, _repository), do: nil

  defp in_delivery?(%{active_job: %{}}), do: true
  defp in_delivery?(%{publication: %{state: "published", pr_state: "open"}}), do: true
  defp in_delivery?(%{external_publication: %{}}), do: true
  defp in_delivery?(_item), do: false

  defp needs_decision?(item) do
    item.issue.workflow_label == "ptc:needs-decision" or
      item.issue.workflow_label_conflict or
      not is_nil(item.dependency_cycle) or
      dependencies_need_decision?(item.dependencies) or
      match?(%{state: "failed"}, item.issue_agent_action)
  end

  defp blocked?(item) do
    item.issue.workflow_label == "ptc:blocked" or
      not item.issue.dependencies_projected or
      not item.issue.structure_projected or
      item.issue.dependency_overflow or
      item.issue.dependency_unknown_count > 0 or
      Enum.any?(item.dependencies, &(not dependency_completed?(&1)))
  end

  defp stale_or(group, item, now, stale_after_days) do
    if stale?(item.issue.github_updated_at, now, stale_after_days), do: :stale, else: group
  end

  defp stale?(%DateTime{} = updated_at, now, stale_after_days),
    do: DateTime.diff(now, updated_at, :second) > stale_after_days * 86_400

  defp stale?(_updated_at, _now, _stale_after_days), do: false

  defp dependency_completed?(%{lookup_state: "resolved", state: "closed", state_reason: reason}),
    do: reason == "completed"

  defp dependency_completed?(_dependency), do: false

  defp closed_without_completion?(%{
         lookup_state: "resolved",
         state: "closed",
         state_reason: reason
       }),
       do: reason != "completed"

  defp closed_without_completion?(_dependency), do: false
end
