defmodule PtcManager.OperationalMode do
  @moduledoc """
  Central admission policy for coordinator work.

  Maintenance mode keeps the web application and read-only inspection
  available while preventing pollers and maintainer mutations from starting
  new work. Canary admission grants one process one use of an exact invocation
  identifier; activation succeeds only after that exact claim is marked passed.
  """

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

  def enter_draining do
    :global.trans(@mode_lock, fn ->
      case mode() do
        :active ->
          Application.put_env(:ptc_manager, :operational_mode, :draining)
          :ok

        :draining ->
          :ok

        _restricted ->
          {:error, :operational_mode_restricted}
      end
    end)
  end

  def leave_draining do
    result =
      :global.trans(@mode_lock, fn ->
        case mode() do
          :draining ->
            Application.put_env(:ptc_manager, :operational_mode, :active)
            :ok

          _mode ->
            {:error, :not_draining}
        end
      end)

    if result == :ok, do: wake_after_draining()
    result
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

  def enter_maintenance do
    :global.trans(@mode_lock, fn ->
      Application.put_env(:ptc_manager, :operational_mode, :maintenance)
      :ok
    end)
  end

  def admit_canary(invocation_id)
      when is_binary(invocation_id) and byte_size(invocation_id) in 1..160 do
    :global.trans(@mode_lock, fn ->
      case mode() do
        :maintenance ->
          Application.put_env(
            :ptc_manager,
            :operational_mode,
            {:canary, invocation_id, :unclaimed}
          )

          :ok

        _mode ->
          {:error, :canary_already_admitted}
      end
    end)
  end

  def admit_canary(_invocation_id), do: {:error, :invalid_canary_id}

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

  @spec activate_canary(String.t(), keyword()) :: :ok | {:error, :canary_not_admitted}
  def activate_canary(invocation_id, opts \\ []) when is_binary(invocation_id) do
    result =
      :global.trans(@mode_lock, fn ->
        case Application.get_env(:ptc_manager, :operational_mode) do
          {:canary, ^invocation_id, {:passed, _owner}} ->
            Application.put_env(:ptc_manager, :operational_mode, :active)
            :ok

          _mode ->
            {:error, :canary_not_admitted}
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
