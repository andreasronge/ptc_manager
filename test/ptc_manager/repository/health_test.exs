defmodule PtcManager.Repository.HealthTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Repository.{Checkout, Health}

  defmodule Updater do
    def refresh(_repository, _opts \\ []),
      do: Application.fetch_env!(:ptc_manager, :health_test_refresh)
  end

  setup do
    previous = Application.get_env(:ptc_manager, :source_updater)
    Application.put_env(:ptc_manager, :source_updater, Updater)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :source_updater, previous)
      Application.delete_env(:ptc_manager, :health_test_refresh)
    end)
  end

  test "the contract is read at the fetched GitHub commit, not the local branch" do
    {repository, path} = checkout()
    local = commit!(path, "./local-check")
    remote = commit!(path, "./fetched-check")
    git!(path, ["reset", "--hard", local])
    git!(path, ["update-ref", "refs/remotes/origin/main", remote])
    Application.put_env(:ptc_manager, :health_test_refresh, {:ok, %{sha: remote}})

    assert %{gate: %{status: :ready, detail: "./fetched-check"}} = Health.summarize(repository)

    # A page that summarises every repository reads the last fetch instead.
    availability = Checkout.availability([repository])[repository.id]
    assert %{gate: %{detail: "./fetched-check"}} = Health.summarize(repository, availability)

    git!(path, ["update-ref", "-d", "refs/remotes/origin/main"])

    assert %{gate: %{status: :unchecked, detail: detail}} =
             Health.summarize(repository, availability)

    assert detail =~ "has not been fetched from GitHub yet"
  end

  test "a branch missing on GitHub and a failed fetch say different things" do
    {repository, path} = checkout()
    commit!(path, "./check")

    for {result, expected} <- [
          {{:error, {:branch_not_on_github, "main"}}, "Branch main is not on GitHub."},
          {{:error, {:repository_source_fetch_failed, 128, "fatal: Authentication failed"}},
           "Could not fetch main: fatal: Authentication failed"}
        ] do
      Application.put_env(:ptc_manager, :health_test_refresh, result)

      assert %{gate: %{status: :attention, detail: ^expected}} = Health.summarize(repository)
      refute expected =~ "Commit the repository"
    end
  end

  defp checkout do
    suffix = System.unique_integer([:positive, :monotonic])
    {owner, name} = {"health-owner-#{suffix}", "health-repo-#{suffix}"}
    path = Path.join(System.tmp_dir!(), "#{owner}-#{name}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["remote", "add", "origin", "git@github.com:#{owner}/#{name}.git"])

    repository =
      repository_fixture(%{github_owner: owner, github_name: name, local_path: path})

    {repository, path}
  end

  defp commit!(path, command) do
    File.write!(
      Path.join(path, ".ptc-manager.yml"),
      "version: 1\nverification:\n  before_publish: #{command}\n  timeout_minutes: 10\n"
    )

    git!(path, ["add", ".ptc-manager.yml"])
    git!(path, ["commit", "-m", "contract"])
    git!(path, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
