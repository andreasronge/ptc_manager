defmodule PtcManager.OperationalModeTest do
  use ExUnit.Case, async: false

  alias PtcManager.OperationalMode

  setup do
    previous = Application.get_env(:ptc_manager, :operational_mode)
    on_exit(fn -> restore_env(:operational_mode, previous) end)
    :ok
  end

  test "active mode admits ordinary work" do
    Application.put_env(:ptc_manager, :operational_mode, :active)

    assert OperationalMode.mode() == :active
    assert OperationalMode.active?()
    assert :ok = OperationalMode.authorize_ordinary_work()
  end

  test "maintenance mode rejects ordinary work without hiding read-only state" do
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)

    assert OperationalMode.mode() == :maintenance
    assert OperationalMode.maintenance?()
    assert {:error, :maintenance_mode} = OperationalMode.authorize_ordinary_work()
  end

  test "canary mode admits only the exact allowlisted invocation" do
    assert :ok = OperationalMode.enter_maintenance()
    assert :ok = OperationalMode.admit_canary("release-abc")

    assert OperationalMode.mode() == {:canary, "release-abc"}
    assert OperationalMode.maintenance?()
    assert OperationalMode.canary?()
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-abc")
    assert :ok = OperationalMode.claim_canary("release-abc")
    assert :ok = OperationalMode.authorize_canary("release-abc")
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-abc")
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-other")
    assert {:error, :maintenance_mode} = OperationalMode.authorize_ordinary_work()
    assert {:error, :canary_not_admitted} = OperationalMode.activate_canary("release-abc")
    assert :ok = OperationalMode.mark_canary_passed("release-abc")
    assert :ok = OperationalMode.activate_canary("release-abc", wake: fn -> :ok end)
    assert OperationalMode.mode() == :active
  end

  test "a different process cannot consume or activate the canary capability" do
    assert :ok = OperationalMode.enter_maintenance()
    assert :ok = OperationalMode.admit_canary("release-owner")
    assert :ok = OperationalMode.claim_canary("release-owner")

    task = Task.async(fn -> OperationalMode.authorize_canary("release-owner") end)
    assert Task.await(task) == {:error, :canary_not_admitted}

    assert {:error, :canary_not_admitted} =
             OperationalMode.activate_canary("release-owner", wake: fn -> :ok end)

    assert :ok = OperationalMode.authorize_canary("release-owner")
    assert :ok = OperationalMode.mark_canary_passed("release-owner")
    assert :ok = OperationalMode.enter_maintenance()

    assert {:error, :canary_not_admitted} =
             OperationalMode.activate_canary("release-owner", wake: fn -> :ok end)
  end

  test "poller callbacks do not launch tasks while maintenance is active" do
    keys = [
      :operational_mode,
      :dispatch_enabled,
      :agent_actions_enabled,
      :publication_enabled,
      :pr_reconcile_enabled,
      :github_sync_interval_ms,
      :herdr_sync_interval_ms,
      :result_reconcile_interval_ms,
      :worktree_reconcile_interval_ms,
      :daily_digest_enabled
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> restore_env(key, value) end) end)

    Application.put_env(:ptc_manager, :operational_mode, :maintenance)
    Application.put_env(:ptc_manager, :dispatch_enabled, true)
    Application.put_env(:ptc_manager, :agent_actions_enabled, true)
    Application.put_env(:ptc_manager, :publication_enabled, true)
    Application.put_env(:ptc_manager, :pr_reconcile_enabled, true)
    Application.put_env(:ptc_manager, :github_sync_interval_ms, 1_000)
    Application.put_env(:ptc_manager, :herdr_sync_interval_ms, 1_000)
    Application.put_env(:ptc_manager, :result_reconcile_interval_ms, 1_000)
    Application.put_env(:ptc_manager, :worktree_reconcile_interval_ms, 1_000)
    Application.put_env(:ptc_manager, :daily_digest_enabled, true)

    assert {:noreply, %{task_ref: nil}} =
             PtcManager.Dispatch.Poller.handle_info(:dispatch, %{task_ref: nil})

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.GitHub.Poller.handle_info(:sync, %{task_ref: nil, timer_ref: nil})

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.Herdr.Poller.handle_info(:sync, %{task_ref: nil, timer_ref: nil})

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.MaintainerActions.Poller.handle_info(:run, %{
               lane: :planning,
               task_ref: nil,
               timer_ref: nil
             })

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.PublisherPoller.handle_info(:publish, %{
               task_ref: nil,
               timer_ref: nil
             })

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.PublicationStatusPoller.handle_info(:reconcile_pr, %{
               task_ref: nil,
               timer_ref: nil
             })

    assert {:noreply, %{task_ref: nil}} =
             PtcManager.ResultPoller.handle_info(:reconcile, %{task_ref: nil})

    assert {:noreply, %{task_ref: nil, timer_ref: nil}} =
             PtcManager.WorktreePoller.handle_info(:cleanup, %{
               task_ref: nil,
               timer_ref: nil
             })

    assert {:noreply, %{timer_ref: nil}} =
             PtcManager.DailyDigests.Scheduler.handle_info(:tick, %{timer_ref: nil})
  end

  defp restore_env(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore_env(key, value), do: Application.put_env(:ptc_manager, key, value)
end
