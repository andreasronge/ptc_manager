defmodule PtcManager.Repository.CheckoutTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Operations
  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.Checkout
  alias PtcManager.Repository.CheckoutMigrationAudit
  alias PtcManager.Repository.GitProbe
  alias PtcManager.Repository.StartupPreflight
  alias PtcManager.Repo

  test "each repository resolves only its own normalized checkout" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-repository-checkout-#{System.unique_integer([:positive, :monotonic])}"
      )

    first_path = Path.join(root, "first")
    second_path = Path.join(root, "second")
    File.mkdir_p!(first_path)
    File.mkdir_p!(second_path)
    on_exit(fn -> File.rm_rf!(root) end)

    previous = Application.get_env(:ptc_manager, :repository_path)
    Application.put_env(:ptc_manager, :repository_path, first_path)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:ptc_manager, :repository_path),
        else: Application.put_env(:ptc_manager, :repository_path, previous)
    end)

    first = %Repository{github_owner: "owner", github_name: "first", local_path: first_path}
    second = %Repository{github_owner: "owner", github_name: "second", local_path: second_path}

    assert {:ok, ^first_path} = Checkout.available_path(first)
    assert {:ok, ^second_path} = Checkout.available_path(second)
  end

  test "rejects relative checkout paths before normalization" do
    assert {:error, changeset} =
             Operations.create_repository(%{
               github_owner: "owner",
               github_name: "relative",
               local_path: "relative/repository"
             })

    assert "must be an absolute path" in errors_on(changeset).local_path
  end

  test "refuses an identical stored checkout path" do
    path = temporary_directory!("shared")
    _first = repository!("first", path)

    assert {:error, changeset} =
             Operations.create_repository(%{
               github_owner: "owner",
               github_name: "second",
               local_path: path
             })

    assert "has already been taken" in errors_on(changeset).local_path
  end

  test "refuses checkout aliases that resolve through a symlink" do
    path = temporary_directory!("canonical")
    alias_path = path <> "-alias"
    File.ln_s!(path, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    first = repository!("first", path)
    _second = repository!("second", alias_path)

    assert {:error, :repository_checkout_shared} = Checkout.available_path(first)
  end

  test "real Git identity verifies the root and GitHub origin" do
    path = git_repository!("andreas", "verified")
    repository = %Repository{github_owner: "andreas", github_name: "verified", local_path: path}

    with_checkout_probe(GitProbe, fn ->
      assert {:ok, ^path} = Checkout.available_path(repository)

      mismatch = %{repository | github_name: "different"}
      assert {:error, :repository_origin_mismatch} = Checkout.available_path(mismatch)
    end)
  end

  test "real Git identity detects linked worktrees sharing a common directory" do
    path = git_repository!("andreas", "shared-git")
    linked_path = path <> "-linked-worktree"
    git!(path, ["worktree", "add", "-b", "linked", linked_path, "main"])
    on_exit(fn -> File.rm_rf!(linked_path) end)
    first = repository!("shared-git", path, "andreas")
    _second = repository!("other-record", linked_path, "andreas")

    with_checkout_probe(GitProbe, fn ->
      assert {:error, :repository_checkout_shared} = Checkout.available_path(first)
    end)
  end

  test "batch availability preserves sharing evidence from an origin mismatch" do
    path = git_repository!("andreas", "batch-shared")
    alias_path = path <> "-alias"
    File.ln_s!(path, alias_path)
    on_exit(fn -> File.rm(alias_path) end)
    first = repository!("batch-shared", path, "andreas")
    second = repository!("wrong-record", alias_path, "andreas")

    with_checkout_probe(GitProbe, fn ->
      availability = Checkout.availability([first, second])

      assert Map.fetch!(availability, first.id) == {:error, :repository_checkout_shared}
      assert Map.fetch!(availability, second.id) == {:error, :repository_checkout_shared}
    end)
  end

  test "batch availability probes each repository checkout once" do
    first_path = temporary_directory!("batch-first")
    second_path = temporary_directory!("batch-second")
    first = repository!("batch-first", first_path)
    second = repository!("batch-second", second_path)

    Process.put(:checkout_probe_count, 0)
    on_exit(fn -> Process.delete(:checkout_probe_count) end)

    with_checkout_probe(__MODULE__.CountingProbe, fn ->
      availability = Checkout.availability([first, second])

      assert Map.fetch!(availability, first.id) == {:ok, first_path}
      assert Map.fetch!(availability, second.id) == {:ok, second_path}

      assert Process.get(:checkout_probe_count) == 2
    end)
  end

  test "startup preflight imports the legacy path once for an empty repository row" do
    path = temporary_directory!("legacy")
    repository = repository!("legacy", nil)

    assert :ok = StartupPreflight.run(path)
    assert Repo.get!(Repository, repository.id).local_path == path
  end

  test "startup preflight rolls back a legacy path that fails validation" do
    repository = repository!("invalid-legacy", nil)
    missing_path = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")

    assert {:error, {"owner/invalid-legacy", :repository_path_unavailable}} =
             StartupPreflight.run(missing_path)

    assert is_nil(Repo.get!(Repository, repository.id).local_path)
  end

  test "startup preflight blocks a conflicting legacy path" do
    first_path = temporary_directory!("current")
    second_path = temporary_directory!("legacy-conflict")
    _repository = repository!("conflict", first_path)

    assert {:error, :legacy_repository_path_conflict} = StartupPreflight.run(second_path)
  end

  test "startup preflight requires the legacy variable to be removed for multiple repositories" do
    first_path = temporary_directory!("legacy-first")
    second_path = temporary_directory!("legacy-second")
    _first = repository!("legacy-first", first_path)
    _second = repository!("legacy-second", second_path)

    assert {:error, :legacy_repository_path_ambiguous} = StartupPreflight.run(first_path)
  end

  test "migration audit diagnoses legacy duplicate paths before the unique index" do
    Repo.query!("DROP INDEX repositories_local_path_index")
    path = temporary_directory!("migration-duplicate")
    _first = repository!("migration-first", path)
    _second = repository!("migration-second", path)

    assert_raise RuntimeError,
                 ~r/2 duplicate local_path value|1 duplicate local_path value/,
                 fn ->
                   CheckoutMigrationAudit.ensure_no_duplicate_local_paths!(Repo)
                 end
  end

  test "external PR worktrees are namespaced even when PR numbers match" do
    first = %Repository{github_owner: "owner", github_name: "first"}
    second = %Repository{github_owner: "owner", github_name: "second"}

    first_name = Checkout.external_worktree_name(first, 17, 9, 1)
    second_name = Checkout.external_worktree_name(second, 17, 9, 1)

    assert first_name == "owner-first-external-pr-17-action-9-f1"
    assert second_name == "owner-second-external-pr-17-action-9-f1"
    refute first_name == second_name
  end

  defp repository!(name, path, owner \\ "owner") do
    {:ok, repository} =
      Operations.create_repository(%{
        github_owner: owner,
        github_name: name,
        local_path: path
      })

    repository
  end

  defmodule CountingProbe do
    def checkout_identity(repository, path) do
      Process.put(:checkout_probe_count, Process.get(:checkout_probe_count, 0) + 1)

      {:ok,
       %{
         top_level: path,
         common_dir: path,
         remote_identity: {repository.github_owner, repository.github_name}
       }}
    end
  end

  # System.unique_integer/1 restarts with the VM, so two runs pick the same
  # names. A run killed before its on_exit hooks — the partition budget sends
  # SIGTERM — leaves its directories behind, and every later run then collides
  # with them. Random bytes keep the names unique across runs as well as within
  # one, so a leftover can no longer fail the next run.
  defp temporary_directory!(name) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    root = Path.join(System.tmp_dir!(), "ptc-repository-checkout-#{name}-#{suffix}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp git_repository!(owner, name) do
    path = temporary_directory!(name)
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "PtcManager Test"])
    git!(path, ["config", "user.email", "ptc-manager@example.invalid"])
    File.write!(Path.join(path, "README.md"), "# Test\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "Initial commit"])
    git!(path, ["remote", "add", "origin", "git@github.com:#{owner}/#{name}.git"])
    path
  end

  defp git!(path, args) do
    {output, status} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp with_checkout_probe(probe, function) do
    previous = Application.get_env(:ptc_manager, :checkout_probe)
    Application.put_env(:ptc_manager, :checkout_probe, probe)

    try do
      function.()
    after
      Application.put_env(:ptc_manager, :checkout_probe, previous)
    end
  end
end
