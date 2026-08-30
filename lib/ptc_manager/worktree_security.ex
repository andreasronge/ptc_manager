defmodule PtcManager.WorktreeSecurity do
  @moduledoc "Validates that agent worktrees cannot be replaced through writable ancestors."

  import Bitwise

  @writable_by_group_or_other 0o022

  def validate_configured_root(path) do
    if Application.get_env(:ptc_manager, :worktree_permission_check, true) do
      with {:ok, owner_uid} <- configured_owner_uid() do
        validate_root(path, owner_uid: owner_uid, trusted_ancestor_uids: [0])
      end
    else
      :ok
    end
  end

  def validate_root(path, opts \\ [])

  def validate_root(path, opts) when is_binary(path) and is_list(opts) do
    if Path.type(path) == :absolute do
      expanded = Path.expand(path)
      owner_uid = Keyword.get(opts, :owner_uid)
      trusted_ancestor_uids = Keyword.get(opts, :trusted_ancestor_uids, [0])

      with {:ok, stat} <- lstat(expanded),
           :ok <- validate_directory(expanded, stat),
           :ok <- validate_mode(expanded, stat.mode),
           :ok <- validate_root_owner(expanded, stat.uid, owner_uid) do
        expanded
        |> Path.dirname()
        |> validate_ancestors(trusted_ancestor_uids)
      end
    else
      {:error, :worktree_root_unavailable}
    end
  end

  def validate_root(_path, _opts), do: {:error, :worktree_root_unavailable}

  def infrastructure_error?(:worktree_root_unavailable), do: true
  def infrastructure_error?(:worktree_owner_unavailable), do: true
  def infrastructure_error?({:worktree_root_io, _path, _reason}), do: true

  def infrastructure_error?({kind, _path})
      when kind in [
             :unsafe_worktree_symlink,
             :unsafe_worktree_ancestor,
             :unsafe_worktree_owner,
             :writable_worktree_ancestor
           ],
      do: true

  def infrastructure_error?(_reason), do: false

  defp validate_ancestors(path, trusted_uids) do
    with {:ok, stat} <- lstat(path),
         :ok <- validate_directory(path, stat),
         :ok <- validate_mode(path, stat.mode),
         :ok <- validate_ancestor_owner(path, stat.uid, trusted_uids) do
      parent = Path.dirname(path)

      if parent == path, do: :ok, else: validate_ancestors(parent, trusted_uids)
    end
  end

  defp lstat(path) do
    case File.lstat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :worktree_root_unavailable}
      {:error, reason} -> {:error, {:worktree_root_io, path, reason}}
    end
  end

  defp validate_directory(_path, %{type: :directory}), do: :ok

  defp validate_directory(path, %{type: :symlink}),
    do: {:error, {:unsafe_worktree_symlink, path}}

  defp validate_directory(path, _stat),
    do: {:error, {:unsafe_worktree_ancestor, path}}

  defp validate_mode(path, mode) do
    if (mode &&& @writable_by_group_or_other) == 0,
      do: :ok,
      else: {:error, {:writable_worktree_ancestor, path}}
  end

  defp validate_root_owner(_path, _actual_uid, nil), do: :ok
  defp validate_root_owner(_path, owner_uid, owner_uid), do: :ok

  defp validate_root_owner(path, _actual_uid, _owner_uid),
    do: {:error, {:unsafe_worktree_owner, path}}

  defp validate_ancestor_owner(path, uid, trusted_uids) do
    if uid in trusted_uids, do: :ok, else: {:error, {:unsafe_worktree_owner, path}}
  end

  defp configured_owner_uid do
    case Application.get_env(:ptc_manager, :worktree_owner_uid) do
      uid when is_integer(uid) and uid >= 0 -> {:ok, uid}
      _unset -> lookup_owner_uid(Application.get_env(:ptc_manager, :herdr_run_as_user))
    end
  end

  defp lookup_owner_uid(user) when is_binary(user) and user != "" do
    case System.cmd("/usr/bin/id", ["-u", user], stderr_to_stdout: true) do
      {output, 0} -> parse_uid(output)
      {_output, _status} -> {:error, :worktree_owner_unavailable}
    end
  rescue
    _error -> {:error, :worktree_owner_unavailable}
  end

  defp lookup_owner_uid(_user), do: {:error, :worktree_owner_unavailable}

  defp parse_uid(output) do
    case Integer.parse(String.trim(output)) do
      {uid, ""} when uid >= 0 -> {:ok, uid}
      _invalid -> {:error, :worktree_owner_unavailable}
    end
  end
end
