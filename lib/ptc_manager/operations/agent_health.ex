defmodule PtcManager.Operations.AgentHealth do
  @moduledoc """
  Judges one Herdr agent run as healthy, needing attention, or ended.

  A Herdr snapshot refreshes every run every few seconds, so a live heartbeat
  proves only that the pane still exists. An agent parked at a question nobody
  is watching for keeps that heartbeat indefinitely while its pull request stops
  moving, which is why the state a run has held, and for how long, decides its
  health rather than the heartbeat alone.

  The assessment is derived, never stored: it reads the run PtcManager already
  reconciled from Herdr, so no extra observation can disagree with it.
  """

  alias PtcManager.Operations.AgentRun

  @attention_states ~w(failed lost unknown)
  @ended_states ~w(done)
  @live_states ~w(queued starting working waiting)
  @parked_states ~w(blocked idle)

  @doc """
  Milliseconds a run may sit parked before it counts as needing attention.

  This covers `blocked` and `idle` alike. Herdr reports a Codex or Claude agent
  that ends its turn with a question as idle rather than blocked, and an idle
  agent that has stopped moving is exactly as stuck as a blocked one.
  """
  def blocked_grace_ms,
    do: Application.get_env(:ptc_manager, :agent_blocked_attention_ms, 600_000)

  @doc "Milliseconds without a Herdr signal before a run counts as out of contact."
  def silent_after_ms,
    do: Application.get_env(:ptc_manager, :agent_silent_attention_ms, 600_000)

  @doc """
  Returns `%{status: :healthy | :attention | :ended, label: binary, detail: binary}`
  for one run. `status: :attention` means a person has to look at it.
  """
  def assess(run, now \\ DateTime.utc_now())

  def assess(%AgentRun{state: state} = run, now) when state in @ended_states do
    %{status: :ended, label: "Finished", detail: "The agent completed #{ago(run, now)}."}
  end

  def assess(%AgentRun{state: state} = run, now) when state in @attention_states do
    %{
      status: :attention,
      label: attention_label(state),
      detail: "#{attention_detail(state)} since #{ago(run, now)}."
    }
  end

  def assess(%AgentRun{state: state} = run, now) when state in @parked_states do
    waiting = held_for_ms(run, now)

    if waiting >= blocked_grace_ms() do
      %{
        status: :attention,
        label: "Waiting for a person",
        detail:
          "The agent has been #{parked_verb(state)} for #{humanize(waiting)}. " <>
            "Nothing is watching its session, so answer it in Herdr or cancel the agent."
      }
    else
      %{
        status: :healthy,
        label: parked_label(state),
        detail: "The agent stopped moving #{humanize(waiting)} ago."
      }
    end
  end

  def assess(%AgentRun{state: state} = run, now) when state in @live_states do
    silence = silence_ms(run, now)

    if silence >= silent_after_ms() do
      %{
        status: :attention,
        label: "Out of contact",
        detail: "Herdr last reported this agent #{humanize(silence)} ago."
      }
    else
      %{status: :healthy, label: healthy_label(state), detail: healthy_detail(state, run, now)}
    end
  end

  def assess(%AgentRun{state: state}, _now),
    do: %{status: :attention, label: "Unrecognised state", detail: "Herdr reported #{state}."}

  @doc "Returns only the runs a person has to look at."
  def needing_attention(runs, now \\ DateTime.utc_now()) when is_list(runs),
    do: Enum.filter(runs, &(assess(&1, now).status == :attention))

  defp attention_label("failed"), do: "Ended without finishing"
  defp attention_label("lost"), do: "Lost from Herdr"
  defp attention_label(_state), do: "State unknown"

  defp attention_detail("failed"), do: "The agent stopped before completing its task"
  defp attention_detail("lost"), do: "No Herdr snapshot has reported this agent"
  defp attention_detail(_state), do: "Herdr could not classify this agent"

  defp parked_verb("blocked"), do: "asking for an answer"
  defp parked_verb(_state), do: "idle"

  defp parked_label("blocked"), do: "Asking for input"
  defp parked_label(_state), do: "Idle"

  defp healthy_label("waiting"), do: "Retained"
  defp healthy_label(state), do: String.capitalize(state)

  defp healthy_detail("waiting", run, now),
    do: "Held with its open pull request since #{ago(run, now)}."

  defp healthy_detail(_state, run, now),
    do: "Working since #{ago(run, now)}."

  defp ago(run, now), do: humanize(held_for_ms(run, now)) <> " ago"

  defp held_for_ms(run, now), do: elapsed_ms(state_since(run), now)
  defp silence_ms(run, now), do: elapsed_ms(run.last_heartbeat_at, now)

  defp state_since(%AgentRun{state_changed_at: %DateTime{} = at}), do: at
  defp state_since(%AgentRun{started_at: at}), do: at

  @doc "Milliseconds from `at` to `now`, never negative; nil counts as no time."
  def elapsed_ms(nil, _now), do: 0

  def elapsed_ms(%DateTime{} = at, now),
    do: now |> DateTime.diff(at, :millisecond) |> max(0)

  @doc "A duration in milliseconds as a short label such as `4m` or `2h 10m`."
  def humanize(milliseconds) do
    seconds = div(milliseconds, 1_000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
      true -> "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
    end
  end
end
