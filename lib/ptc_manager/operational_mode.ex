defmodule PtcManager.OperationalMode do
  @moduledoc """
  Central admission policy for coordinator work.

  Maintenance mode keeps the web application and read-only inspection
  available while preventing pollers and maintainer mutations from starting
  new work. Canary admission grants one process one use of an exact invocation
  identifier; activation succeeds only after that exact claim is marked passed.
  """

  alias PtcManager.OperationalMode.Audit

  @type mode :: :active | :draining | :maintenance | {:canary, String.t()}

  @mode_lock {__MODULE__, :mode}

  @spec mode() :: mode()
  def mode do
    case Application.get_env(:ptc_manager, :operational_mode, :active) do
      :active ->
        :active

      "active" ->
        :active

      :draining ->
        :draining

      "draining" ->
        :draining

      :maintenance ->
        :maintenance

      "maintenance" ->
        :maintenance

      {:canary, invocation_id} when is_binary(invocation_id) ->
        {:canary, invocation_id}

      {:canary, invocation_id, :unclaimed} when is_binary(invocation_id) ->
        {:canary, invocation_id}

      {:canary, invocation_id, {:claimed, owner}}
      when is_binary(invocation_id) and is_pid(owner) ->
        {:canary, invocation_id}

      {:canary, invocation_id, {:consumed, owner}}
      when is_binary(invocation_id) and is_pid(owner) ->
        {:canary, invocation_id}

      {:canary, invocation_id, {:passed, owner}}
      when is_binary(invocation_id) and is_pid(owner) ->
        {:canary, invocation_id}

      invalid ->
        raise "invalid PtcManager operational mode: #{inspect(invalid)}"
    end
  end

  def active?, do: mode() == :active
  def maintenance?, do: not active?()
  def reconciliation_allowed?, do: mode() in [:active, :draining]
  def canary?, do: match?({:canary, _invocation_id}, mode())

  @spec authorize_ordinary_work() :: :ok | {:error, :maintenance_mode}
  def authorize_ordinary_work do
    case mode() do
      :active -> :ok
      :draining -> {:error, :deployment_draining}
      _restricted -> {:error, :maintenance_mode}
    end
  end

  @doc "Pauses new work for a deployment; `actor` names who asked, for the audit trail."
  def enter_draining(actor) when is_binary(actor) do
    transition(actor, fn
      :active -> {:ok, :draining}
      :draining -> {:ok, :draining}
      _restricted -> {:error, :operational_mode_restricted}
    end)
  end

  @doc "Ends a deployment drain and wakes the pollers."
  def leave_draining(actor) when is_binary(actor) do
    result =
      transition(actor, fn
        :draining -> {:ok, :active}
        _mode -> {:error, :not_draining}
      end)

    if result == :ok, do: wake_after_draining()
    result
  end

  # Every coarse transition goes through here so that a change of mode, and
  # only a change, is recorded with the actor that asked for it. The audit is
  # written inside the lock so the records keep the order of the transitions;
  # it never fails the transition.
  defp transition(actor, decide) do
    :global.trans(@mode_lock, fn ->
      previous = mode()

      case decide.(previous) do
        {:ok, next} ->
          Application.put_env(:ptc_manager, :operational_mode, next)
          if previous != next, do: Audit.record(actor, previous, next)
          :ok

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @doc """
  Records a release that started restricted. The deployment script installs a
  systemd override that boots the new release in maintenance and writes no
  event of its own, so the boot is recorded as the script's transition; the
  Deployments page and the stall detectors then know who owns the window.
  """
  def record_boot do
    case mode() do
      :active -> :ok
      restricted -> Audit.record("deploy", :boot, restricted)
    end
  end

  @doc """
  Whether the mode is a canary whose process is gone: admitted but never
  claimed, or claimed by a process that no longer runs. Such a canary can only
  be replaced, never finished.
  """
  def stale_canary? do
    case Application.get_env(:ptc_manager, :operational_mode) do
      {:canary, _invocation_id, :unclaimed} -> true
      {:canary, _invocation_id, {_step, owner}} when is_pid(owner) -> not Process.alive?(owner)
      _mode -> false
    end
  end

  @spec authorize_canary(String.t()) :: :ok | {:error, :canary_not_admitted}
  def authorize_canary(invocation_id) when is_binary(invocation_id) do
    owner = self()

    :global.trans(@mode_lock, fn ->
      case Application.get_env(:ptc_manager, :operational_mode) do
        {:canary, ^invocation_id, {:claimed, ^owner}} ->
          Application.put_env(
            :ptc_manager,
            :operational_mode,
            {:canary, invocation_id, {:consumed, owner}}
          )

          :ok

        _mode ->
          {:error, :canary_not_admitted}
      end
    end)
  end

  @doc "Stops all ordinary work; `actor` names who asked, for the audit trail."
  def enter_maintenance(actor) when is_binary(actor),
    do: transition(actor, fn _mode -> {:ok, :maintenance} end)

  @doc "Admits exactly one canary invocation from maintenance mode; refused from any other mode."
  def admit_canary(invocation_id, actor)
      when is_binary(invocation_id) and byte_size(invocation_id) in 1..160 and is_binary(actor) do
    transition(actor, fn
      :maintenance -> {:ok, {:canary, invocation_id, :unclaimed}}
      _mode -> {:error, :canary_already_admitted}
    end)
  end

  def admit_canary(_invocation_id, actor) when is_binary(actor), do: {:error, :invalid_canary_id}

  def claim_canary(invocation_id) when is_binary(invocation_id) do
    owner = self()

    :global.trans(@mode_lock, fn ->
      case Application.get_env(:ptc_manager, :operational_mode) do
        {:canary, ^invocation_id, :unclaimed} ->
          Application.put_env(
            :ptc_manager,
            :operational_mode,
            {:canary, invocation_id, {:claimed, owner}}
          )

          :ok

        _mode ->
          {:error, :canary_not_admitted}
      end
    end)
  end

  @spec mark_canary_passed(String.t()) :: :ok | {:error, :canary_not_admitted}
  def mark_canary_passed(invocation_id) when is_binary(invocation_id) do
    owner = self()

    :global.trans(@mode_lock, fn ->
      case Application.get_env(:ptc_manager, :operational_mode) do
        {:canary, ^invocation_id, {:consumed, ^owner}} ->
          Application.put_env(
            :ptc_manager,
            :operational_mode,
            {:canary, invocation_id, {:passed, owner}}
          )

          :ok

        _mode ->
          {:error, :canary_not_admitted}
      end
    end)
  end

  @spec activate_canary(String.t(), String.t(), keyword()) :: :ok | {:error, :canary_not_admitted}
  def activate_canary(invocation_id, actor, opts \\ [])
      when is_binary(invocation_id) and is_binary(actor) do
    result =
      transition(actor, fn
        _mode ->
          case Application.get_env(:ptc_manager, :operational_mode) do
            {:canary, ^invocation_id, {:passed, _owner}} -> {:ok, :active}
            _mode -> {:error, :canary_not_admitted}
          end
      end)

    if result == :ok, do: Keyword.get(opts, :wake, &wake_pollers/0).()
    result
  end

  def label(:active), do: "Active"
  def label(:draining), do: "Deployment drain"
  def label(:maintenance), do: "Maintenance"
  def label({:canary, _invocation_id}), do: "Canary"

  defp wake_pollers do
    PtcManager.MaintainerActions.Poller.wake()
    PtcManager.GitHub.Poller.wake()
    PtcManager.Herdr.Poller.wake()
    PtcManager.Dispatch.Poller.wake()
    PtcManager.WorktreePoller.wake()
    PtcManager.ResultPoller.wake()
    PtcManager.PublisherPoller.wake()
    PtcManager.PublicationStatusPoller.wake()
    PtcManager.DailyDigests.Scheduler.wake()
  end

  defp wake_after_draining do
    # Reconciliation pollers continue running while draining. Only wake the
    # producers that were deliberately paused from starting new work.
    PtcManager.MaintainerActions.Poller.wake()
    PtcManager.GitHub.Poller.wake()
    PtcManager.Dispatch.Poller.wake()
    PtcManager.DailyDigests.Scheduler.wake()
  end
end
