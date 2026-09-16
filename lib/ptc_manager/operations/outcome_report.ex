defmodule PtcManager.Operations.OutcomeReport do
  @moduledoc """
  The protocol v2 agent report: one file, one attempt, one outcome.

  The v1 contract could only say "I could not continue", so a successful
  implementation left no account of itself and the maintainer read a pull
  request body written from memory afterwards. This contract lets the same file
  say `completed` and carry the summary, validation, and retrospective material
  while the implementation context is still present.

  Nothing here is authority. A `completed` report is attached to a result only
  when PtcManager's own Git probe finds the same head, so a wrong or invented
  `head_sha` discards the report rather than moving the job. The accepted
  material stays `reported` evidence: it cannot change publication eligibility,
  and it never becomes observed merely because the SHA matched.

  One report path per attempt makes a simultaneous completed and stopped claim
  impossible, so there is no precedence rule to get wrong.
  """

  alias PtcManager.Operations.Job
  alias PtcManager.Operations.ReportFile
  alias PtcManager.Operations.StopReport

  @schema_version 2
  @max_section 2_000
  @sections ~w(summary validation retrospective)
  @completed_keys ~w(schema_version outcome head_sha summary validation retrospective)
  @sha ~r/\A[0-9a-f]{40}\z/

  @doc "The contract version this module reads."
  def schema_version, do: @schema_version

  @doc """
  Where this job's agent writes its outcome report, or nil before a token was
  issued.

  Distinct from the v1 stop-report name so a job that changes protocol can
  never have one attempt's file read as the other's contract.
  """
  def path_for(%Job{stop_report_token: token} = job) when is_binary(token) and token != "" do
    if ReportFile.safe_token?(token),
      do: Path.join(directory(), "ptc-outcome-#{job.id}-#{job.fencing_token}-#{token}.json"),
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
  """
  def prepare(%Job{} = job) do
    with path when is_binary(path) <- path_for(job),
         schema_path when is_binary(schema_path) <- schema_path_for(job),
         :ok <- File.mkdir_p(directory()),
         :ok <- File.cp(schema_source(), schema_path),
         :ok <- File.chmod(schema_path, 0o440) do
      {:ok, path, schema_path}
    else
      nil -> {:error, :outcome_report_token_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes the report and its schema once the outcome is durable."
  def discard(%Job{} = job) do
    for path <- [path_for(job), schema_path_for(job)], is_binary(path), do: File.rm(path)
    :ok
  end

  @doc """
  Reads and validates this job's outcome report.

  Returns `{:ok, report}` with string keys, `:none` when the agent wrote
  nothing, or `{:error, :invalid_outcome_report}` when it wrote something this
  contract does not describe. An invalid report can never be read as success.
  """
  def read(%Job{} = job) do
    case path_for(job) do
      nil -> :none
      path -> path |> ReportFile.read_json(:invalid_outcome_report) |> validate_decoded()
    end
  end

  @doc """
  True when `report` is a completed outcome naming exactly `head_sha`.

  The probed head is PtcManager's own observation. A report that names a
  different commit is describing work this result does not contain.
  """
  def completed_for?(%{"outcome" => "completed", "head_sha" => reported}, head_sha)
      when is_binary(head_sha),
      do: reported == head_sha

  def completed_for?(_report, _head_sha), do: false

  @doc """
  Builds the durable completion envelope stored beside a verified result.

  It records how the report was obtained as well as what it said, so a later
  reader can tell accepted material from a validation failure without inferring
  it from missing fields.
  """
  def envelope(outcome, head_sha, review_generation, now) do
    %{
      "schema_version" => @schema_version,
      "head_sha" => head_sha,
      "review_generation" => review_generation,
      "observed_at" => DateTime.to_iso8601(now)
    }
    |> Map.merge(envelope_outcome(outcome))
  end

  defp envelope_outcome({:ok, %{"outcome" => "completed"} = report}) do
    %{
      "outcome" => "completed",
      "report" => Map.take(report, @sections)
    }
  end

  defp envelope_outcome({:error, reason}) do
    %{"outcome" => "unusable", "failure" => to_string(reason)}
  end

  defp envelope_outcome(:none) do
    %{"outcome" => "unavailable"}
  end

  defp validate_decoded({:ok, decoded}), do: validate(decoded)
  defp validate_decoded(other), do: other

  # Validated here rather than by a schema library, matching how every other
  # agent result in this repository is checked.
  defp validate(%{"schema_version" => @schema_version, "outcome" => "completed"} = report) do
    head_sha = Map.get(report, "head_sha")

    with true <- known_keys_only?(report, @completed_keys),
         true <- is_binary(head_sha) and Regex.match?(@sha, head_sha),
         {:ok, sections} <- validate_sections(report) do
      {:ok, Map.merge(sections, %{"outcome" => "completed", "head_sha" => head_sha})}
    else
      _invalid -> {:error, :invalid_outcome_report}
    end
  end

  defp validate(%{"schema_version" => @schema_version, "outcome" => "stopped"} = report) do
    case report
         |> Map.delete("schema_version")
         |> Map.delete("outcome")
         |> StopReport.validate_payload() do
      {:ok, stopped} -> {:ok, Map.put(stopped, "outcome", "stopped")}
      {:error, _reason} -> {:error, :invalid_outcome_report}
    end
  end

  defp validate(_report), do: {:error, :invalid_outcome_report}

  # The contract the agent is handed sets additionalProperties to false, so a
  # report carrying anything else was not written against it.
  defp known_keys_only?(report, allowed),
    do: report |> Map.keys() |> Enum.all?(&(&1 in allowed))

  defp validate_sections(report) do
    Enum.reduce_while(@sections, {:ok, %{}}, fn key, {:ok, accepted} ->
      case Map.get(report, key) do
        value when is_binary(value) and value != "" ->
          if String.length(value) <= @max_section,
            do: {:cont, {:ok, Map.put(accepted, key, value)}},
            else: {:halt, {:error, :invalid_outcome_report}}

        _missing ->
          {:halt, {:error, :invalid_outcome_report}}
      end
    end)
  end

  defp directory,
    do: Application.get_env(:ptc_manager, :agent_action_output_dir) || System.tmp_dir!()

  defp schema_source,
    do: Application.app_dir(:ptc_manager, "priv/codex/agent_outcome_report.schema.json")
end
