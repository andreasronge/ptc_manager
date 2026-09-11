defmodule PtcManagerWeb.PlanningComponents do
  @moduledoc """
  The compact parts of the Planning page: one group heading and one card header.

  Planning is read on a phone before it is read anywhere else, so a card shows
  its identity, its badges, and its two ages, and nothing else until the
  maintainer asks for more.
  """

  use PtcManagerWeb, :html

  alias PtcManager.Operations.PlanningGroup

  @doc "The heading, count, and collapse toggle of one Planning group."
  attr :group, :atom, required: true
  attr :count, :integer, required: true
  attr :collapsed, :boolean, required: true

  def group_heading(assigns) do
    ~H"""
    <button
      id={"planning-group-toggle-#{@group}"}
      type="button"
      phx-click="toggle-group"
      phx-value-group={@group}
      aria-expanded={to_string(not @collapsed)}
      class="flex w-full items-center justify-between gap-3 rounded-xl px-1 py-2 text-left hover:bg-white/[0.03]"
    >
      <span class="min-w-0">
        <span class="flex items-center gap-2">
          <.icon
            name={if @collapsed, do: "hero-chevron-right-mini", else: "hero-chevron-down-mini"}
            class="size-4 shrink-0 text-slate-500"
          />
          <span class="text-sm font-semibold">{PlanningGroup.label(@group)}</span>
          <span class="rounded-full bg-white/5 px-2 py-0.5 text-xs text-slate-400 ring-1 ring-white/10">
            {@count}
          </span>
        </span>
        <span class="mt-1 block pl-6 text-[11px] leading-4 text-slate-500">
          {PlanningGroup.description(@group)}
        </span>
      </span>
    </button>
    """
  end

  @doc "Everything a collapsed Planning card shows about one issue."
  attr :item, :map, required: true
  attr :now, :any, required: true
  attr :expanded, :boolean, required: true

  def card_header(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
      <div class="min-w-0">
        <p class="text-xs font-medium text-slate-500">
          {@item.issue.repository.github_owner}/{@item.issue.repository.github_name} · #{@item.issue.number}
          <span :if={@item.issue.state != "open"}>{" · #{@item.issue.state}"}</span>
        </p>
        <h3 class="mt-1 text-base font-semibold leading-6 sm:text-lg sm:leading-7">
          {@item.issue.title}
        </h3>
        <.ages item={@item} now={@now} />
      </div>
      <div class="flex shrink-0 flex-wrap items-center gap-2">
        <.badges item={@item} />
        <button
          id={"toggle-issue-#{@item.issue.id}"}
          type="button"
          phx-click="toggle-issue"
          phx-value-issue-id={@item.issue.id}
          aria-expanded={to_string(@expanded)}
          class="rounded-lg border border-white/10 px-2.5 py-1 text-xs font-semibold text-slate-300 hover:bg-white/5"
        >
          {if @expanded, do: "Collapse", else: "Expand"}
        </button>
      </div>
    </div>
    """
  end

  @doc "How long ago GitHub saw this issue created and last touched."
  attr :item, :map, required: true
  attr :now, :any, required: true

  def ages(assigns) do
    ~H"""
    <p class="mt-1.5 text-xs text-slate-500">
      <span
        :if={@item.issue.github_created_at}
        title={TimeFormat.utc(@item.issue.github_created_at)}
      >
        opened {TimeFormat.relative(@now, @item.issue.github_created_at)}
      </span>
      <span :if={@item.issue.github_created_at}>·</span>
      <span title={TimeFormat.utc(@item.issue.github_updated_at)}>
        updated {TimeFormat.relative(@now, @item.issue.github_updated_at)}
      </span>
    </p>
    """
  end

  @doc "The badge row shared by the collapsed and expanded card."
  attr :item, :map, required: true

  def badges(assigns) do
    ~H"""
    <span
      :if={PlanningGroup.claimed?(@item.issue)}
      id={"issue-#{@item.issue.id}-claimed"}
      title="GitHub assignment is advisory, but PtcManager will not start duplicate work."
      class="inline-flex w-fit items-center gap-1.5 rounded-full bg-sky-400/15 px-2.5 py-1 text-xs text-sky-300 ring-1 ring-sky-400/20"
    >
      <.icon name="hero-user-circle-mini" class="size-4" />
      {claim_label(@item.issue)}
    </span>
    <span
      :if={not @item.issue.github_assignment_projected}
      id={"issue-#{@item.issue.id}-claim-unknown"}
      class="inline-flex w-fit items-center gap-1.5 rounded-full bg-amber-400/15 px-2.5 py-1 text-xs text-amber-300 ring-1 ring-amber-400/20"
    >
      <.icon name="hero-arrow-path-mini" class="size-4" /> Claim status needs sync
    </span>
    <span
      :if={PlanningGroup.collection?(@item)}
      id={"issue-#{@item.issue.id}-collection"}
      title="This issue has GitHub sub-issues. Its members are implemented; it is not."
      class="inline-flex w-fit items-center gap-1.5 rounded-full bg-indigo-400/15 px-2.5 py-1 text-xs text-indigo-300 ring-1 ring-indigo-400/20"
    >
      <.icon name="hero-squares-2x2-mini" class="size-4" />
      Collection · {PtcManager.Operations.Issue.sub_issues_completed(@item.issue)}/{@item.issue.sub_issues[
        "total"
      ]}
    </span>
    <span
      :if={@item.issue.parent_issue_number}
      id={"issue-#{@item.issue.id}-member"}
      class="w-fit rounded-full bg-indigo-400/15 px-2.5 py-1 text-xs text-indigo-300 ring-1 ring-indigo-400/20"
    >
      Part of #{@item.issue.parent_issue_number}
    </span>
    <span
      :if={@item.proposal}
      class={[
        "w-fit rounded-full px-2.5 py-1 text-xs ring-1",
        readiness_classes(@item.proposal.readiness)
      ]}
    >
      {String.replace(@item.proposal.readiness, "_", " ")}
    </span>
    <span
      :if={author = PlanningGroup.external_author(@item)}
      id={"issue-#{@item.issue.id}-external"}
      title="This issue was opened by somebody other than the account PtcManager reads GitHub with."
      class="w-fit rounded-full bg-fuchsia-400/15 px-2.5 py-1 text-xs text-fuchsia-300 ring-1 ring-fuchsia-400/20"
    >
      External · @{author}
    </span>
    <span
      :if={@item.issue.workflow_label}
      class="w-fit rounded-full bg-violet-400/15 px-2.5 py-1 text-xs text-violet-300 ring-1 ring-violet-400/20"
    >
      {@item.issue.workflow_label}
    </span>
    <span
      :if={@item.issue.workflow_label_conflict}
      class="w-fit rounded-full bg-amber-400/15 px-2.5 py-1 text-xs text-amber-300 ring-1 ring-amber-400/20"
    >
      conflicting ptc labels
    </span>
    """
  end

  defp claim_label(%{github_assignees: %{"logins" => logins}}) when is_list(logins),
    do: "Taken by " <> Enum.map_join(logins, ", ", &"@#{&1}")

  defp readiness_classes("ready"), do: "bg-teal-400/15 text-teal-300 ring-teal-400/20"
  defp readiness_classes(_readiness), do: "bg-slate-400/10 text-slate-300 ring-white/10"
end
