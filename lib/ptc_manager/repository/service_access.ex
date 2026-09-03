defmodule PtcManager.Repository.ServiceAccess do
  @moduledoc """
  Reports whether both services can write one repository's checkout.

  A checkout becomes writable for a service only when that service's unit grants
  the path and the service has started since: `ReadWritePaths` enters a process's
  mount namespace when it starts, never on a daemon reload. Neither fact is
  visible from the checkout itself, so a repository whose grant is missing or
  merely pending looks healthy right up to the moment an implementation dispatch
  fails with "cannot lock ref".

  Everything here is read-only. The unit's loaded grants and start time come from
  `systemctl show`, which needs no privilege, and the generated drop-in is only
  stat'd, so asking the question never changes an answer.
  """

  alias PtcManager.Operations.Repository

  @dropin "zz-ptc-manager-repositories.conf"

  @doc "Summarizes both services' access to this repository's checkout."
  def summarize(%Repository{local_path: path}) when is_binary(path) and path != "" do
    coordinator = grant(coordinator_unit(), Path.join(path, ".git"))
    worker = grant(worker_unit(), path)

    describe(coordinator, worker)
  end

  def summarize(%Repository{}),
    do: %{status: :unchecked, label: "Service access not checked", detail: "No checkout path."}

  defp describe(:unknown, _worker),
    do: unchecked()

  defp describe(_coordinator, :unknown),
    do: unchecked()

  defp describe(:missing, _worker), do: missing()
  defp describe(_coordinator, :missing), do: missing()

  defp describe(:restart_pending, :restart_pending),
    do: pending("#{coordinator_unit()} and #{worker_unit()} have not started since")

  defp describe(:restart_pending, _worker),
    do: pending("#{coordinator_unit()} has not started since")

  defp describe(_coordinator, :restart_pending),
    do: pending("#{worker_unit()} has not started since")

  defp describe(:effective, :effective) do
    %{
      status: :ready,
      label: "Service access granted",
      detail: "Both services can write this checkout."
    }
  end

  defp unchecked do
    %{
      status: :unchecked,
      label: "Service access not checked",
      detail: "This host does not report its service configuration."
    }
  end

  defp missing do
    %{
      status: :attention,
      label: "Service access not granted",
      detail:
        "Prepare this repository so its checkout exists and both services are granted it. " <>
          "Until then nothing can create a worktree from it."
    }
  end

  defp pending(subject) do
    %{
      status: :attention,
      label: "Service access waiting for a restart",
      detail:
        "#{subject} the grant was written, and a checkout only becomes writable when the " <>
          "service starts. A deployment restarts #{worker_unit()} for you when no agent " <>
          "session is retained; while one is held it leaves it alone, so restart it yourself " <>
          "once the board is quiet."
    }
  end

  defp grant(unit, path) do
    case properties(unit) do
      {:ok, properties} ->
        cond do
          not granted?(properties, path) -> :missing
          granted_outside_dropin?(unit, path) -> :effective
          started_after_dropin?(properties, unit) -> :effective
          true -> :restart_pending
        end

      :error ->
        :unknown
    end
  end

  defp granted?(properties, path) do
    properties
    |> Map.get("ReadWritePaths", "")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.trim_leading(&1, "-"))
    |> Enum.member?(path)
  end

  # A path some other source already grants is in force whatever the generated
  # drop-in says. Without this, regenerating the drop-in would report every
  # repository the base unit covers as waiting for a restart it does not need.
  defp granted_outside_dropin?(unit, path) do
    [Path.join(dropin_root(), unit) | sibling_dropins(unit)]
    |> Enum.flat_map(&grants_in/1)
    |> Enum.member?(path)
  end

  defp sibling_dropins(unit) do
    directory = Path.join(dropin_root(), "#{unit}.d")

    case File.ls(directory) do
      {:ok, entries} ->
        entries |> Enum.reject(&(&1 == @dropin)) |> Enum.map(&Path.join(directory, &1))

      {:error, _reason} ->
        []
    end
  end

  defp grants_in(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "ReadWritePaths="))
        |> Enum.flat_map(fn line ->
          line |> String.replace_prefix("ReadWritePaths=", "") |> String.split(" ", trim: true)
        end)
        |> Enum.map(&String.trim_leading(&1, "-"))

      {:error, _reason} ->
        []
    end
  end

  # The drop-in is only written when its grants change, so its modification time
  # marks when this repository's access last became available rather than when a
  # deployment last ran. A repository granted by the base unit has no drop-in to
  # be newer than the running service at all.
  defp started_after_dropin?(properties, unit) do
    with {:ok, %{mtime: written_at}} <- File.stat(dropin_path(unit), time: :posix),
         {:ok, started_at} <- started_at(properties) do
      started_at >= written_at
    else
      _absent -> true
    end
  end

  defp started_at(properties) do
    case properties |> Map.get("ActiveEnterTimestamp", "") |> String.trim_leading("@") do
      "" ->
        :error

      value ->
        if Regex.match?(~r/\A\d+\z/, value), do: {:ok, String.to_integer(value)}, else: :error
    end
  end

  defp properties(unit) do
    command = Application.get_env(:ptc_manager, :service_access_command, __MODULE__.Runner)

    case command.show(unit) do
      {output, 0} -> {:ok, parse(output)}
      _failure -> :error
    end
  rescue
    _error -> :error
  end

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, properties ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(properties, key, value)
        _other -> properties
      end
    end)
  end

  defp dropin_path(unit),
    do: Path.join([dropin_root(), "#{unit}.d", @dropin])

  defp dropin_root,
    do: Application.get_env(:ptc_manager, :systemd_unit_root, "/etc/systemd/system")

  defp coordinator_unit,
    do: Application.get_env(:ptc_manager, :coordinator_unit, "ptc_manager.service")

  defp worker_unit,
    do: Application.get_env(:ptc_manager, :worker_unit, "ptc_manager-herdr.service")

  defmodule Runner do
    @moduledoc false

    def show(unit) when is_binary(unit) do
      System.cmd(
        "systemctl",
        ["show", "--timestamp=unix", "-p", "ReadWritePaths", "-p", "ActiveEnterTimestamp", unit],
        env: PtcManager.CommandEnvironment.scrub(),
        stderr_to_stdout: true
      )
    rescue
      _error -> {"", 127}
    end
  end
end
