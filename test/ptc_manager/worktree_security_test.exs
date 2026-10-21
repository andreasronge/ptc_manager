defmodule PtcManager.WorktreeSecurityTest do
  # Some tests set the application environment the configured root reads.
  use ExUnit.Case, async: false

  alias PtcManager.WorktreeSecurity

  setup do
    root =
      Path.expand(
        "../../tmp/worktree-security-#{System.unique_integer([:positive, :monotonic])}",
        __DIR__
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o750)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root}
  end

  test "accepts a private worktree root with non-writable ancestors", %{root: root} do
    uid = File.stat!(root).uid

    assert :ok =
             WorktreeSecurity.validate_root(root, owner_uid: uid, trusted_ancestor_uids: [0, uid])
  end

  test "rejects a group-writable worktree ancestor", %{root: root} do
    shared = Path.join(root, "shared")
    worktrees = Path.join(shared, "worktrees")
    File.mkdir_p!(worktrees)
    File.chmod!(shared, 0o770)
    File.chmod!(worktrees, 0o750)

    assert {:error, {:writable_worktree_ancestor, ^shared}} =
             WorktreeSecurity.validate_root(worktrees,
               owner_uid: File.stat!(worktrees).uid,
               trusted_ancestor_uids: [0, File.stat!(root).uid]
             )
  end

  test "rejects a symlink in the worktree path", %{root: root} do
    private = Path.join(root, "private")
    link = Path.join(root, "linked")
    File.mkdir_p!(private)
    File.ln_s!(private, link)

    assert {:error, {:unsafe_worktree_symlink, ^link}} =
             WorktreeSecurity.validate_root(link,
               owner_uid: File.stat!(private).uid,
               trusted_ancestor_uids: [0, File.stat!(root).uid]
             )
  end

  test "rejects a relative worktree root" do
    assert {:error, :worktree_root_unavailable} = WorktreeSecurity.validate_root("worktrees")
  end

  test "rejects an ancestor not owned by a trusted identity", %{root: root} do
    assert {:error, {:unsafe_worktree_owner, _path}} =
             WorktreeSecurity.validate_root(root,
               owner_uid: File.stat!(root).uid,
               trusted_ancestor_uids: []
             )
  end

  test "classifies every filesystem lookup failure as retryable infrastructure", %{root: root} do
    blocker = Path.join(root, "not-a-directory")
    File.write!(blocker, "file")

    assert {:error, reason = {:worktree_root_io, _path, :enotdir}} =
             WorktreeSecurity.validate_root(Path.join(blocker, "worktrees"))

    assert WorktreeSecurity.infrastructure_error?(reason)
  end

  describe "the configured root" do
    setup do
      keys = [:worktree_permission_check, :worktree_owner_uid, :herdr_run_as_user]
      previous = Map.new(keys, &{&1, Application.fetch_env(:ptc_manager, &1)})

      on_exit(fn ->
        Enum.each(previous, fn
          {key, {:ok, value}} -> Application.put_env(:ptc_manager, key, value)
          {key, :error} -> Application.delete_env(:ptc_manager, key)
        end)
      end)

      Application.put_env(:ptc_manager, :worktree_permission_check, true)
      Application.delete_env(:ptc_manager, :worktree_owner_uid)
      :ok
    end

    test "agents on the service account trust the service account's own directories",
         %{root: root} do
      Application.put_env(:ptc_manager, :herdr_run_as_user, nil)

      assert :ok = WorktreeSecurity.validate_configured_root(root)
    end

    test "a separate agent account still trusts only root-owned ancestors", %{root: root} do
      Application.put_env(:ptc_manager, :herdr_run_as_user, "root")

      assert {:error, {:unsafe_worktree_owner, _path}} =
               WorktreeSecurity.validate_configured_root(root)
    end
  end
end
