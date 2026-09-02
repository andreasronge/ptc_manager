defmodule PtcManager.Repository.SourceUpdaterTest do
  use ExUnit.Case, async: true

  @moduletag :nightly

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.SourceUpdater

  defmodule TimeoutGit do
    def run(_args, _timeout_ms), do: {"source refresh timed out", 124}
  end

  test "fetches and pins the remote default branch without changing the persistent checkout" do
    root =
      Path.join(System.tmp_dir!(), "ptc-source-updater-#{System.unique_integer([:positive])}")

    remote = Path.join(root, "remote.git")
    producer = Path.join(root, "producer")
    checkout = Path.join(root, "checkout")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    git!(root, ["init", "--bare", remote])
    git!(root, ["clone", remote, producer])
    git!(producer, ["checkout", "-b", "main"])
    git!(producer, ["config", "user.email", "test@example.com"])
    git!(producer, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(producer, "mix.lock"), "%{version: 1}\n")
    git!(producer, ["add", "mix.lock"])
    git!(producer, ["commit", "-m", "first"])
    git!(producer, ["push", "-u", "origin", "main"])
    git!(root, ["clone", "--branch", "main", remote, checkout])
    original = revision!(checkout, "HEAD")

    File.write!(Path.join(producer, "mix.lock"), "%{version: 2}\n")
    git!(producer, ["commit", "-am", "second"])
    git!(producer, ["push", "origin", "main"])
    current = revision!(producer, "HEAD")

    repository = %Repository{
      github_owner: "example",
      github_name: "repository",
      default_branch: "main",
      local_path: checkout
    }

    assert {:ok, source} = SourceUpdater.refresh(repository, remote: remote)
    assert source.sha == current
    assert source.ref == "refs/remotes/origin/main"
    assert revision!(checkout, source.ref) == current
    assert revision!(checkout, "HEAD") == original
    assert File.read!(Path.join(checkout, "mix.lock")) == "%{version: 1}\n"
  end

  test "returns a bounded failure when the remote fetch times out" do
    repository = %Repository{
      github_owner: "example",
      github_name: "repository",
      default_branch: "main",
      local_path: System.tmp_dir!()
    }

    assert {:error, {:repository_source_fetch_failed, 124, "source refresh timed out"}} =
             SourceUpdater.refresh(repository, git: TimeoutGit, timeout_ms: 10)
  end

  defp revision!(path, ref), do: git!(path, ["rev-parse", ref]) |> String.trim()

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
