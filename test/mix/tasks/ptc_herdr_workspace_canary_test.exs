defmodule Mix.Tasks.Ptc.HerdrWorkspaceCanaryTest do
  use ExUnit.Case, async: false

  @moduletag :nightly

  import ExUnit.CaptureIO

  defmodule FakeHerdr do
    def run(args, _timeout \\ nil)

    def run(["status", "server"], _timeout) do
      Process.put({__MODULE__, :session}, Application.get_env(:ptc_manager, :herdr_session))
      {:ok, "status: running\nsocket: /tmp/herdr-canary.sock\n"}
    end

    def run(["worktree", "create" | args], _timeout) do
      repository = value!(args, "--cwd")
      branch = value!(args, "--branch")
      base = value!(args, "--base")
      path = value!(args, "--path")

      case System.cmd("git", ["-C", repository, "worktree", "add", "-b", branch, path, base],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Process.put({__MODULE__, :workspace}, {repository, path})

          {:ok,
           Jason.encode!(%{
             "result" => %{
               "workspace" => %{"workspace_id" => "w-canary"},
               "root_pane" => %{"pane_id" => "w-canary:p1"}
             }
           })}

        {output, status} ->
          {:error, {:git_worktree_failed, status, output}}
      end
    end

    def run(["worktree", "remove", "--workspace", "w-canary", "--force"], _timeout) do
      {repository, path} = Process.delete({__MODULE__, :workspace})

      case System.cmd("git", ["-C", repository, "worktree", "remove", "--force", path],
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          Process.put({__MODULE__, :removed_path}, path)
          {:ok, "{}"}

        {output, status} ->
          {:error, {:git_worktree_remove_failed, status, output}}
      end
    end

    defp value!(args, option) do
      index = Enum.find_index(args, &(&1 == option))
      Enum.at(args, index + 1)
    end
  end

  test "uses a real Git worktree behind the Herdr boundary and cleans it up" do
    root = Path.join(System.tmp_dir!(), "ptc-canary-task-#{System.unique_integer([:positive])}")
    repository = Path.join(root, "repository")
    File.mkdir_p!(Path.join(repository, "scripts/ptc"))
    on_exit(fn -> File.rm_rf!(root) end)

    git!(repository, ["init", "-b", "main"])
    git!(repository, ["config", "user.email", "test@example.com"])
    git!(repository, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(repository, ".gitignore"), ".prepared\n")

    File.write!(
      Path.join(repository, ".ptc-manager.yml"),
      """
      version: 1
      bootstrap:
        command: ./scripts/ptc/setup-worktree
        timeout_minutes: 1
      verification:
        before_publish: ./scripts/ptc/setup-worktree
        timeout_minutes: 1
      """
    )

    script = Path.join(repository, "scripts/ptc/setup-worktree")
    File.write!(script, "#!/bin/sh\nset -eu\nmkdir .prepared\nprintf 'canary ready\\n'\n")
    File.chmod!(script, 0o755)
    git!(repository, ["add", "."])
    git!(repository, ["commit", "-m", "canary fixture"])

    previous = Application.get_env(:ptc_manager, :workspace_canary_herdr_command)
    Application.put_env(:ptc_manager, :workspace_canary_herdr_command, FakeHerdr)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ptc_manager, :workspace_canary_herdr_command, previous),
        else: Application.delete_env(:ptc_manager, :workspace_canary_herdr_command)
    end)

    Mix.Task.reenable("ptc.herdr_workspace_canary")

    output =
      capture_io(fn ->
        Mix.Tasks.Ptc.HerdrWorkspaceCanary.run([
          "--repository",
          repository,
          "--session",
          "test-canary"
        ])
      end)

    assert output =~ "Herdr session: test-canary"
    assert output =~ "socket: /tmp/herdr-canary.sock"
    assert output =~ "Local Herdr workspace canary passed."
    assert output =~ "Repository setup:"
    assert output =~ "canary ready"
    refute File.exists?(Process.delete({FakeHerdr, :removed_path}))
    assert Process.delete({FakeHerdr, :session}) == "test-canary"

    {branches, 0} = System.cmd("git", ["-C", repository, "branch", "--list"])
    refute branches =~ "ptc-manager/issue-0-job-"
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
