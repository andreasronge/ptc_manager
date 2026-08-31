defmodule Mix.Tasks.Ptc.Demo.Reset do
  @shortdoc "Rebuilds an isolated, deterministic browser-demo database"

  @moduledoc """
  Rebuilds the dedicated local browser-demo database and loads the checked-in
  mock scenario. It refuses to touch the ordinary development database.

      PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db mix ptc.demo.reset

  Start the application with the same demo settings afterwards:

      PTC_DEMO_MODE=true PTC_DATABASE_PATH=tmp/ptc_manager_demo.db PORT=4100 mix phx.server
  """

  use Mix.Task

  @requirements ["app.config"]
  @demo_filename "ptc_manager_demo.db"

  @impl Mix.Task
  def run(_args) do
    unless Application.get_env(:ptc_manager, :demo_mode, false) do
      Mix.raise("refusing to reset without PTC_DEMO_MODE=true")
    end

    database =
      :ptc_manager
      |> Application.fetch_env!(PtcManager.Repo)
      |> Keyword.fetch!(:database)
      |> Path.expand()

    unless safe_demo_database?(database) do
      Mix.raise("refusing to reset #{database}; set PTC_DATABASE_PATH=tmp/#{@demo_filename}")
    end

    case database_status(database) do
      :available ->
        :ok

      :in_use ->
        Mix.raise("the browser demo is running; stop its Phoenix server before resetting")

      {:error, reason} ->
        Mix.raise("cannot safely check whether the browser demo is running: #{reason}")
    end

    File.mkdir_p!(Path.dirname(database))

    run_task("ecto.drop", ["--quiet"])
    run_task("ecto.create", ["--quiet"])
    run_task("ecto.migrate", ["--quiet"])
    run_task("run", ["priv/repo/seeds.exs"])

    Mix.shell().info("Browser demo ready at #{database}")
  end

  @doc false
  def safe_demo_database?(database) when is_binary(database) do
    database = Path.expand(database)
    expected = Path.expand(Path.join([File.cwd!(), "tmp", @demo_filename]))
    database == expected
  end

  def safe_demo_database?(_database), do: false

  @doc false
  def database_status(
        database,
        runner \\ &System.cmd/3,
        executable \\ System.find_executable("lsof")
      )
      when is_binary(database) do
    paths = Enum.filter([database, database <> "-wal", database <> "-shm"], &File.exists?/1)

    case {paths, executable} do
      {[], _executable} ->
        :available

      {_paths, nil} ->
        {:error, "lsof is not installed"}

      {paths, lsof} when is_binary(lsof) ->
        case runner.(lsof, ["-t", "--" | paths], stderr_to_stdout: true) do
          {output, 0} ->
            if(String.trim(output) == "", do: :available, else: :in_use)

          {output, 1} ->
            if(String.trim(output) == "",
              do: :available,
              else: {:error, "lsof exited with status 1: #{String.trim(output)}"}
            )

          {output, status} ->
            {:error, "lsof exited with status #{status}: #{String.trim(output)}"}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp run_task(name, args) do
    Mix.Task.reenable(name)
    Mix.Task.run(name, args)
  end
end
