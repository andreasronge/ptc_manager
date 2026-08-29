defmodule Mix.Tasks.Ptc.Deploy do
  use Mix.Task

  @shortdoc "Deploys the current clean commit to the Herdr server"

  @moduledoc """
  Deploys the current clean Git commit to the PtcManager service on the Herdr
  machine.

      mix ptc.deploy
      mix ptc.deploy --target herdr-box
      mix ptc.deploy --dry-run

  The deployment runs the local precommit checks, builds a production release
  remotely, stops the service, backs up SQLite, installs the release, runs
  migrations during application startup, and verifies the local HTTP endpoint.
  """

  @impl Mix.Task
  def run(args) do
    project_root = Mix.Project.project_file() |> Path.dirname()
    script = Path.join(project_root, "deploy/deploy-herdr")

    unless File.regular?(script) do
      Mix.raise("deployment script not found: #{script}")
    end

    {_output, status} =
      System.cmd(script, args,
        cd: project_root,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("Herdr deployment failed with exit status #{status}")
    end

    :ok
  end
end
