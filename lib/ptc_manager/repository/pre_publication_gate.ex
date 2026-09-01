defmodule PtcManager.Repository.PrePublicationGate do
  @moduledoc "Runs a repository-owned publication gate without GitHub credentials."

  alias PtcManager.Operations.{Job, PrPublication, WorktreeAllocation}
  alias PtcManager.Repository.{Contract, GitProbe}

  @callback verify(struct()) ::
              {:ok, :already_passed | map()} | {:error, term()}

  def verify(publication), do: verify(publication, Runner)

  @doc false
  def verify(
        %PrPublication{
          head_sha: head_sha,
          job:
            %Job{
              pre_publication_status: "passed",
              pre_publication_verified_sha: head_sha,
              pre_publication_exit_status: 0
            } = job
        },
        _runner
      ) do
    if Contract.frozen_publication_digest_matches?(job),
      do: {:ok, :already_passed},
      else: {:error, :pre_publication_gate_config_changed}
  end

  def verify(
        %PrPublication{
          head_sha: head_sha,
          job:
            %Job{
              branch_name: branch_name,
              pre_publication_bootstrap_command: bootstrap_command,
              pre_publication_bootstrap_timeout_ms: bootstrap_timeout_ms,
              pre_publication_command: command,
              pre_publication_timeout_ms: timeout_ms,
              worktree_allocation: %WorktreeAllocation{path: path}
            } = job
        },
        runner
      )
      when is_binary(bootstrap_command) and bootstrap_command != "" and
             is_integer(bootstrap_timeout_ms) and bootstrap_timeout_ms > 0 and
             is_binary(command) and command != "" and is_integer(timeout_ms) and timeout_ms > 0 and
             is_binary(path) do
    with true <- Contract.frozen_publication_digest_matches?(job),
         :ok <- GitProbe.reclaimable(path, branch_name, head_sha),
         {:ok, execution} <-
           runner.run(
             path,
             head_sha,
             bootstrap_command,
             bootstrap_timeout_ms,
             command,
             timeout_ms
           ),
         :ok <- GitProbe.reclaimable(path, branch_name, head_sha) do
      {:ok,
       execution
       |> Map.put(:status, if(execution.exit_status == 0, do: "passed", else: "failed"))
       |> Map.put(:verified_sha, head_sha)
       |> Map.put(:config_digest, job.pre_publication_config_digest)}
    else
      false -> {:error, :pre_publication_gate_config_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(%PrPublication{}, _runner), do: {:error, :pre_publication_gate_not_configured}

  defmodule Runner do
    @moduledoc false

    @output_limit 65_536

    @wrapper """
    set -eu
    source_path=$1
    head_sha=$2
    bootstrap_command=$3
    bootstrap_timeout=$4
    gate_command=$5
    gate_timeout=$6
    timeout_binary=$7
    git_binary=$8
    base_home=$HOME
    run_root="$base_home/pre-publication-runs"
    mkdir -p "$run_root"
    chmod 700 "$run_root"
    snapshot=$(mktemp -d "$run_root/gate.XXXXXX")
    cleanup() {
      chmod -R u+w "$snapshot" 2>/dev/null || true
      rm -rf "$snapshot"
    }
    trap cleanup EXIT HUP INT TERM
    mkdir "$snapshot/home"
    chmod 700 "$snapshot/home"
    HOME="$snapshot/home"
    HEX_HOME="$HOME/.hex"
    REBAR_CACHE_DIR="$HOME/.cache/rebar3"
    export HOME
    export HEX_HOME
    export REBAR_CACHE_DIR
    reject_local_filters() {
      filter_file=$(mktemp "$snapshot/local-filters.XXXXXX") || return 1
      set +e
      "$git_binary" --no-replace-objects -C "$snapshot/repository" config --local --get-regexp '^filter\..*\.(clean|smudge|process|required)$' >"$filter_file"
      filter_status=$?
      set -e
      if test "$filter_status" -ne 0 && test "$filter_status" -ne 1; then
        printf '%s\n' 'Git local-filter inspection failed.' >&2
        rm -f "$filter_file"
        return 1
      fi
      if test -s "$filter_file"; then
        printf '%s\n' 'Repository-local Git filters, including Git LFS, are not supported by exact-SHA validation.' >&2
        rm -f "$filter_file"
        return 1
      fi
      rm -f "$filter_file"
    }
    verify_tracked_contents() {
      tree_file=$(mktemp "$snapshot/tracked-tree.XXXXXX") || return 1
      reference=$(mktemp -d "$snapshot/reference.XXXXXX") || return 1
      if ! "$git_binary" --no-replace-objects -c safe.directory='*' clone --quiet --no-local --no-checkout -- "$source_path" "$reference/repository"; then
        printf '%s\n' 'Reference checkout clone failed.' >&2
        return 1
      fi
      if ! "$git_binary" --no-replace-objects -C "$reference/repository" -c core.hooksPath=/dev/null checkout --quiet --detach "$head_sha"; then
        printf '%s\n' 'Reference checkout failed.' >&2
        return 1
      fi
      if ! "$git_binary" --no-replace-objects -C "$snapshot/repository" ls-tree -rz --full-tree -r "$head_sha" >"$tree_file"; then
        printf '%s\n' 'Tracked-tree inspection failed.' >&2
        return 1
      fi
      set +e
      python3 - "$snapshot/repository" "$reference/repository" "$tree_file" <<'PY'
    import os
    import stat
    import sys

    root, reference_root, tree_file = sys.argv[1:]

    def fail(message, path):
        print(f"{message}: {os.fsdecode(path)}", file=sys.stderr)
        raise SystemExit(1)

    def compare_files(left, right):
        with open(left, "rb") as left_handle, open(right, "rb") as right_handle:
            while True:
                left_chunk = left_handle.read(1024 * 1024)
                right_chunk = right_handle.read(1024 * 1024)
                if left_chunk != right_chunk:
                    return False
                if not left_chunk:
                    return True

    for record in open(tree_file, "rb").read().split(b"\\0"):
        if not record:
            continue

        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, kind, expected = metadata.split(b" ")
        except ValueError:
            fail("Invalid tracked-tree record", record)

        relative_path = os.fsdecode(raw_path)
        path = os.path.join(root, relative_path)
        reference_path = os.path.join(reference_root, relative_path)

        if kind == b"commit" and mode == b"160000":
            fail("Submodules are not supported by exact-SHA validation", raw_path)

        try:
            details = os.lstat(path)
            reference_details = os.lstat(reference_path)
        except OSError:
            fail("Tracked path is missing", raw_path)

        if kind == b"blob" and mode == b"120000":
            if not stat.S_ISLNK(details.st_mode) or not stat.S_ISLNK(reference_details.st_mode):
                fail("Tracked symlink changed type", raw_path)
            if os.fsencode(os.readlink(path)) != os.fsencode(os.readlink(reference_path)):
                fail("Tracked symlink differs from the exact checkout", raw_path)
        elif kind == b"blob" and mode in (b"100644", b"100755"):
            if not stat.S_ISREG(details.st_mode) or not stat.S_ISREG(reference_details.st_mode):
                fail("Tracked file changed type", raw_path)
            expected_executable = mode == b"100755"
            if bool(details.st_mode & 0o111) != expected_executable or bool(reference_details.st_mode & 0o111) != expected_executable:
                fail("Tracked file changed executable mode", raw_path)
            if details.st_size != reference_details.st_size or not compare_files(path, reference_path):
                fail("Tracked content differs from the exact checkout", raw_path)
        else:
            fail("Unsupported tracked entry", raw_path)
    PY
      status=$?
      set -e
      rm -f "$tree_file"
      chmod -R u+w "$reference" 2>/dev/null || true
      rm -rf "$reference"
      return "$status"
    }
    verify_clean_status() {
      status_file=$(mktemp "$snapshot/git-status.XXXXXX") || return 1
      if ! "$git_binary" --no-replace-objects -C "$snapshot/repository" -c core.fsmonitor=false status --porcelain=v1 --untracked-files=all >"$status_file"; then
        printf '%s\n' 'Git status inspection failed.' >&2
        rm -f "$status_file"
        return 1
      fi
      if test -s "$status_file"; then
        rm -f "$status_file"
        return 1
      fi
      rm -f "$status_file"
    }
    "$git_binary" --no-replace-objects -c safe.directory='*' clone --quiet --no-local --no-checkout -- "$source_path" "$snapshot/repository"
    "$git_binary" --no-replace-objects -C "$snapshot/repository" -c core.hooksPath=/dev/null checkout --quiet --detach "$head_sha"
    checked_out_sha=$("$git_binary" --no-replace-objects -C "$snapshot/repository" rev-parse --verify HEAD^{commit})
    if test "$checked_out_sha" != "$head_sha"; then
      printf '%s\n' 'Disposable checkout did not resolve to the verified SHA.'
      exit 120
    fi
    cd "$snapshot/repository"
    printf '%s\n' 'PtcManager bootstrap started.'
    "$timeout_binary" --signal=TERM --kill-after=5s "$bootstrap_timeout" /bin/sh -c "$bootstrap_command"
    checked_out_sha=$("$git_binary" --no-replace-objects -C "$snapshot/repository" rev-parse --verify HEAD^{commit})
    if test "$checked_out_sha" != "$head_sha"; then
      printf '%s\n' 'Bootstrap changed the disposable checkout HEAD.'
      exit 120
    fi
    if ! reject_local_filters; then
      printf '%s\n' 'Bootstrap configured an unsupported repository-local Git filter.'
      exit 121
    fi
    if ! verify_tracked_contents; then
      printf '%s\n' 'Bootstrap changed tracked contents in the exact-SHA checkout.'
      exit 121
    fi
    if ! verify_clean_status; then
      printf '%s\n' 'Bootstrap left the exact-SHA checkout dirty.'
      exit 121
    fi
    printf '%s\n' 'PtcManager pre-publication gate started.'
    set +e
    "$timeout_binary" --signal=TERM --kill-after=5s "$gate_timeout" /bin/sh -c "$gate_command"
    gate_status=$?
    set -e
    checked_out_sha=$("$git_binary" --no-replace-objects -C "$snapshot/repository" rev-parse --verify HEAD^{commit})
    if test "$checked_out_sha" != "$head_sha"; then
      printf '%s\n' 'Pre-publication gate changed the disposable checkout HEAD.'
      exit 120
    fi
    if ! reject_local_filters; then
      printf '%s\n' 'Pre-publication gate configured an unsupported repository-local Git filter.'
      exit 122
    fi
    if ! verify_tracked_contents; then
      printf '%s\n' 'Pre-publication gate changed tracked contents in the exact-SHA checkout.'
      exit 122
    fi
    if ! verify_clean_status; then
      printf '%s\n' 'Pre-publication gate left the exact-SHA checkout dirty.'
      exit 122
    fi
    exit "$gate_status"
    """

    def run(
          path,
          head_sha,
          bootstrap_command,
          bootstrap_timeout_ms,
          configured_command,
          timeout_ms
        )
        when is_binary(path) and is_binary(head_sha) and is_binary(bootstrap_command) and
               is_integer(bootstrap_timeout_ms) and is_binary(configured_command) and
               is_integer(timeout_ms) do
      with {:ok, command, args} <-
             command(
               path,
               head_sha,
               bootstrap_command,
               bootstrap_timeout_ms,
               configured_command,
               timeout_ms
             ) do
        started = System.monotonic_time(:millisecond)

        port =
          Port.open(
            {:spawn_executable, command},
            [:binary, :exit_status, :stderr_to_stdout, :hide, args: args, cd: path]
          )

        receive_result(
          port,
          "",
          false,
          started,
          started + bootstrap_timeout_ms + timeout_ms + 32_500
        )
      end
    rescue
      _error -> {:error, :pre_publication_gate_unavailable}
    end

    @doc false
    def command(
          source_path,
          head_sha,
          bootstrap_command,
          bootstrap_timeout_ms,
          configured_command,
          timeout_ms
        ) do
      timeout_binary = Application.get_env(:ptc_manager, :pre_publication_timeout_binary)

      if is_binary(timeout_binary) and timeout_binary != "" do
        home =
          Application.get_env(:ptc_manager, :pre_publication_home) ||
            Application.get_env(:ptc_manager, :git_verifier_home) || System.tmp_dir!()

        path =
          Application.get_env(
            :ptc_manager,
            :pre_publication_path,
            "/usr/local/bin:/usr/bin:/bin"
          )

        total_timeout_ms = bootstrap_timeout_ms + timeout_ms + 30_000

        git_binary =
          Application.get_env(:ptc_manager, :pre_publication_git_binary, "/usr/bin/git")

        timed = [
          timeout_binary,
          "--signal=TERM",
          "--kill-after=5s",
          timeout_duration(total_timeout_ms),
          "/bin/sh",
          "-c",
          @wrapper,
          "ptc-manager-pre-publication",
          source_path,
          head_sha,
          bootstrap_command,
          timeout_duration(bootstrap_timeout_ms),
          configured_command,
          timeout_duration(timeout_ms),
          timeout_binary,
          git_binary
        ]

        environment = [
          "-i",
          "HOME=#{home}",
          "MIX_HOME=#{Application.get_env(:ptc_manager, :pre_publication_mix_home, "/opt/ptc-manager-gate-mix")}",
          "PATH=#{path}",
          "LC_ALL=C",
          "MIX_ENV=test",
          "PTC_WORKSPACE_CACHE_DISABLED=true",
          "GIT_CONFIG_NOSYSTEM=1",
          "GIT_CONFIG_GLOBAL=/dev/null",
          "GIT_NO_REPLACE_OBJECTS=1",
          "GIT_TERMINAL_PROMPT=0"
        ]

        executable = ["/usr/bin/env" | environment ++ timed]

        case Application.get_env(:ptc_manager, :pre_publication_run_as_user) do
          user when is_binary(user) and user != "" ->
            {:ok, "/usr/bin/sudo", ["-n", "-H", "-u", user, "--" | executable]}

          _user ->
            [command | args] = executable
            {:ok, command, args}
        end
      else
        {:error, :pre_publication_timeout_not_configured}
      end
    end

    defp receive_result(port, output, truncated, started, deadline) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {^port, {:data, data}} ->
          {output, truncated} = append_bounded(output, data, truncated)
          receive_result(port, output, truncated, started, deadline)

        {^port, {:exit_status, exit_status}} ->
          {:ok,
           %{
             exit_status: exit_status,
             output: output,
             output_truncated: truncated,
             duration_ms: max(System.monotonic_time(:millisecond) - started, 0)
           }}
      after
        remaining ->
          close_port(port)
          {:error, :pre_publication_gate_timeout_uncertain}
      end
    end

    defp append_bounded(output, data, truncated) do
      combined = output <> String.replace_invalid(data)

      if byte_size(combined) <= @output_limit do
        {combined, truncated}
      else
        {binary_part(combined, byte_size(combined) - @output_limit, @output_limit), true}
      end
    end

    defp close_port(port) do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    defp timeout_duration(timeout_ms), do: "#{max(div(timeout_ms + 999, 1_000), 1)}s"
  end
end
