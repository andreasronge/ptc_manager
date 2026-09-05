defmodule PtcManager.Repository.ServiceAccessTest do
  use ExUnit.Case, async: false

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.ServiceAccess

  defmodule ShowCommand do
    def show(unit) do
      case Application.fetch_env!(:ptc_manager, :service_access_test_properties) do
        %{^unit => {output, status}} -> {output, status}
        properties -> Map.get(properties, :default, {"", 1})
      end
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "ptc-service-access-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "ptc_manager.service.d"))
    File.mkdir_p!(Path.join(root, "ptc_manager-herdr.service.d"))
    on_exit(fn -> File.rm_rf!(root) end)

    keys = [:service_access_command, :service_access_test_properties, :systemd_unit_root]
    previous = Map.new(keys, &{&1, Application.get_env(:ptc_manager, &1)})

    Application.put_env(:ptc_manager, :service_access_command, ShowCommand)
    Application.put_env(:ptc_manager, :systemd_unit_root, root)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:ptc_manager, key)
        {key, value} -> Application.put_env(:ptc_manager, key, value)
      end)
    end)

    %{root: root}
  end

  defp repository, do: %Repository{local_path: "/srv/demo"}

  defp properties(paths, started_at),
    do: {"ReadWritePaths=#{paths}\nActiveEnterTimestamp=@#{started_at}\n", 0}

  defp write_dropin(root, unit, mtime) do
    path = Path.join([root, "#{unit}.d", "zz-ptc-manager-repositories.conf"])
    File.write!(path, "[Service]\n")
    File.touch!(path, mtime)
  end

  test "both services granted and started since the grant is ready", %{root: root} do
    write_dropin(root, "ptc_manager.service", 100)
    write_dropin(root, "ptc_manager-herdr.service", 100)

    Application.put_env(:ptc_manager, :service_access_test_properties, %{
      "ptc_manager.service" => properties("-/srv/demo/.git", 200),
      "ptc_manager-herdr.service" => properties("-/srv/demo", 200)
    })

    assert %{status: :ready, label: "Service access granted"} =
             ServiceAccess.summarize(repository())
  end

  # ReadWritePaths enters a namespace when the service starts, so a grant written
  # after the service last started is loaded but not yet in force.
  test "a grant written after the worker started still needs a restart", %{root: root} do
    write_dropin(root, "ptc_manager.service", 100)
    write_dropin(root, "ptc_manager-herdr.service", 300)

    Application.put_env(:ptc_manager, :service_access_test_properties, %{
      "ptc_manager.service" => properties("-/srv/demo/.git", 200),
      "ptc_manager-herdr.service" => properties("-/srv/demo", 200)
    })

    assert %{status: :attention, detail: detail} = ServiceAccess.summarize(repository())
    assert detail =~ "ptc_manager-herdr.service has not started since"
    assert detail =~ "restarts ptc_manager-herdr.service for you"
  end

  # Regenerating the drop-in must not report the repositories the base unit
  # already covers as waiting for a restart they do not need.
  test "a base unit grant stays in force when the drop-in is newer", %{root: root} do
    File.write!(
      Path.join(root, "ptc_manager-herdr.service"),
      "[Service]\nReadWritePaths=/var/lib/ptc_manager-worker /srv/demo\n"
    )

    write_dropin(root, "ptc_manager.service", 100)
    write_dropin(root, "ptc_manager-herdr.service", 300)

    Application.put_env(:ptc_manager, :service_access_test_properties, %{
      "ptc_manager.service" => properties("-/srv/demo/.git", 200),
      "ptc_manager-herdr.service" => properties("/srv/demo -/srv/demo", 200)
    })

    assert %{status: :ready} = ServiceAccess.summarize(repository())
  end

  test "a repository no unit grants needs preparing" do
    Application.put_env(:ptc_manager, :service_access_test_properties, %{
      "ptc_manager.service" => properties("-/srv/other/.git", 200),
      "ptc_manager-herdr.service" => properties("-/srv/other", 200)
    })

    assert %{status: :attention, label: "Service access not granted", detail: detail} =
             ServiceAccess.summarize(repository())

    assert detail =~ "Prepare this repository"
  end

  # A repository the base unit grants has no generated drop-in to be newer than
  # the running service, so its grant is already in force.
  test "a grant from the base unit needs no drop-in" do
    Application.put_env(:ptc_manager, :service_access_test_properties, %{
      "ptc_manager.service" => properties("/srv/demo/.git", 200),
      "ptc_manager-herdr.service" => properties("/srv/demo", 200)
    })

    assert %{status: :ready} = ServiceAccess.summarize(repository())
  end

  test "a host that cannot report its services is unchecked, not failing" do
    Application.put_env(:ptc_manager, :service_access_test_properties, %{default: {"", 127}})

    assert %{status: :unchecked} = ServiceAccess.summarize(repository())
    assert %{status: :unchecked} = ServiceAccess.summarize(%Repository{local_path: nil})
  end
end
