defmodule PtcManager.Operations.StopReport do
  @moduledoc """
  A durable attention report for startup failures and agents that say "I could not start" or "I could not continue".

  The coordinator also records this data when dispatch safely fails before an agent starts.

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
  alias PtcManager.Operations.ReportFile

  @reason_codes ~w(missing_prerequisite environment_broken ambiguous_requirement unsafe_to_proceed)
  @progress_values ~w(none partial)
  @prefix "ptc-stop"
  @schema_name "agent_stop_report.schema.json"
  @max_summary 300
  @max_detail 2_000
  @max_prerequisite 120

  @doc "Every reason an agent may give for stopping."
  def reason_codes, do: @reason_codes

  @doc """
  A fresh random identifier naming one attempt's report file.

  Defence in depth, not a capability: it separates attempts and makes the name
  impractical to guess, but every agent shares one worker identity and can list
  the directory. See the note on the module.
  """
  defdelegate new_token, to: ReportFile

  @doc """
  Where this job's agent writes its report, or nil before a token was issued.

  The token keeps two attempts from colliding and makes the name impractical to
  guess. It is not a secret: see the note on shared worker identity above.
  """
  def path_for(%Job{} = job), do: ReportFile.path_for(job, @prefix)

  @doc "Where the contract itself is placed, so the agent can read it."
  def schema_path_for(%Job{} = job), do: ReportFile.schema_path_for(job, @prefix)

  @doc "Places the schema next to the report path so the agent has the contract."
  def prepare(%Job{} = job),
    do: ReportFile.prepare(job, @prefix, @schema_name, :stop_report_token_missing)

  @doc "Removes the report and its schema once the outcome is durable."
  def discard(%Job{} = job), do: ReportFile.discard(job, @prefix)

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
      path -> path |> ReportFile.read_json(:invalid_stop_report) |> validate_decoded()
    end
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

  defp validate_decoded({:ok, decoded}), do: validate_payload(decoded)
  defp validate_decoded(other), do: other

  @doc """
  Checks the stopped-outcome fields, which protocol v2 carries unchanged.

  Returns the accepted report with only the fields this contract defines, so a
  caller cannot be handed anything the agent added on its own.
  """
  # Validated here rather than by a schema library, matching how every other
  # agent result in this repository is checked.
  def validate_payload(
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

  def validate_payload(_report), do: {:error, :invalid_stop_report}

  defp valid_prerequisite?(nil), do: true

  defp valid_prerequisite?(value) when is_binary(value),
    do: String.length(value) <= @max_prerequisite

  defp valid_prerequisite?(_value), do: false

  defp maybe_put_prerequisite(report, nil), do: report
  defp maybe_put_prerequisite(report, ""), do: report
  defp maybe_put_prerequisite(report, value), do: Map.put(report, "prerequisite", value)
end
