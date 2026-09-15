defmodule PtcManager.OperationalMode.Audit do
  @moduledoc """
  The record of every operational mode transition: who moved the console,
  from what, to what, and when.

  The mode itself lives in application configuration and carries no history,
  which is how the console once entered maintenance twice with nothing to
  show for it. Every transition now writes an audit event under the actor
  that asked for it: `deployments` for the drain around a deployment,
  `canary` for a canary's own failure, `broker_recovery` for an expensive
  operation whose recovery failed, `deploy` for the deployment script, and
  the maintainer's own actor for the Activate button.

  Recording never blocks the transition: a busy database is exactly when a
  transition into maintenance happens, so a failed write is logged and the
  mode still changes.
  """

  import Ecto.Query
  require Logger

  alias PtcManager.{ExecutionProfiles, Repo}
  alias PtcManager.Operations.AuditEvent

  @action "operational_mode.changed"
  @target_type "operational_mode"
  # The mode is a singleton; audit events need an integer target.
  @target_id 0
  @deploy_actor "deploy"

  @doc "The audit action name every transition writes."
  def action, do: @action

  @doc "Records one transition. Returns `:ok` even when the write fails, after logging it."
  def record(actor, previous, next) when is_binary(actor) do
    ExecutionProfiles.audit(
      actor,
      @action,
      @target_id,
      %{"previous" => name(previous), "next" => name(next)},
      @target_type
    )

    :ok
  rescue
    exception in [Exqlite.Error, DBConnection.ConnectionError] ->
      Logger.error(
        "Operational mode transition #{name(previous)} -> #{name(next)} by #{actor} was not recorded: " <>
          Exception.message(exception)
      )

      :ok
  end

  @doc "The newest recorded transition, or nil when none has been recorded."
  def last_transition do
    Repo.one(
      from event in AuditEvent,
        where:
          event.target_type == @target_type and event.target_id == @target_id and
            event.action == @action,
        order_by: [desc: event.id],
        limit: 1
    )
  end

  @doc """
  Milliseconds after the deployment script's last transition during which it
  still owns a restricted console: a direct deployment boots in maintenance and
  runs its own canary within this window. After it, a console the script left
  restricted is a stall and may be activated from the console.
  """
  def deploy_window_ms, do: Application.get_env(:ptc_manager, :mode_deploy_window_ms, 1_800_000)

  @doc "Whether the deployment script made the last transition within `deploy_window_ms/0`."
  def deploy_owned?(now \\ DateTime.utc_now()) do
    case last_transition() do
      %AuditEvent{actor: @deploy_actor, inserted_at: at} ->
        DateTime.diff(now, at, :millisecond) < deploy_window_ms()

      _other ->
        false
    end
  end

  @doc "A mode as the audit records it."
  def name({:canary, _invocation_id}), do: "canary"
  def name({:canary, _invocation_id, _state}), do: "canary"
  def name(mode) when is_atom(mode), do: Atom.to_string(mode)
end
