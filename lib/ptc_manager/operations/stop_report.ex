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
  reconciliation looks for it when the agent produced no usable branch.
  """

  alias PtcManager.Operations.Job

  @reason_codes ~w(missing_prerequisite environment_broken ambiguous_requirement unsafe_to_proceed)
  @progress_values ~w(none partial)
  @max_summary 300
  @max_detail 2_000
  @max_prerequisite 120

  @doc "Every reason an agent may give for stopping."
  def reason_codes, do: @reason_codes

  @doc "Where this job's agent writes its report."
  def path_for(%Job{id: id, fencing_token: token}),
    do: Path.join(directory(), "ptc-stop-job-#{id}-#{token}.json")

  @doc "Where the contract itself is placed, so the agent can read it."
  def schema_path_for(%Job{} = job), do: Path.rootname(path_for(job)) <> ".schema.json"

  @doc """
  Places the schema next to the report path so the agent has the contract.

  A failure here is never fatal: the agent simply has no structured way to stop,
  which is the behaviour that existed before this contract.
  """
  def prepare(%Job{} = job) do
    schema_path = schema_path_for(job)

    with :ok <- File.mkdir_p(directory()),
         :ok <- File.cp(schema_source(), schema_path),
         :ok <- File.chmod(schema_path, 0o440) do
      {:ok, path_for(job), schema_path}
    else
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
    path = path_for(job)

    case File.read(path) do
      {:ok, body} -> decode(body)
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, {:stop_report_unreadable, reason}}
    end
  end

  @doc "Removes the report and its schema once the outcome is durable."
  def discard(%Job{} = job) do
    _ = File.rm(path_for(job))
    _ = File.rm(schema_path_for(job))
    :ok
  end

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

  defp maybe_put_prerequisite(report, nil), do: report
  defp maybe_put_prerequisite(report, ""), do: report
  defp maybe_put_prerequisite(report, value), do: Map.put(report, "prerequisite", value)

  defp directory,
    do: Application.get_env(:ptc_manager, :agent_action_output_dir) || System.tmp_dir!()

  defp schema_source,
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_stop_report.schema.json")
end
