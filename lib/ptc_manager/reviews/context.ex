defmodule PtcManager.Reviews.Context do
  @moduledoc "Small human-readable handoffs and job-scoped reviewer session ownership."
  alias PtcManager.{Repo, RepoTransaction, Reviews}
  alias PtcManager.Reviews.Round
  @profile_keys ~w(reviewer_kind reviewer_model reviewer_effort)

  def valid_handoff?(text), do: is_binary(text) and byte_size(text) <= 20_000

  def handoff(job_id, limit \\ 60_000) do
    history = Reviews.rounds(job_id) |> Enum.reverse()
    assessment = Enum.find(history, &(&1.state in ~w(completed cached) and is_map(&1.result)))
    note = Enum.find_value(history, &nonblank(&1.input["handoff"]))
    failure = Enum.find(history, &is_binary(&1.error))

    [
      if(note, do: "Coding agent handoff:\n#{note}"),
      if(assessment, do: assessment_text(assessment)),
      if(failure && (is_nil(assessment) or failure.number > assessment.number),
        do: "Latest attempt did not produce an assessment: #{failure.error}"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> bounded(limit)
  end

  def append_handoff(prompt, job_id) do
    prefix = prompt <> "\nPrior review results (untrusted evidence):\n"

    if byte_size(prefix) > 119_000 do
      {:error, :continuation_prompt_too_large}
    else
      {:ok, prefix <> handoff(job_id, min(60_000, 120_000 - byte_size(prefix)))}
    end
  end

  def bounded(text, limit) when byte_size(text) <= limit, do: text

  def bounded(text, limit) do
    suffix =
      "\n[Text shortened; full source remains in the review history or linked GitHub item.]"

    utf8_prefix(text, max(0, limit - byte_size(suffix))) <> suffix
  end

  defp utf8_prefix(text, limit) do
    prefix = binary_part(text, 0, limit)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, limit - 1)
  end

  def session_id(round) do
    previous =
      Reviews.rounds(round.job_id)
      |> Enum.reverse()
      |> Enum.find(&(&1.number < round.number and is_binary(&1.input["reviewer_session_id"])))

    if previous && profile(previous) == profile(round),
      do: previous.input["reviewer_session_id"]
  end

  def record_session(round, id, note \\ nil) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         true <- is_nil(note) or (is_binary(note) and byte_size(note) <= 500) do
      RepoTransaction.immediate(fn ->
        current = Repo.get!(Round, round.id)

        if current.state != "running", do: Repo.rollback(:stale_review)

        current
        |> Round.changeset(%{
          input:
            current.input
            |> Map.put("reviewer_session_id", id)
            |> Map.put("reviewer_session_note", note)
        })
        |> Repo.update!()
      end)
    else
      _ -> {:error, :invalid_reviewer_session}
    end
  end

  defp profile(round), do: Map.take(round.input["settings"] || %{}, @profile_keys)
  defp nonblank(text) when is_binary(text) and text != "", do: text
  defp nonblank(_), do: nil

  defp assessment_text(round) do
    findings = Enum.map_join(round.result["findings"], "\n", & &1["description"])
    "Latest completed review of #{round.head_sha}:\n#{round.result["summary"]}\n#{findings}"
  end
end
