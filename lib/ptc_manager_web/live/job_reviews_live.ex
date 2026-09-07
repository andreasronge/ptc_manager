defmodule PtcManagerWeb.JobReviewsLive do
  use PtcManagerWeb, :live_view
  alias PtcManager.{Repo, Reviews, Operations}
  alias PtcManager.Operations.Job

  def mount(%{"id" => id}, session, socket) do
    if connected?(socket), do: Operations.subscribe()

    {:ok,
     socket
     |> assign(
       page_title: "Job reviews",
       actor: session["actor"] || "maintainer",
       job_id: String.to_integer(id)
     )
     |> load_job()}
  end

  def handle_info({:operations_changed, _}, socket), do: {:noreply, load_job(socket)}

  def handle_event("decide", %{"decision" => params}, socket) do
    with {generation, ""} <- Integer.parse(params["generation"]),
         {extra, ""} <- Integer.parse(params["extra_rounds"] || "0"),
         {:ok, _} <-
           Reviews.decide(
             socket.assigns.job_id,
             generation,
             params["action"],
             Map.put(params, "extra_rounds", extra),
             socket.assigns.actor
           ) do
      {:noreply,
       socket
       |> load_job()
       |> put_flash(:info, "Decision recorded. Your existing work is preserved.")}
    else
      {:error, reason} ->
        {:noreply, socket |> load_job() |> put_flash(:error, decision_error(reason))}

      _ ->
        {:noreply, put_flash(socket, :error, "Check the review budget and reason.")}
    end
  end

  def handle_event("post-note", %{"note" => %{"body" => body}}, socket) do
    case PtcManager.Reviews.CancellationNote.queue(
           socket.assigns.job_id,
           body,
           socket.assigns.actor
         ) do
      {:ok, _} ->
        {:noreply,
         socket |> load_job() |> put_flash(:info, "The approved GitHub explanation is queued.")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "The explanation could not be queued, or was already queued.")}
    end
  end

  defp load_job(socket) do
    job =
      Repo.get!(Job, socket.assigns.job_id)
      |> Repo.preload([:issue, :repository, :worktree_allocation])

    rounds = Reviews.rounds(job.id)

    assign(socket,
      job: job,
      rounds: rounds,
      completed_count: Enum.count(rounds, &(&1.state == "completed")),
      failed_count: Enum.count(rounds, &(&1.state == "failed")),
      active_count: Enum.count(rounds, &(&1.state in ~w(queued running))),
      latest_failed: match?(%{state: "failed"}, List.last(rounds)),
      profiles: PtcManager.ExecutionProfiles.list()
    )
  end

  defp decision_error(:reason_required),
    do: "Enter a reason before cancelling the implementation."

  defp decision_error(:review_decision_stale),
    do: "This job changed. Review its current state before choosing again."

  defp decision_error(:review_budget_exhausted), do: "Add at least one review round to continue."

  defp decision_error(:invalid_continuation_instructions),
    do: "Keep continuation instructions within 4,000 characters."

  defp decision_error(:invalid_review_budget),
    do: "Choose up to five additional rounds, within the total limit of 100."

  defp decision_error(_),
    do:
      "The decision could not be saved. Your work is preserved; check the selected profile and retry."

  defp review_status("resume_pending"), do: "Continuation queued"
  defp review_status("manual"), do: "Manual takeover"
  defp review_status(nil), do: "Legacy prompt policy"
  defp review_status(state), do: String.replace(state, "_", " ") |> String.capitalize()

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path="/board">
      <div class="mx-auto max-w-4xl space-y-5 p-6 text-slate-200">
        <h1 class="text-2xl font-semibold text-white">Reviews for issue #{@job.issue.number}</h1>
        <p>{@job.issue.title}</p>
        <div class="rounded-xl border border-white/10 bg-white/5 p-5">
          <h2 class="text-xl">
            {if @job.review_state == "paused",
              do:
                if(@latest_failed,
                  do: "Review attempt failed",
                  else: "Review budget reached or review needs attention"
                ),
              else: "Review status: #{review_status(@job.review_state)}"}
          </h2>
          <p>{@completed_count} of {@job.required_review_count} completed reviews · Work preserved</p>
          <p>{@failed_count} failed attempts · {@active_count} in progress</p>
          <p>Review timeout: {div(Reviews.timeout_ms(@job), 60_000)} minutes</p>
          <p :if={@latest_failed and @job.review_state == "paused"} class="mt-2 text-amber-200">
            The reviewer did not return a valid assessment. This attempt did not use a review round.
            Continue with unused budget after addressing the failure; retries require your decision.
          </p>
          <p class="mt-2 break-all text-sm">Branch: {@job.branch_name}</p>
          <p :if={@job.worktree_allocation} class="break-all text-sm">
            Workspace: {@job.worktree_allocation.path}
          </p>
          <p :if={@job.execution_settings} class="mt-2 text-sm">
            Implementation: {@job.execution_settings["kind"]} / {@job.execution_settings["model"]} · Reviewer: {@job.execution_settings[
              "reviewer_kind"
            ]} / {@job.execution_settings["reviewer_model"]}
          </p>
        </div>
        <div :if={@job.review_continuation_instructions} class="rounded-xl border border-white/10 p-5">
          <h2 class="font-semibold">Last continuation instructions</h2>
          <p class="whitespace-pre-wrap">{@job.review_continuation_instructions}</p>
        </div>
        <p :if={@job.review_state == "resume_pending"}>
          {if is_nil(@job.review_resume_expires_at),
            do:
              "Continuation queued. Your workspace is preserved while waiting for the previous agent to stop and a worker slot to become free.",
            else: "A worker slot is reserved and the retained work is starting."}
        </p>
        <p :if={@job.last_error} class="text-amber-200">{@job.last_error}</p>
        <p :if={@job.review_state == "manual"}>
          Confirm the retained agent has stopped in Operations before editing the workspace.
        </p>
        <.form
          :if={@job.review_state in ~w(paused manual)}
          for={%{}}
          as={:decision}
          id="review-decision"
          phx-submit="decide"
          class="space-y-4 rounded-xl border border-amber-300/30 p-5"
        >
          <input type="hidden" name="decision[generation]" value={@job.review_generation} />
          <label class="block">
            Additional rounds<select name="decision[extra_rounds]" class="ml-3 bg-slate-900"><option
                value="0"
                selected={@completed_count < @job.required_review_count}
              >0 — unused budget only</option><option value="1">+1</option><option
                value="2"
                selected={@completed_count >= @job.required_review_count}
              >+2</option><option value="5">+5</option></select>
          </label>
          <label class="block">
            Execution profile<select name="decision[profile]" class="ml-3 bg-slate-900"><option value="">Keep approved models</option><option
                :for={profile <- @profiles}
                value={profile.name}
              >{String.capitalize(profile.name)} · {profile.kind}/{profile.model} · reviewer {profile.reviewer_kind}/{profile.reviewer_model}</option></select>
          </label>
          <p class="text-sm text-slate-400">
            Changing profile selects its implementation and reviewer models and review timeout. The same branch, files and review history are retained.
          </p>
          <label class="block">
            Instructions for continuation (optional)<textarea
              name="decision[instructions]"
              maxlength="4000"
              rows="4"
              class="mt-2 block w-full bg-slate-900"
            />
          </label>
          <p class="text-sm text-slate-400">
            Sent to the agent only when you continue. Use this to request a broader review of the
            existing work or explain a change of approach. Leave blank for normal continuation;
            previous instructions are not automatically reused. Review and publication safeguards still apply.
          </p>
          <label class="block">
            Reason (required for cancellation)<textarea
              name="decision[reason]"
              maxlength="2000"
              class="mt-2 block w-full bg-slate-900"
            />
          </label>
          <div class="flex flex-wrap gap-3">
            <button
              name="decision[action]"
              value="continue"
              class="rounded bg-teal-300 px-4 py-2 text-slate-950"
            >
              Continue existing work
            </button>
            <button name="decision[action]" value="manual" class="rounded bg-white/10 px-4 py-2">
              Take over manually
            </button>
            <button name="decision[action]" value="cancel" class="rounded bg-red-400/20 px-4 py-2">
              Cancel implementation
            </button>
          </div>
          <p class="text-sm">
            Cancellation records your reason privately. It never discards the workspace.
          </p>
        </.form>
        <.form
          :if={@job.review_state == "cancelled" and is_nil(@job.cancellation_action_id)}
          for={%{}}
          as={:note}
          id="cancellation-note"
          phx-submit="post-note"
          class="space-y-3 rounded-xl border border-white/10 p-5"
        >
          <h2 class="font-semibold">Optional GitHub explanation</h2>
          <p>Review and edit this comment. Posting it is a separate approval.</p>
          <textarea name="note[body]" maxlength="4000" rows="6" class="block w-full bg-slate-900">{PtcManager.Reviews.CancellationNote.preview(@job, @job.cancellation_reason || "")}</textarea>
          <button class="rounded bg-teal-300 px-4 py-2 text-slate-950">
            Approve and post explanation
          </button>
        </.form>
        <p :if={@job.cancellation_action_id}>
          GitHub explanation queued as action #{@job.cancellation_action_id}.
        </p>
        <article
          :for={round <- @rounds}
          id={"review-round-#{round.id}"}
          class="rounded-xl border border-white/10 p-5"
        >
          <h2 class="font-semibold">Attempt {round.number} · {round.state}</h2>
          <p class="break-all text-xs text-slate-400">Commit {round.head_sha}</p>
          <p :if={round.error} class="mt-2 text-amber-200">{round.error}</p>
          <div :if={round.result} class="mt-3">
            <p>{round.result["summary"]}</p>
            <ul class="mt-3 space-y-2">
              <li :for={finding <- round.result["findings"]}>
                <strong>{finding["severity"]}</strong> — {finding["description"]}
              </li>
            </ul>
          </div>
        </article>
        <.link navigate="/board" class="text-teal-300">Back to Delivery</.link>
      </div>
    </Layouts.app>
    """
  end
end
