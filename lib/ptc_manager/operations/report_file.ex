defmodule PtcManager.Operations.ReportFile do
  @moduledoc """
  Reads a file a model wrote, safely.

  Every agent report shares the same hazard: the contents are model output, the
  path can be swapped between checking it and opening it, and the single
  reconciliation task must not be stalled or exhausted by either. The read is
  therefore bounded and runs under a deadline, and a stat is only a cheap early
  reject rather than a guarantee.

  Callers supply their own error reason so a malformed file is reported in the
  vocabulary of the contract that was being read.
  """

  alias PtcManager.Operations.Job

  @max_file_bytes 32_768
  @read_timeout_ms 2_000

  @doc """
  Returns `{:ok, decoded_map}`, `:none` when nothing was written, or
  `{:error, reason}` for anything that is not a JSON object within bounds.
  """
  def read_json(path, reason) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        path |> bounded_contents() |> decode(reason)

      {:ok, %File.Stat{}} ->
        {:error, reason}

      {:error, :enoent} ->
        :none

      {:error, _reason} ->
        {:error, reason}
    end
  end

  @doc """
  True when `token` can only ever name a file inside its own directory.
  """
  def safe_token?(token) when is_binary(token),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{16,64}\z/, token)

  def safe_token?(_token), do: false

  @doc "A fresh random identifier naming one attempt's report file."
  def new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc """
  Where a job's agent writes one report, or nil when no token was issued.

  A nil path means no contract was ever handed over, which is not the same
  condition as an agent that was given one and wrote nothing. Callers must not
  treat the two alike.
  """
  def path_for(%Job{stop_report_token: token} = job, prefix)
      when is_binary(token) and token != "" do
    if safe_token?(token),
      do: Path.join(directory(), "#{prefix}-#{job.id}-#{job.fencing_token}-#{token}.json"),
      else: nil
  end

  def path_for(%Job{}, _prefix), do: nil

  @doc "Where the contract itself is placed, so the agent can read it."
  def schema_path_for(%Job{} = job, prefix) do
    case path_for(job, prefix) do
      nil -> nil
      path -> Path.rootname(path) <> ".schema.json"
    end
  end

  @doc """
  Places the schema next to the report path so the agent has the contract.

  Both files are removed first. A dispatch that is retried reuses the same
  token, so a report left by the previous run would otherwise still be at this
  attempt's path and could be read as this attempt's outcome; the schema copy
  is 0440, so writing over it without removing it fails.
  """
  def prepare(%Job{} = job, prefix, schema_name, missing_token_error) do
    with path when is_binary(path) <- path_for(job, prefix),
         schema_path when is_binary(schema_path) <- schema_path_for(job, prefix),
         :ok <- File.mkdir_p(directory()),
         _stale_report <- File.rm(path),
         _stale_schema <- File.rm(schema_path),
         :ok <- File.cp(schema_source(schema_name), schema_path),
         :ok <- File.chmod(schema_path, 0o440) do
      {:ok, path, schema_path}
    else
      nil -> {:error, missing_token_error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes a job's report and its schema once the outcome is durable."
  def discard(%Job{} = job, prefix) do
    for path <- [path_for(job, prefix), schema_path_for(job, prefix)],
        is_binary(path),
        do: File.rm(path)

    :ok
  end

  defp directory,
    do: Application.get_env(:ptc_manager, :agent_action_output_dir) || System.tmp_dir!()

  defp schema_source(name),
    do: Application.app_dir(:ptc_manager, Path.join("priv/codex", name))

  # async_nolink, not async: the reader must survive a crash in the spawned
  # process as well as a stall. A linked task would take the caller down with
  # it, which is the single reconciliation task this module exists to protect.
  defp bounded_contents(path) do
    task = Task.Supervisor.async_nolink(PtcManager.TaskSupervisor, fn -> read_head(path) end)

    case Task.yield(task, @read_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_crash -> {:error, :unreadable}
    end
  end

  defp read_head(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, handle} ->
        try do
          # One byte more than a report may be, so an oversized file is detected
          # rather than truncated into something that happens to parse.
          case :file.read(handle, @max_file_bytes + 1) do
            {:ok, body} when byte_size(body) <= @max_file_bytes -> {:ok, body}
            {:ok, _too_large} -> {:error, :too_large}
            :eof -> {:error, :empty}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(handle)
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode({:ok, body}, reason) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, reason}
      {:error, _decode_error} -> {:error, reason}
    end
  end

  defp decode(:none, _reason), do: :none
  defp decode({:error, _cause}, reason), do: {:error, reason}
end
