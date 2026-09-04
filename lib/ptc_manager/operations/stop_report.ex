defmodule PtcManager.Operations.StopReport do
  @moduledoc """
  The one way an agent can say "I could not start" or "I could not continue".

  Nothing is watching a managed pane, so an agent that asks a question there is
  asking nobody: PtcManager never parses terminal output, by design. An agent
  that cannot reach done therefore writes this file and exits, and deterministic
  code turns it into a card the maintainer can act on.

  The report is data. It records a reason and never causes a state transition by
  itself, and `reason_code` decides only which recovery PtcManager offers first.

  Both sides derive the path from the job, so nothing has to be threaded through
  dispatch: the adapter writes the schema beside it before the agent starts, and
  reconciliation looks for it.

  The path carries a random per-attempt token. That is defence in depth, not a
  capability: every managed agent runs as the same worker identity and can list
  the shared results directory, so one agent can still find and forge another
  job's report. Technical separation between agents is deferred deployment-wide,
  and per-agent OS identities are the only thing that would close it.

  What is enforced is the blast radius. A report cannot approve, publish, merge,
  or write to GitHub. Recording one takes the same fencing and result-attempt
  tokens as any other result write, so it can only end the attempt a verifier
  currently holds, and the worktree is preserved either way. The read itself is
  bounded and deadlined, so what the file contains cannot exhaust or stall the
  coordinator.
  """

  alias PtcManager.Operations.Job

  @reason_codes ~w(missing_prerequisite environment_broken ambiguous_requirement unsafe_to_proceed)
  @progress_values ~w(none partial)
  @max_summary 300
  @max_detail 2_000
  @max_prerequisite 120
  @max_file_bytes 32_768
  @read_timeout_ms 2_000

  @doc "Every reason an agent may give for stopping."
  def reason_codes, do: @reason_codes

  @doc "A fresh capability token naming one attempt's report file."
  def new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  @doc """
  Where this job's agent writes its report, or nil before a token was issued.

  The token keeps two attempts from colliding and makes the name impractical to
  guess. It is not a secret: see the note on shared worker identity above.
  """
  def path_for(%Job{stop_report_token: token} = job) when is_binary(token) and token != "" do
    if safe_token?(token),
      do: Path.join(directory(), "ptc-stop-#{job.id}-#{job.fencing_token}-#{token}.json"),
      else: nil
  end

  def path_for(%Job{}), do: nil

  @doc "Where the contract itself is placed, so the agent can read it."
  def schema_path_for(%Job{} = job) do
    case path_for(job) do
      nil -> nil
      path -> Path.rootname(path) <> ".schema.json"
    end
  end

  @doc """
  Places the schema next to the report path so the agent has the contract.

  A failure here is never fatal: the agent simply has no structured way to stop,
  which is the behaviour that existed before this contract.
  """
  def prepare(%Job{} = job) do
    with path when is_binary(path) <- path_for(job),
         schema_path when is_binary(schema_path) <- schema_path_for(job),
         :ok <- File.mkdir_p(directory()),
         :ok <- File.cp(schema_source(), schema_path),
         :ok <- File.chmod(schema_path, 0o440) do
      {:ok, path, schema_path}
    else
      nil -> {:error, :stop_report_token_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads and validates this job's report.

  Returns `{:ok, report}` with string keys, `:none` when the agent wrote
  nothing, or `{:error, reason}` when it wrote something that is not a report.
  A malformed file is deliberately not a stop: PtcManager cannot tell what the
  agent meant, so the ordinary "no usable result" path stays in charge.
  """
  def read(%Job{} = job) do
    case path_for(job) do
      nil -> :none
      path -> read_bounded(path)
    end
  end

  # A model wrote this path's contents. The stat is only a cheap early reject:
  # the path can be swapped between checking it and opening it, so the read
  # itself has to be safe on its own. It is bounded, so a large or endless file
  # cannot exhaust this process, and it runs under a deadline, so a FIFO that
  # never yields cannot stall the single reconciliation task.
  defp read_bounded(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        bounded_contents(path)

      {:ok, %File.Stat{}} ->
        {:error, :invalid_stop_report}

      {:error, :enoent} ->
        :none

      {:error, _reason} ->
        {:error, :invalid_stop_report}
    end
  end

  defp bounded_contents(path) do
    task = Task.async(fn -> read_head(path) end)

    case Task.yield(task, @read_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, body}} -> decode(body)
      {:ok, :none} -> :none
      {:ok, {:error, _reason}} -> {:error, :invalid_stop_report}
      _timeout_or_crash -> {:error, :invalid_stop_report}
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

  @doc "Removes the report and its schema once the outcome is durable."
  def discard(%Job{} = job) do
    for path <- [path_for(job), schema_path_for(job)], is_binary(path), do: File.rm(path)
    :ok
  end

  @doc """
  The recoveries a maintainer may take for one report.

  An agent that judged something unsafe offers none: restarting it or asking an
  issue-writing agent to reword it are both ways of proceeding anyway, and the
  point of that reason code is that a person reads the evidence first.
  """
  def recoveries(%{"reason_code" => "unsafe_to_proceed"}), do: []
  def recoveries(%{"reason_code" => code}) when code in @reason_codes, do: [:retry, :ask_on_issue]
  def recoveries(_report), do: []

  @doc "True when this recovery may be offered for this report."
  def allows?(report, action), do: action in recoveries(report)

  @doc """
  The recovery a maintainer most likely wants, given why the agent stopped.

  Retrying an ambiguity asks the same question again, and an agent that called
  something unsafe should never be one click from being told to do it anyway.
  """
  def primary_action(%{"reason_code" => code}), do: primary_action(code)
  def primary_action(code) when code in ~w(missing_prerequisite environment_broken), do: :retry
  def primary_action("ambiguous_requirement"), do: :ask_on_issue
  def primary_action(_code), do: :none

  @doc "True when the agent committed nothing, so a fresh attempt loses nothing."
  def nothing_committed?(%{"progress" => "none"}), do: true
  def nothing_committed?(_report), do: false

  @doc "The maintainer-facing sentence for a card."
  def summary(%{"summary" => summary}) when is_binary(summary), do: summary
  def summary(_report), do: "The agent stopped without saying why."

  @doc "The exact missing thing, when the agent named one."
  def prerequisite(%{"prerequisite" => value}) when is_binary(value) and value != "", do: value
  def prerequisite(_report), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> validate(decoded)
      {:ok, _other} -> {:error, :invalid_stop_report}
      {:error, _reason} -> {:error, :invalid_stop_report}
    end
  end

  # Validated here rather than by a schema library, matching how every other
  # agent result in this repository is checked.
  defp validate(
         %{
           "reason_code" => reason_code,
           "summary" => summary,
           "detail" => detail,
           "progress" => progress
         } = report
       )
       when reason_code in @reason_codes and progress in @progress_values and
              is_binary(summary) and is_binary(detail) do
    prerequisite = Map.get(report, "prerequisite")

    if summary != "" and String.length(summary) <= @max_summary and detail != "" and
         String.length(detail) <= @max_detail and valid_prerequisite?(prerequisite) do
      {:ok,
       %{
         "reason_code" => reason_code,
         "summary" => summary,
         "detail" => detail,
         "progress" => progress
       }
       |> maybe_put_prerequisite(prerequisite)}
    else
      {:error, :invalid_stop_report}
    end
  end

  defp validate(_report), do: {:error, :invalid_stop_report}

  defp valid_prerequisite?(nil), do: true

  defp valid_prerequisite?(value) when is_binary(value),
    do: String.length(value) <= @max_prerequisite

  defp valid_prerequisite?(_value), do: false

  # The token names a file, so it must never be able to leave the directory.
  defp safe_token?(token), do: Regex.match?(~r/\A[A-Za-z0-9_-]{16,64}\z/, token)

  defp maybe_put_prerequisite(report, nil), do: report
  defp maybe_put_prerequisite(report, ""), do: report
  defp maybe_put_prerequisite(report, value), do: Map.put(report, "prerequisite", value)

  defp directory,
    do: Application.get_env(:ptc_manager, :agent_action_output_dir) || System.tmp_dir!()

  defp schema_source,
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_stop_report.schema.json")
end
