defmodule PtcManagerWeb.RetrospectiveComponents do
  @moduledoc """
  The private retrospective of one pull request and its proposed follow-ups.

  Planning shows this after a pull request is labelled as having unfinished
  business; the Delivery board shows the same block on a card that is ready to
  merge. Both read this one component so a suggestion looks and behaves the same
  wherever the maintainer meets it.
  """

  use PtcManagerWeb, :html

  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.Poller, as: MaintainerActionPoller

  @doc "The retrospective summary and its suggestions, or nothing at all."
  attr :id, :string, required: true
  attr :action, :map, default: nil
  attr :creation_actions, :list, default: []
  attr :repository, :map, required: true
  attr :class, :string, default: "mt-4 border-t border-white/10 pt-4"

  def retrospective(assigns) do
    ~H"""
    <section :if={summary(@action) || suggestions(@action) != []} id={@id} class={@class}>
      <p class="text-[11px] font-semibold uppercase tracking-wider text-violet-300">
        Private retrospective
      </p>
      <p :if={summary(@action)} class="mt-1 text-xs leading-5 text-slate-300">
        {summary(@action)}
      </p>

      <div class="mt-3 space-y-3">
        <div
          :for={{suggestion, index} <- suggestions(@action)}
          id={"retro-suggestion-#{@action.id}-#{index}"}
          class="rounded-lg border border-violet-400/15 bg-violet-400/[0.05] p-3"
        >
          <div class="flex items-start justify-between gap-2">
            <p class="text-xs font-semibold leading-5 text-slate-100">{suggestion["title"]}</p>
            <span class="shrink-0 rounded-full bg-white/5 px-2 py-1 text-[9px] text-slate-400 ring-1 ring-white/10">
              {category_label(suggestion["category"])}
            </span>
          </div>
          <p class="mt-1 text-xs leading-5 text-slate-300">{suggestion["simple_summary"]}</p>
          <p class="mt-2 text-[11px] leading-4 text-slate-500">
            Why it matters: {suggestion["why_it_matters"]}
          </p>

          <% creation = creation_action(@creation_actions, @action.id, index) %>
          <% created_number = created_issue_number(creation) %>

          <div class="mt-3">
            <a
              :if={created_number}
              href={issue_url(@repository, created_number)}
              target="_blank"
              rel="noreferrer"
              class="text-xs font-semibold text-teal-300 hover:text-teal-200"
            >
              Created issue #{created_number} ↗
            </a>
            <p :if={not_created?(creation)} class="text-xs font-semibold text-slate-400">
              Already tracked; no duplicate was created.
            </p>
            <button
              :if={!created_number && !not_created?(creation)}
              id={"create-retro-issue-#{@action.id}-#{index}"}
              phx-click="create-retrospective-issue"
              phx-value-source-action-id={@action.id}
              phx-value-suggestion-index={index}
              disabled={active?(creation)}
              class="inline-flex items-center gap-1.5 rounded-lg bg-teal-400 px-3 py-2 text-xs font-semibold text-slate-950 hover:bg-teal-300 disabled:cursor-not-allowed disabled:bg-slate-700 disabled:text-slate-400"
            >
              <.icon name="hero-plus-mini" class="size-3.5" />
              {creation_label(creation)}
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  @doc "Queues one approved follow-up and returns the flash to show."
  def queue_issue(source_action_id, suggestion_index, actor) do
    with {source_action_id, ""} <- Integer.parse(source_action_id),
         {suggestion_index, ""} <- Integer.parse(suggestion_index),
         {:ok, _action} <-
           MaintainerActions.enqueue_retrospective_issue(
             source_action_id,
             suggestion_index,
             actor
           ) do
      MaintainerActionPoller.wake()
      {:info, "Approved follow-up queued for GitHub issue creation."}
    else
      {:error, :suggestion_already_handled} ->
        {:info, "That follow-up is already queued or handled."}

      {:error, :agent_action_already_active} ->
        {:error, "Another PR action is already queued or running."}

      _error ->
        {:error, "The follow-up issue could not be queued."}
    end
  end

  @doc "The suggestions of a finished retrospective, with their stable indexes."
  def suggestions(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         suggestions when is_list(suggestions) <- result["suggestions"] do
      Enum.with_index(suggestions)
    else
      _result -> []
    end
  end

  def suggestions(_action), do: []

  @doc "The private summary of a finished retrospective."
  def summary(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         summary when is_binary(summary) <- result["private_summary"] do
      summary
    else
      _result -> nil
    end
  end

  def summary(_action), do: nil

  @doc "The issue-creation action already queued for one suggestion, if any."
  def creation_action(actions, source_action_id, suggestion_index) do
    Enum.find(actions, fn action ->
      action.target_snapshot["source_action_id"] == source_action_id and
        action.target_snapshot["suggestion_index"] == suggestion_index
    end)
  end

  def active?(%{state: state}) when state in ["queued", "running", "sync_pending"], do: true
  def active?(_action), do: false

  def creation_label(%{state: "queued"}), do: "Issue queued"
  def creation_label(%{state: "running"}), do: "Creating issue"
  def creation_label(%{state: "sync_pending"}), do: "Checking GitHub"
  def creation_label(%{state: "failed"}), do: "Try again"
  def creation_label(_action), do: "Add as GitHub issue"

  def created_issue_number(%{state: "done", result_summary: body}) when is_binary(body) do
    with {:ok, result} <- Jason.decode(body),
         [number] <- result["created_issue_numbers"],
         true <- is_integer(number) do
      number
    else
      _result -> nil
    end
  end

  def created_issue_number(_action), do: nil

  def not_created?(%{state: "done", result_summary: body}) when is_binary(body) do
    match?({:ok, %{"outcome" => "no-followups"}}, Jason.decode(body))
  end

  def not_created?(_action), do: false

  def issue_url(repository, issue_number),
    do:
      "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{issue_number}"

  def category_label(category) when is_binary(category),
    do: category |> String.replace("-", " ") |> String.capitalize()

  def category_label(_category), do: "Follow-up"
end
