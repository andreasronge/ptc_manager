defmodule PtcManager.OperationalModeTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.OperationalMode
  alias PtcManager.OperationalMode.Audit
  alias PtcManager.Operations.AuditEvent
  alias PtcManager.Repo

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
    assert :ok = OperationalMode.enter_maintenance("test")
    assert :ok = OperationalMode.admit_canary("release-abc", "test")

    assert OperationalMode.mode() == {:canary, "release-abc"}
    assert OperationalMode.maintenance?()
    assert OperationalMode.canary?()
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-abc")
    assert :ok = OperationalMode.claim_canary("release-abc")
    assert :ok = OperationalMode.authorize_canary("release-abc")
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-abc")
    assert {:error, :canary_not_admitted} = OperationalMode.authorize_canary("release-other")
    assert {:error, :maintenance_mode} = OperationalMode.authorize_ordinary_work()
    assert {:error, :canary_not_admitted} = OperationalMode.activate_canary("release-abc", "test")
    assert :ok = OperationalMode.mark_canary_passed("release-abc")
    assert :ok = OperationalMode.activate_canary("release-abc", "test", wake: fn -> :ok end)
    assert OperationalMode.mode() == :active
  end

  test "a different process cannot consume or activate the canary capability" do
    assert :ok = OperationalMode.enter_maintenance("test")
    assert :ok = OperationalMode.admit_canary("release-owner", "test")
    assert :ok = OperationalMode.claim_canary("release-owner")

    task = Task.async(fn -> OperationalMode.authorize_canary("release-owner") end)
    assert Task.await(task) == {:error, :canary_not_admitted}

    assert {:error, :canary_not_admitted} =
             OperationalMode.activate_canary("release-owner", "test", wake: fn -> :ok end)

    assert :ok = OperationalMode.authorize_canary("release-owner")
    assert :ok = OperationalMode.mark_canary_passed("release-owner")
    assert :ok = OperationalMode.enter_maintenance("test")

    assert {:error, :canary_not_admitted} =
             OperationalMode.activate_canary("release-owner", "test", wake: fn -> :ok end)
  end

  test "every change of mode is recorded with its actor, and a repeat is not a change" do
    Application.put_env(:ptc_manager, :operational_mode, :active)

    assert :ok = OperationalMode.enter_draining("deployments")
    assert :ok = OperationalMode.enter_draining("deployments")
    assert :ok = OperationalMode.leave_draining("deployments")
    assert {:error, :not_draining} = OperationalMode.leave_draining("deployments")
    assert :ok = OperationalMode.enter_maintenance("broker_recovery")
    assert :ok = OperationalMode.enter_maintenance("broker_recovery")
    assert :ok = OperationalMode.admit_canary("release-audit", "deploy")
    assert :ok = OperationalMode.claim_canary("release-audit")
    assert :ok = OperationalMode.authorize_canary("release-audit")
    assert :ok = OperationalMode.mark_canary_passed("release-audit")
    assert :ok = OperationalMode.activate_canary("release-audit", "deploy", wake: fn -> :ok end)

    transitions =
      Repo.all(
        from event in AuditEvent,
          where: event.action == ^Audit.action(),
          order_by: event.id,
          select: {event.actor, event.details["previous"], event.details["next"]}
      )

    assert transitions == [
             {"deployments", "active", "draining"},
             {"deployments", "draining", "active"},
             {"broker_recovery", "active", "maintenance"},
             {"deploy", "maintenance", "canary"},
             {"deploy", "canary", "active"}
           ]

    assert %AuditEvent{actor: "deploy"} = Audit.last_transition()
  end

  test "a restricted boot is recorded as the deployment script's transition" do
    Application.put_env(:ptc_manager, :operational_mode, :active)
    assert :ok = OperationalMode.record_boot()
    assert is_nil(Audit.last_transition())

    Application.put_env(:ptc_manager, :operational_mode, :maintenance)
    assert :ok = OperationalMode.record_boot()

    assert %AuditEvent{actor: "deploy", details: %{"previous" => "boot", "next" => "maintenance"}} =
             Audit.last_transition()

    assert Audit.deploy_owned?()

    refute Audit.deploy_owned?(
             DateTime.add(DateTime.utc_now(), Audit.deploy_window_ms(), :millisecond)
           )
  end

  test "a canary whose process is gone is stale, a live one is not" do
    Application.put_env(:ptc_manager, :operational_mode, :maintenance)
    refute OperationalMode.stale_canary?()

    assert :ok = OperationalMode.admit_canary("release-stale", "test")
    assert OperationalMode.stale_canary?(), "admitted but never claimed"

    assert :ok = OperationalMode.claim_canary("release-stale")
    refute OperationalMode.stale_canary?()

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    Application.put_env(
      :ptc_manager,
      :operational_mode,
      {:canary, "release-stale", {:claimed, dead}}
    )

    assert OperationalMode.stale_canary?()
    assert {:ok, "release-stale"} = OperationalMode.replace_stale_canary("test")
    assert OperationalMode.mode() == :maintenance

    assert %AuditEvent{actor: "test", details: %{"previous" => "canary", "next" => "maintenance"}} =
             Audit.last_transition()

    assert :ok = OperationalMode.admit_canary("release-live", "test")
    assert :ok = OperationalMode.claim_canary("release-live")
    assert {:error, :canary_not_stale} = OperationalMode.replace_stale_canary("test")
    assert OperationalMode.mode() == {:canary, "release-live"}
  end

  test "the mode lock excludes other processes" do
    Application.put_env(:ptc_manager, :operational_mode, :active)
    parent = self()

    holder =
      spawn_link(fn ->
        :global.trans({{OperationalMode, :mode}, self()}, fn ->
          send(parent, :holding)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :holding
    task = Task.async(fn -> OperationalMode.enter_maintenance("test") end)
    refute_receive {_ref, :ok}, 200, "the transition ran while another process held the lock"
    send(holder, :release)
    assert :ok = Task.await(task)
    assert OperationalMode.mode() == :maintenance
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
