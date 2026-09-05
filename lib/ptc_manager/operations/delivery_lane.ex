defmodule PtcManager.Operations.DeliveryLane do
  @moduledoc """
  Places one delivery item in the lane a maintainer would put it in.

  The Delivery board draws the lanes; Planning shows the same lane as a badge on
  an issue that is already being delivered. Both read this one definition so the
  two pages can never disagree about where a job stands.
  """

  @labels %{
    queued: "Queued",
    working: "In progress",
    stuck: "Needs attention",
    ready: "Ready to merge"
  }

  @doc "The lane keys in board order."
  def keys, do: [:queued, :working, :stuck, :ready]

  @doc "The maintainer-facing name of one lane."
  def label(key) when is_map_key(@labels, key), do: Map.fetch!(@labels, key)

  @doc "The lane this delivery item belongs to."
  def lane_for(item) do
    cond do
      stopped?(item) -> :stuck
      job_state(item) == "queued" -> :queued
      stuck?(item) -> :stuck
      ready?(item) -> :ready
      true -> :working
    end
  end

  @doc "True when this card is a job whose agent reported that it could not finish."
  def stopped?(%{active_job: %{stop_reported_at: %DateTime{}, stop_acknowledged_at: nil}}),
    do: true

  def stopped?(_item), do: false

  def stuck?(item) do
    PtcManager.Reviews.held?(item.active_job) or stopped?(item) or
      job_state(item) in ["blocked", "reconciling", "publish_blocked", "failed", "lost"] or
      unreconciled?(item) or
      match?(%{checks_state: "failure"}, item.publication) or
      match?(%{mergeability: "conflicting"}, item.publication) or
      match?(
        %{draft: false, checks_state: checks_state, mergeability: "blocked"}
        when checks_state in ["success", "none"],
        item.publication
      )
  end

  @doc """
  True when reconciliation ran against the agent's branch and could not take it.

  A job passes through `awaiting_reconciliation` in seconds on its way to
  verification, so the state alone says nothing. A recorded error means a probe
  ran and failed, most often on `:no_commits` — which is what a Codex or Claude
  session parked at an unanswered prompt looks like from outside the pane, since
  Herdr reports that pane as finished. PtcManager keeps probing, so a transient
  failure returns the card to its own lane without anyone touching it.
  """
  def unreconciled?(%{active_job: %{state: "awaiting_reconciliation", last_error: error}})
      when is_binary(error) and error != "",
      do: true

  def unreconciled?(_item), do: false

  def ready?(item) do
    open_pull_request?(item) and
      match?(%{state: "published", pr_state: "open", draft: false}, item.publication) and
      item.publication.checks_state in ["success", "none"] and
      item.publication.mergeability == "mergeable"
  end

  defp open_pull_request?(%{publication: %{state: "published", pr_state: "open"}}), do: true
  defp open_pull_request?(_item), do: false

  defp job_state(%{active_job: %{state: state}}), do: state
  defp job_state(_item), do: nil
end
