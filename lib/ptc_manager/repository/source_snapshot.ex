defmodule PtcManager.Repository.SourceSnapshot do
  @moduledoc "Creates and verifies a coordinator-owned read-only clone for planning and exact-commit review evidence."

  import Bitwise

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.Checkout

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @writable_bits 0o222
  @sticky_bit 0o1000
  @setgid_bit 0o2000
  @marker ".ptc-manager-planning-snapshot"

  def prepare(%Repository{} = repository, action_id, existing_snapshot)
      when is_integer(action_id) and is_map(existing_snapshot),
      do: prepare_owned(repository, action_id, existing_snapshot)

  def prepare_review(repository, round_id, ref, sha) when is_integer(round_id) do
    prepare_owned(repository, "review-#{round_id}", %{"source_ref" => ref, "source_sha" => sha})
  end

  def review_identity(repository, round_id, sha) when is_integer(round_id) do
    with {:ok, path} <- Checkout.configured_path(repository),
         true <- is_binary(sha) and Regex.match?(@sha, sha) do
      {:ok,
       %{
         "source_path" => snapshot_path("review-#{round_id}", sha),
         "source_sha" => sha,
         "repository_path" => path
       }}
    else
      _ -> {:error, :repository_snapshot_unavailable}
    end
  end

  def release_review_owned(round_id, %{"repository_path" => path} = ownership)
      when is_integer(round_id) and is_binary(path) do
    if Path.type(path) == :absolute,
      do: release_identity("review-#{round_id}", ownership, path),
      else: {:error, :repository_snapshot_path_mismatch}
  end

  defp prepare_owned(repository, action_id, existing_snapshot) do
    with {:ok, repository_path} <- repository_path(repository),
         {:ok, source} <- source(repository, repository_path, existing_snapshot),
         snapshot_path <- snapshot_path(action_id, source.sha),
         :ok <- ensure_snapshot_root(),
         :ok <- remove_existing_snapshot(snapshot_path, repository_path, action_id, source.sha),
         :ok <-
           clone_snapshot(repository_path, snapshot_path, action_id, source.ref, source.sha),
         :ok <- verify(repository, snapshot_path, source.sha) do
      {:ok, Map.put(source, :path, snapshot_path)}
    end
  end

  def capture(%Repository{} = repository) do
    with {:ok, path} <- repository_path(repository) do
      refresh(repository, path)
    end
  end

  def verify(%Repository{} = repository, path, expected_sha)
      when is_binary(path) and is_binary(expected_sha) do
    with {:ok, repository_path} <- repository_path(repository),
         :ok <- validate_snapshot_root(),
         :ok <- validate_target_directory(path),
         :ok <- validate_marker(path, repository_path, expected_sha),
         :ok <- verify_revision(path, expected_sha),
         :ok <- verify_detached(path),
         :ok <- verify_clean(path),
         :ok <- verify_read_only(path, path) do
      :ok
    end
  end

  def release(%Repository{} = repository, action_id, snapshot)
      when is_integer(action_id) and is_map(snapshot),
      do: release_owned(repository, action_id, snapshot)

  def release_review(repository, round_id, snapshot) when is_integer(round_id),
    do: release_owned(repository, "review-#{round_id}", snapshot)

  defp release_owned(
         repository,
         action_id,
         %{"source_sha" => sha, "source_path" => path} = snapshot
       )
       when is_binary(sha) and is_binary(path) do
    with {:ok, repository_path} <- repository_path(repository),
         do: release_identity(action_id, snapshot, repository_path)
  end

  defp release_owned(_, _, _), do: :ok

  defp release_identity(action_id, snapshot, repository_path) do
    with source_sha when is_binary(source_sha) <- snapshot["source_sha"],
         true <- Regex.match?(@sha, source_sha),
         source_path when is_binary(source_path) <- snapshot["source_path"],
         expected_path <- snapshot_path(action_id, source_sha),
         true <- Path.expand(source_path) == expected_path do
      case File.lstat(expected_path) do
        {:error, :enoent} ->
          :ok

        _ ->
          with :ok <- validate_snapshot_root(),
               do: remove_existing_snapshot(expected_path, repository_path, action_id, source_sha)
      end
    else
      nil -> :ok
      false -> {:error, :repository_snapshot_path_mismatch}
      {:error, _reason} = error -> error
      _failure -> :ok
    end
  end

  defp source(_repository, _path, %{"source_sha" => sha, "source_ref" => ref})
       when is_binary(sha) and is_binary(ref) do
    if Regex.match?(@sha, sha) and ref != "" and byte_size(ref) <= 240,
      do: {:ok, %{sha: sha, ref: ref}},
      else: {:error, :repository_snapshot_unavailable}
  end

  defp source(repository, path, _snapshot), do: refresh(repository, path)

  defp refresh(repository, path) do
    updater = Application.fetch_env!(:ptc_manager, :source_updater)

    updater.refresh(repository)
    |> case do
      {:ok, %{path: ^path} = source} ->
        {:ok, source}

      {:ok, %{path: other_path} = source} when is_binary(other_path) ->
        if Path.expand(other_path) == Path.expand(path),
          do: {:ok, %{source | path: Path.expand(path)}},
          else: {:error, :repository_source_path_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp clone_snapshot(repository_path, path, action_id, source_ref, source_sha) do
    bundle_path = Path.join([path, ".git", "ptc-manager-source.bundle"])

    # A local clone starts upload-pack in a child Git process that re-checks the
    # worker-owned .git directory without inheriting this command's narrow
    # safe.directory setting. Create the bundle while Git is already operating
    # in the trusted source checkout, then import it into a coordinator-owned
    # repository without hardlinks back to the mutable source.
    with :ok <- File.mkdir_p(Path.join(path, ".git")),
         :ok <- write_marker(path, repository_path, action_id, source_sha),
         {_output, 0} <- git_command(["init", "--quiet", "--", path]),
         {_output, 0} <-
           git_command(git_args(repository_path, ["bundle", "create", bundle_path, source_ref])),
         {_output, 0} <-
           git_command(["-C", path, "fetch", "--no-tags", "--", bundle_path, source_sha]),
         :ok <- File.rm(bundle_path),
         {_output, 0} <- git_command(["-C", path, "checkout", "--detach", source_sha]),
         :ok <- make_read_only(path) do
      :ok
    else
      _failure ->
        cleanup_failed_clone(path)
        {:error, :repository_snapshot_clone_failed}
    end
  end

  defp write_marker(path, repository_path, action_id, source_sha) do
    body =
      Jason.encode!(%{
        "action_id" => action_id,
        "repository_path" => repository_path,
        "source_sha" => source_sha
      })

    with :ok <- File.write(marker_path(path), body, [:exclusive]),
         :ok <- File.chmod(marker_path(path), 0o440) do
      :ok
    else
      _failure -> {:error, :repository_snapshot_marker_failed}
    end
  end

  defp make_read_only(path) do
    case System.cmd("/bin/chmod", ["-R", "a-w", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :repository_snapshot_permissions_failed}
    end
  end

  defp make_owner_writable(path) do
    case System.cmd("/bin/chmod", ["-R", "u+w", path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :repository_snapshot_permissions_failed}
    end
  end

  defp remove_existing_snapshot(path, repository_path, action_id, source_sha) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with :ok <- validate_target_directory(path),
             :ok <- validate_marker(path, repository_path, source_sha, action_id),
             :ok <- make_owner_writable(path),
             {:ok, _removed} <- File.rm_rf(path),
             false <- File.exists?(path) do
          :ok
        else
          true -> {:error, :repository_snapshot_cleanup_failed}
          {:error, _reason} = error -> error
          _failure -> {:error, :repository_snapshot_cleanup_failed}
        end

      {:ok, %{type: :symlink}} ->
        {:error, :repository_snapshot_symlink}

      _failure ->
        {:error, :repository_snapshot_path_unavailable}
    end
  end

  defp cleanup_failed_clone(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        _ = make_owner_writable(path)
        _ = File.rm_rf(path)
        :ok

      _missing_or_unsafe ->
        :ok
    end
  end

  defp verify_revision(path, expected_sha) do
    case git(path, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      {:ok, ^expected_sha} -> :ok
      _failure -> {:error, :repository_snapshot_changed}
    end
  end

  defp verify_detached(path) do
    case git_command(["-C", path, "symbolic-ref", "-q", "HEAD"]) do
      {_output, 1} -> :ok
      {_output, _status} -> {:error, :repository_snapshot_not_detached}
    end
  end

  defp verify_clean(path) do
    case git(path, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, ""} -> :ok
      {:ok, _changes} -> {:error, :repository_snapshot_dirty}
      {:error, _reason} -> {:error, :repository_snapshot_unavailable}
    end
  end

  defp verify_read_only(path, snapshot_path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        verify_symlink_inside_snapshot(path, snapshot_path)

      {:ok, %{type: :directory, mode: mode}} ->
        with true <- (mode &&& @writable_bits) == 0,
             {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case verify_read_only(Path.join(path, entry), snapshot_path) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        else
          false -> {:error, :repository_snapshot_writable}
          {:error, _reason} -> {:error, :repository_snapshot_unavailable}
        end

      {:ok, %{mode: mode}} ->
        if (mode &&& @writable_bits) == 0,
          do: :ok,
          else: {:error, :repository_snapshot_writable}

      {:error, _reason} ->
        {:error, :repository_snapshot_unavailable}
    end
  end

  defp verify_symlink_inside_snapshot(path, snapshot_path) do
    with {:ok, root} <- resolve_path(snapshot_path),
         relative <- Path.relative_to(Path.expand(path), Path.expand(snapshot_path)),
         false <- relative == ".." or String.starts_with?(relative, "../"),
         {:ok, _resolved} <-
           resolve_components_within(root, path_components(relative), 40, root) do
      :ok
    else
      _failure -> {:error, :repository_snapshot_symlink_escape}
    end
  end

  defp resolve_path(path) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: resolve_components("/", path_components(path), 40),
      else: {:error, :relative_path}
  end

  defp path_components(path),
    do: path |> String.split("/", trim: true)

  defp resolve_components(_current, _components, 0), do: {:error, :too_many_symlinks}

  defp resolve_components(current, [], _remaining), do: {:ok, Path.expand(current)}

  defp resolve_components(current, ["." | rest], remaining),
    do: resolve_components(current, rest, remaining)

  defp resolve_components(current, [".." | rest], remaining),
    do: resolve_components(Path.dirname(current), rest, remaining)

  defp resolve_components(current, [component | rest], remaining) do
    candidate = Path.join(current, component)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          {target_base, target_components} =
            if Path.type(target) == :absolute,
              do: {"/", path_components(target)},
              else: {current, path_components(target)}

          resolve_components(target_base, target_components ++ rest, remaining - 1)
        end

      {:ok, _stat} ->
        resolve_components(candidate, rest, remaining)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_components_within(_current, _components, 0, _root),
    do: {:error, :too_many_symlinks}

  defp resolve_components_within(current, [], _remaining, _root), do: {:ok, current}

  defp resolve_components_within(current, ["." | rest], remaining, root),
    do: resolve_components_within(current, rest, remaining, root)

  defp resolve_components_within(current, [".." | rest], remaining, root) do
    parent = Path.dirname(current)

    if inside_root?(parent, root),
      do: resolve_components_within(parent, rest, remaining, root),
      else: {:error, :path_escape}
  end

  defp resolve_components_within(current, [component | rest], remaining, root) do
    candidate = Path.join(current, component)

    with true <- inside_root?(candidate, root) do
      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          with {:ok, target} <- File.read_link(candidate),
               false <- Path.type(target) == :absolute do
            resolve_components_within(
              current,
              path_components(target) ++ rest,
              remaining - 1,
              root
            )
          else
            _failure -> {:error, :path_escape}
          end

        {:ok, _stat} ->
          resolve_components_within(candidate, rest, remaining, root)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :path_escape}
    end
  end

  defp inside_root?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp validate_marker(path, repository_path, source_sha, action_id \\ nil) do
    marker_path = marker_path(path)

    with {:ok, %{type: :regular, mode: mode, uid: uid}} <- File.lstat(marker_path),
         true <- (mode &&& @writable_bits) == 0,
         {:ok, %{uid: root_uid}} <- File.stat(snapshot_root()),
         true <- uid == root_uid,
         {:ok, body} <- File.read(marker_path),
         {:ok, marker} <- Jason.decode(body),
         true <- marker["repository_path"] == repository_path,
         true <- marker["source_sha"] == source_sha,
         true <- is_nil(action_id) or marker["action_id"] == action_id do
      :ok
    else
      _failure -> {:error, :repository_snapshot_marker_invalid}
    end
  end

  defp ensure_snapshot_root do
    root = snapshot_root()

    with {:ok, coordinator_uid} <- coordinator_uid(),
         :ok <- validate_configured_snapshot_root(root, coordinator_uid),
         :ok <- create_or_authenticate_snapshot_root(root, coordinator_uid),
         :ok <- File.chmod(root, 0o2750) do
      validate_snapshot_root()
    else
      _failure -> {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp validate_configured_snapshot_root(root, coordinator_uid) do
    expanded = Path.expand(root)
    parent = Path.dirname(expanded)
    basename = Path.basename(expanded)

    with true <- Path.type(root) == :absolute,
         true <- root == expanded,
         true <- parent not in [expanded, "/"],
         true <- String.contains?(basename, "snapshot"),
         {:ok, %{type: :directory, mode: parent_mode, uid: parent_uid}} <- File.lstat(parent),
         true <- parent_uid in [0, coordinator_uid],
         true <- protected_parent?(parent_mode),
         :ok <- validate_snapshot_ancestors(parent, coordinator_uid) do
      case File.lstat(expanded) do
        {:error, :enoent} ->
          :ok

        {:ok, _stat} ->
          authenticate_existing_snapshot_root(expanded, coordinator_uid)

        _unsafe ->
          {:error, :repository_snapshot_root_unavailable}
      end
    else
      _failure -> {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp create_or_authenticate_snapshot_root(root, coordinator_uid) do
    case File.mkdir(root) do
      :ok -> authenticate_created_snapshot_root(root, coordinator_uid)
      {:error, :eexist} -> authenticate_existing_snapshot_root(root, coordinator_uid)
      {:error, _reason} = error -> error
    end
  end

  defp authenticate_created_snapshot_root(root, coordinator_uid) do
    case File.lstat(root) do
      {:ok, %{type: :directory, uid: ^coordinator_uid}} -> :ok
      _unsafe -> {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp authenticate_existing_snapshot_root(root, coordinator_uid) do
    case File.lstat(root) do
      {:ok, %{type: :directory, mode: mode, uid: ^coordinator_uid}}
      when (mode &&& 0o022) == 0 ->
        :ok

      _unsafe ->
        {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp protected_parent?(mode),
    do: (mode &&& 0o022) == 0 or (mode &&& @sticky_bit) != 0

  defp coordinator_uid do
    case System.cmd("/usr/bin/id", ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _invalid -> {:error, :repository_snapshot_root_unavailable}
        end

      _failure ->
        {:error, :repository_snapshot_root_unavailable}
    end
  rescue
    _error -> {:error, :repository_snapshot_root_unavailable}
  end

  defp validate_snapshot_root do
    root = snapshot_root()

    with true <- Path.type(root) == :absolute,
         {:ok, %{type: :directory, mode: mode, uid: uid}} <- File.lstat(root),
         true <- (mode &&& 0o022) == 0,
         true <- (mode &&& @setgid_bit) != 0,
         :ok <- validate_snapshot_ancestors(Path.dirname(root), uid) do
      :ok
    else
      _failure -> {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp validate_snapshot_ancestors(path, owner_uid) do
    if Application.get_env(:ptc_manager, :planning_snapshot_permission_check, false),
      do: do_validate_snapshot_ancestors(path, owner_uid),
      else: :ok
  end

  defp do_validate_snapshot_ancestors(path, owner_uid) do
    with {:ok, %{type: :directory, mode: mode, uid: uid}} <- File.lstat(path),
         true <- (mode &&& 0o022) == 0 or (mode &&& @sticky_bit) != 0,
         true <- uid in [0, owner_uid] do
      parent = Path.dirname(path)
      if parent == path, do: :ok, else: do_validate_snapshot_ancestors(parent, owner_uid)
    else
      _failure -> {:error, :repository_snapshot_root_unavailable}
    end
  end

  defp validate_target_directory(path) do
    expanded = Path.expand(path)

    with true <- Path.dirname(expanded) == Path.expand(snapshot_root()),
         {:ok, %{type: :directory, uid: uid}} <- File.lstat(expanded),
         {:ok, %{uid: root_uid}} <- File.stat(snapshot_root()),
         true <- uid == root_uid do
      :ok
    else
      false -> {:error, :repository_snapshot_path_mismatch}
      {:ok, %{type: :symlink}} -> {:error, :repository_snapshot_symlink}
      _failure -> {:error, :repository_snapshot_path_unavailable}
    end
  end

  defp snapshot_path(action_id, source_sha) do
    suffix = String.slice(source_sha, 0, 12)
    Path.join(snapshot_root(), "ptc-manager-planning-a#{action_id}-#{suffix}") |> Path.expand()
  end

  defp marker_path(path), do: Path.join([path, ".git", @marker])

  defp snapshot_root do
    Application.get_env(:ptc_manager, :planning_snapshot_root) ||
      Path.join(System.tmp_dir!(), "ptc-manager-planning-snapshots")
  end

  defp repository_path(repository) do
    Checkout.available_path(repository)
  end

  defp git(path, args) do
    case git_command(git_args(path, args)) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :repository_snapshot_unavailable}
    end
  end

  @doc false
  def git_args(path, args) when is_binary(path) and is_list(args) do
    expanded = Path.expand(path)
    ["-c", "safe.directory=#{expanded}", "-C", expanded, "--no-optional-locks" | args]
  end

  defp git_command(args) do
    binary = Application.get_env(:ptc_manager, :planning_git_binary, "/usr/bin/git")

    timeout = System.find_executable("timeout") || System.find_executable("gtimeout")

    System.cmd(timeout, ["--kill-after=5s", "120s", binary | args],
      env: [{"GIT_OPTIONAL_LOCKS", "0"}],
      stderr_to_stdout: true
    )
  rescue
    _error -> {"", 127}
  end
end
