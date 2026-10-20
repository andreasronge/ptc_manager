defmodule PtcManager.Machine.InventoryTest do
  use PtcManager.DataCase

  alias PtcManager.Machine.{Inventory, ToolInventory}
  alias PtcManager.Operations.AuditEvent

  setup do
    directory =
      Path.join(System.tmp_dir!(), "ptc-inventory-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, name: :"inventory_#{System.unique_integer([:positive])}"}
  end

  defp start(name, opts) do
    start_supervised!(
      {Inventory, [name: name, reload_ms: 3_600_000, first_probe_ms: 3_600_000] ++ opts},
      id: name
    )
  end

  defp snapshot(daemon_status, captured_at \\ DateTime.utc_now()) do
    %{
      "captured_at" => DateTime.to_iso8601(captured_at),
      "os" => "linux",
      "probes" => [
        %{"name" => "docker", "exit_status" => 0, "stdout" => "Docker version 27.5.1, build 9f9e405\n", "stderr" => ""},
        %{
          "name" => "docker-daemon",
          "exit_status" => daemon_status,
          "stdout" => "",
          "stderr" => ""
        }
      ]
    }
  end

  defp parsed(daemon_status) do
    {:ok, parsed} = ToolInventory.parse(snapshot(daemon_status), "pane")
    parsed
  end

  defp transitions do
    Repo.all(
      from event in AuditEvent,
        where: event.action == "machine.inventory_changed",
        order_by: [asc: event.id]
    )
  end

  test "rereads snapshot files and writes the catalog the probe unit reads", ctx do
    File.write!(Path.join(ctx.directory, "tool-inventory-pane.json"), Jason.encode!(snapshot(1)))
    File.write!(Path.join(ctx.directory, "tool-inventory-setup.json"), "{not json")

    pid = start(ctx.name, enabled: true, directory: ctx.directory)
    :sys.get_state(pid)

    inventory = Inventory.current(ctx.name)
    assert inventory.contexts["pane"].tools["docker"].version == "27.5.1"
    assert inventory.contexts["pane"].tools["docker-daemon"].status == "failed"
    assert inventory.contexts["setup"] == nil
    assert inventory.errors["setup"] == :invalid_json

    catalog =
      ctx.directory |> Path.join("tool-probe-catalog.json") |> File.read!() |> Jason.decode!()

    assert %{"name" => "docker-daemon", "argv" => ["docker", "version" | _]} =
             Enum.find(catalog["probes"], &(&1["name"] == "docker-daemon"))
  end

  test "persists only eligibility changes, and none after a restart with the same tools", ctx do
    start(ctx.name, enabled: false)

    Inventory.put_context("pane", parsed(1), ctx.name)
    assert [first] = transitions()
    assert first.target_type == "machine"
    assert first.details["old"] == []

    assert %{"context" => "pane", "status" => "failed", "stale" => false} =
             Enum.find(
               first.details["new"],
               &(&1["name"] == "docker-daemon" and &1["context"] == "pane")
             )

    # A newer capture with the same results is not a transition.
    Inventory.put_context("pane", parsed(1), ctx.name)
    assert length(transitions()) == 1

    Inventory.put_context("pane", parsed(0), ctx.name)
    assert [_first, second] = transitions()
    assert second.details["old"] == first.details["new"]

    assert %{"status" => "ok"} =
             Enum.find(
               second.details["new"],
               &(&1["name"] == "docker-daemon" and &1["context"] == "pane")
             )

    stop_supervised!(ctx.name)
    start(ctx.name, enabled: false)
    Inventory.put_context("pane", parsed(0), ctx.name)
    assert length(transitions()) == 2
  end

  test "an unprobed machine records nothing until a context arrives", ctx do
    start(ctx.name, enabled: false)
    Inventory.clear(ctx.name)
    assert transitions() == []

    assert Enum.all?(
             Inventory.lines(Inventory.current(ctx.name)),
             &(&1["status"] == "no_inventory")
           )
  end

  test "lines mark a context stale past the maximum age" do
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)
    {:ok, parsed} = ToolInventory.parse(snapshot(0, old), "pane")

    lines = Inventory.lines(%{contexts: %{"pane" => parsed, "setup" => nil}}, DateTime.utc_now())

    assert %{"stale" => true} =
             Enum.find(lines, &(&1["context"] == "pane" and &1["name"] == "docker"))

    assert %{"status" => "no_inventory"} = Enum.find(lines, &(&1["context"] == "setup"))
  end

  @tag :nightly
  test "without a job user one local probe run is recorded for both contexts", ctx do
    previous = Application.get_env(:ptc_manager, :herdr_run_as_user)
    Application.delete_env(:ptc_manager, :herdr_run_as_user)

    on_exit(fn ->
      if previous, do: Application.put_env(:ptc_manager, :herdr_run_as_user, previous)
    end)

    Phoenix.PubSub.subscribe(PtcManager.PubSub, "machine_usage")
    start(ctx.name, enabled: false, directory: ctx.directory)
    assert :ok = Inventory.refresh(ctx.name)

    assert_receive {:machine_inventory,
                    %{probing?: false, contexts: %{"pane" => %{}, "setup" => %{}}}},
                   60_000

    inventory = Inventory.current(ctx.name)
    assert inventory.contexts["pane"].tools["git"].status == "ok"
    assert inventory.contexts["setup"].tools == inventory.contexts["pane"].tools
    assert File.exists?(Path.join(ctx.directory, "tool-inventory-setup.json"))
  end
end
