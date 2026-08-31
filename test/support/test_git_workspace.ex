defmodule PtcManager.TestGitWorkspace do
  @moduledoc """
  Disposable real Git repository and worktree support for integration scenarios.

  Creation and removal use the injected command runner so acknowledgement-loss
  windows remain controllable and visible in the scenario trace. Reconciliation
  reads Git's authoritative worktree registry and cleanup refuses any path,
  branch, head, or filesystem identity that does not match the retained record.
  """

  alias PtcManager.CommandRunner
  alias PtcManager.TestCommandRunner.System, as: SystemCommandRunner

  defstruct [:root, :repository, :worktree_root, :source_sha, :runner]

  defmodule Worktree do
    @moduledoc false
    defstruct [:key, :path, :branch, :head_sha]
  end

  defmodule HerdrCommand do
    @moduledoc false
    use GenServer

    defstruct [:pid]

    def start_link({workspace, runner}) do
      GenServer.start_link(__MODULE__, {workspace, runner})
    end

    def gateway(pid), do: %__MODULE__{pid: pid}
    def workspaces(%__MODULE__{} = command), do: GenServer.call(command.pid, :workspaces)

    def run(%__MODULE__{} = command, args, timeout) do
      GenServer.call(command.pid, {:run, args, timeout}, :infinity)
    end

    @impl true
    def init({workspace, runner}) do
      {:ok, %{workspace: %{workspace | runner: runner}, workspaces: %{}}}
    end

    @impl true
    def handle_call(:workspaces, _from, state) do
      {:reply, state.workspaces |> Map.values() |> Enum.sort_by(& &1.id), state}
    end

    def handle_call({:run, ["worktree", "create" | _] = args, timeout}, _from, state) do
      path = PtcManager.TestGitWorkspace.command_option!(args, "--path")
      result = PtcManager.TestGitWorkspace.run(state.workspace, args, timeout)

      workspaces =
        if File.dir?(path) do
          id = workspace_id(path)
          Map.put(state.workspaces, id, %{id: id, path: path})
        else
          state.workspaces
        end

      {:reply, result, %{state | workspaces: workspaces}}
    end

    def handle_call({:run, ["worktree", "open" | _] = args, _timeout}, _from, state) do
      path = PtcManager.TestGitWorkspace.command_option!(args, "--path")

      with :ok <- PtcManager.TestGitWorkspace.validate_open_args(args),
           {id, _workspace} <-
             Enum.find(state.workspaces, fn {_id, workspace} -> workspace.path == path end) do
        {:reply, {:ok, response(id)}, state}
      else
        nil -> {:reply, {:error, :test_herdr_workspace_missing}, state}
        {:error, _reason} = error -> {:reply, error, state}
      end
    end

    def handle_call({:run, ["worktree", "remove" | _] = args, timeout}, _from, state) do
      id = PtcManager.TestGitWorkspace.command_option!(args, "--workspace")

      case Map.fetch(state.workspaces, id) do
        {:ok, workspace} ->
          result = PtcManager.TestGitWorkspace.run(state.workspace, args, timeout)

          workspaces =
            if File.exists?(workspace.path),
              do: state.workspaces,
              else: Map.delete(state.workspaces, id)

          {:reply, result, %{state | workspaces: workspaces}}

        :error ->
          {:reply, {:error, :test_herdr_workspace_missing}, state}
      end
    end

    def handle_call({:run, args, timeout}, _from, state) do
      {:reply, PtcManager.TestGitWorkspace.run(state.workspace, args, timeout), state}
    end

    defp response(id) do
      Jason.encode!(%{
        "result" => %{
          "workspace" => %{"workspace_id" => id},
          "root_pane" => %{"pane_id" => "#{id}:p1"}
        }
      })
    end

    defp workspace_id(path),
      do: "test-worktree:" <> Base.url_encode64(path, padding: false)
  end

  def new!(root) when is_binary(root) do
    root = Path.expand(root)
    File.mkdir_p!(root)
    root = run!("/bin/pwd", ["-P"], cd: root) |> String.trim()
    repository = Path.join(root, "repository")
    worktree_root = Path.join(root, "worktrees")

    File.mkdir_p!(worktree_root)
    run!(git!(), ["init", "--initial-branch=main", repository])
    run!(git!(), ["-C", repository, "config", "user.name", "PtcManager Test"])
    run!(git!(), ["-C", repository, "config", "user.email", "ptc-manager@example.invalid"])
    run!(git!(), ["-C", repository, "config", "commit.gpgSign", "false"])
    run!(git!(), ["-C", repository, "config", "core.hooksPath", "/dev/null"])
    File.write!(Path.join(repository, "README.md"), "# Test repository\n")
    run!(git!(), ["-C", repository, "add", "README.md"])
    run!(git!(), ["-C", repository, "commit", "-m", "Initial commit"])
    source_sha = run!(git!(), ["-C", repository, "rev-parse", "HEAD"]) |> String.trim()

    %__MODULE__{
      root: root,
      repository: repository,
      worktree_root: worktree_root,
      source_sha: source_sha
    }
  end

  def worktree(%__MODULE__{} = workspace, key) when is_binary(key) do
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, key) do
      raise ArgumentError, "worktree key must contain only lowercase letters, numbers, _ or -"
    end

    %Worktree{
      key: key,
      path: Path.join(workspace.worktree_root, key),
      branch: "ptc-test/#{key}",
      head_sha: workspace.source_sha
    }
  end

  def with_runner(%__MODULE__{} = workspace, runner), do: %{workspace | runner: runner}

  def standalone_clone_at!(%__MODULE__{} = workspace, path, branch) do
    run!(git!(), ["clone", "--no-local", workspace.repository, path])
    run!(git!(), ["-C", path, "switch", "-c", branch])
    :ok
  end

  @doc "Implements the Herdr command boundary with real disposable Git worktrees."
  def run(%__MODULE__{runner: runner} = workspace, args, _timeout) when not is_nil(runner) do
    case args do
      ["worktree", "create" | _options] ->
        cwd = command_option!(args, "--cwd")
        branch = command_option!(args, "--branch")
        base = command_option!(args, "--base")
        path = command_option!(args, "--path")

        case CommandRunner.run(
               runner,
               git!(),
               ["-C", cwd, "worktree", "add", "-b", branch, path, base],
               stderr_to_stdout: true
             ) do
          {:ok, _output} -> {:ok, herdr_worktree_response(path)}
          {:error, _reason} = error -> error
        end

      ["worktree", "open" | _options] ->
        path = command_option!(args, "--path")

        with :ok <- validate_open_args(args),
             true <- File.dir?(path) do
          {:ok, herdr_worktree_response(path)}
        else
          false -> {:error, :test_worktree_missing}
          {:error, _reason} = error -> error
        end

      ["worktree", "remove" | _options] ->
        workspace_id = command_option!(args, "--workspace")

        with {:ok, path} <- worktree_path(workspace, workspace_id) do
          CommandRunner.run(
            runner,
            git!(),
            ["-C", workspace.repository, "worktree", "remove", "--force", path],
            stderr_to_stdout: true
          )
        end

      ["agent", "start", name | _options] ->
        {:ok,
         Jason.encode!(%{
           "result" => %{"agent" => %{"agent_session" => %{"value" => "test:#{name}"}}}
         })}

      ["agent", "prompt" | _options] ->
        {:ok, Jason.encode!(%{"result" => %{}})}

      _other ->
        {:error, {:unsupported_test_herdr_command, args}}
    end
  end

  def create(%__MODULE__{} = workspace, runner, %Worktree{} = worktree) do
    with :ok <- validate_identity(workspace, worktree) do
      CommandRunner.run(
        runner,
        git!(),
        [
          "-C",
          workspace.repository,
          "worktree",
          "add",
          "-b",
          worktree.branch,
          worktree.path,
          worktree.head_sha
        ],
        stderr_to_stdout: true
      )
    end
  end

  def ensure(%__MODULE__{} = workspace, runner, %Worktree{} = worktree) do
    case reconcile(workspace, runner, worktree) do
      {:ok, :absent} ->
        case create(workspace, runner, worktree) do
          {:ok, _output} -> {:ok, {:created, worktree}}
          {:error, _reason} = error -> error
        end

      {:ok, {:adopted, _worktree}} = adopted ->
        adopted

      {:error, _reason} = error ->
        error
    end
  end

  def reconcile(%__MODULE__{} = workspace, runner, %Worktree{} = worktree) do
    with :ok <- validate_identity(workspace, worktree),
         {:ok, output} <-
           CommandRunner.run(
             runner,
             git!(),
             ["-C", workspace.repository, "worktree", "list", "--porcelain"],
             stderr_to_stdout: true
           ),
         {:ok, entries} <- parse_worktrees(output) do
      reconcile_entry(entries, workspace, worktree)
    end
  end

  def cleanup(%__MODULE__{} = workspace, runner, %Worktree{} = worktree) do
    with :ok <- validate_identity(workspace, worktree),
         :ok <- validate_directory(worktree.path),
         {:ok, {:adopted, _worktree}} <- reconcile(workspace, runner, worktree),
         {:ok, ""} <- clean_status(runner, worktree.path) do
      CommandRunner.run(
        runner,
        git!(),
        ["-C", workspace.repository, "worktree", "remove", "--force", worktree.path],
        stderr_to_stdout: true
      )
    else
      {:ok, :absent} -> {:ok, :already_removed}
      {:ok, output} when is_binary(output) -> {:error, {:worktree_dirty, output}}
      {:error, _reason} = error -> error
    end
  end

  defp clean_status(runner, path) do
    CommandRunner.run(
      runner,
      git!(),
      ["-C", path, "status", "--porcelain=v1", "--untracked-files=all"],
      stderr_to_stdout: true
    )
  end

  defp herdr_worktree_response(path) do
    id = workspace_id(path)

    Jason.encode!(%{
      "result" => %{
        "workspace" => %{"workspace_id" => id},
        "root_pane" => %{"pane_id" => "#{id}:p1"}
      }
    })
  end

  defp workspace_id(path),
    do: "test-worktree:" <> Base.url_encode64(path, padding: false)

  defp worktree_path(workspace, "test-worktree:" <> encoded) do
    with {:ok, path} <- Base.url_decode64(encoded, padding: false),
         true <- String.starts_with?(path, workspace.worktree_root <> "/") do
      {:ok, path}
    else
      _invalid -> {:error, :unsafe_test_workspace_identity}
    end
  end

  defp worktree_path(_workspace, _workspace_id),
    do: {:error, :unsafe_test_workspace_identity}

  @doc false
  def command_option!(args, name) do
    case Enum.split_while(args, &(&1 != name)) do
      {_before, [^name, value | _after]} -> value
      _missing -> raise ArgumentError, "missing #{name} in test Herdr command"
    end
  end

  @doc false
  def validate_open_args(args) do
    has_path = "--path" in args
    has_branch = "--branch" in args

    if has_path != has_branch,
      do: :ok,
      else: {:error, :invalid_test_herdr_open_selector}
  end

  defp reconcile_entry(entries, workspace, worktree) do
    matches = Enum.filter(entries, &(&1.path == worktree.path))

    case matches do
      [] ->
        {:ok, :absent}

      [%{branch: branch, head_sha: head_sha} = entry]
      when branch == worktree.branch and head_sha == worktree.head_sha ->
        with false <- entry[:prunable] == true,
             :ok <- validate_registered_checkout(workspace, worktree.path) do
          {:ok, {:adopted, worktree}}
        else
          true -> {:error, :stale_worktree_registry_entry}
          {:error, _reason} = error -> error
        end

      [entry] ->
        {:error,
         {:worktree_identity_mismatch,
          %{expected_branch: worktree.branch, expected_head: worktree.head_sha, actual: entry}}}

      _multiple ->
        {:error, :ambiguous_worktree_identity}
    end
  end

  defp parse_worktrees(output) do
    entries =
      output
      |> String.split("\n\n", trim: true)
      |> Enum.map(fn block ->
        fields =
          block
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, fields ->
            case String.split(line, " ", parts: 2) do
              ["worktree", path] -> Map.put(fields, :path, Path.expand(path))
              ["HEAD", head_sha] -> Map.put(fields, :head_sha, head_sha)
              ["branch", "refs/heads/" <> branch] -> Map.put(fields, :branch, branch)
              ["prunable" | _reason] -> Map.put(fields, :prunable, true)
              _other -> fields
            end
          end)

        fields
      end)

    {:ok, entries}
  end

  defp validate_identity(workspace, worktree) do
    expected = worktree(workspace, worktree.key)

    if worktree == expected,
      do: :ok,
      else: {:error, :unsafe_worktree_identity}
  end

  defp validate_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, %{type: :symlink}} -> {:error, :unsafe_worktree_symlink}
      {:ok, _stat} -> {:error, :unsafe_worktree_type}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:worktree_io, reason}}
    end
  end

  defp validate_registered_checkout(workspace, path) do
    git_file = Path.join(path, ".git")
    expected_prefix = "gitdir: #{Path.join(workspace.repository, ".git/worktrees")}/"

    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, %{type: :regular}} <- File.lstat(git_file),
         {:ok, contents} <- File.read(git_file),
         true <- String.starts_with?(String.trim(contents), expected_prefix) do
      :ok
    else
      {:error, :enoent} -> {:error, :stale_worktree_registry_entry}
      _mismatch -> {:error, :unsafe_worktree_administrative_link}
    end
  end

  defp run!(command, args, options \\ []) do
    case SystemCommandRunner.run(command, args, Keyword.put(options, :stderr_to_stdout, true)) do
      {:ok, output} -> output
      {:error, reason} -> raise "test Git setup failed: #{inspect(reason)}"
    end
  end

  defp git!, do: System.find_executable("git") || raise("git is required for this test")
end
