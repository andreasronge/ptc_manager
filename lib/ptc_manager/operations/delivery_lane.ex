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
      job_state(item) == "queued" -> :queued
      stuck?(item) -> :stuck
      ready?(item) -> :ready
      true -> :working
    end
  end

  def stuck?(item) do
    job_state(item) in ["blocked", "reconciling", "publish_blocked", "failed", "lost"] or
      match?(%{checks_state: "failure"}, item.publication) or
      match?(%{mergeability: "conflicting"}, item.publication) or
      match?(
        %{draft: false, checks_state: checks_state, mergeability: "blocked"}
        when checks_state in ["success", "none"],
        item.publication
      )
  end

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
