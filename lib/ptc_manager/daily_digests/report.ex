defmodule PtcManager.DailyDigests.Report do
  @moduledoc "Validates model-authored prose; renders delivery facts from captured evidence only."
  alias PtcManager.DailyDigests.Input

  @keys ~w(status title summary what_shipped what_we_learned window_started_at window_ended_at source_head_sha change_count pull_request_numbers evidence_sha256)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
  @hash ~r/\A[0-9a-f]{64}\z/

  def validate(result) when is_map(result) do
    valid =
      keys?(result, @keys) and
        text?(result["title"], 180) and text?(result["summary"], 4_000) and
        iso?(result["window_started_at"]) and iso?(result["window_ended_at"]) and
        matches?(result["source_head_sha"], @sha) and matches?(result["evidence_sha256"], @hash) and
        is_integer(result["change_count"]) and result["change_count"] in 0..100 and
        list?(result["pull_request_numbers"], 50, &(is_integer(&1) and &1 > 0)) and
        result["pull_request_numbers"] == Enum.sort(Enum.uniq(result["pull_request_numbers"])) and
        list?(result["what_shipped"], 100, &shipped?/1) and
        list?(result["what_we_learned"], 20, &lesson?/1) and
        status?(result) and byte_size(Jason.encode!(result)) <= 60_000

    if valid, do: :ok, else: {:error, :invalid_daily_digest_output}
  end

  def validate(_), do: {:error, :invalid_daily_digest_output}

  def render(action, result) do
    with :ok <- validate(result),
         {:ok, evidence} <- Input.read(action),
         :ok <- provenance(action.target_snapshot, result),
         sources = sources(evidence),
         true <- selectors?(result, sources) do
      markdown =
        shipped(result["what_shipped"], sources) <>
          lessons(result["what_we_learned"], sources) <> health(evidence)

      if byte_size(markdown) <= 40_000,
        do: {:ok, markdown},
        else: {:error, :daily_digest_report_too_large}
    else
      false -> {:error, :daily_digest_selector_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provenance(snapshot, result) do
    pairs = [
      {"window_started_at", "window_started_at"},
      {"window_ended_at", "window_ended_at"},
      {"source_head_sha", "trusted_source_head_sha"},
      {"change_count", "trusted_change_count"},
      {"pull_request_numbers", "trusted_pull_request_numbers"},
      {"evidence_sha256", "trusted_evidence_sha256"}
    ]

    if Enum.all?(pairs, fn {output, trusted} -> result[output] == snapshot[trusted] end),
      do: :ok,
      else: {:error, :daily_digest_provenance_mismatch}
  end

  defp sources(evidence) do
    pulls =
      Enum.map(evidence["pull_requests"]["data"], fn pull ->
        {"pr:#{pull["number"]}",
         %{label: "PR ##{pull["number"]}", url: pull["github"]["data"]["url"], pull: pull}}
      end)

    commits =
      Enum.map(evidence["direct_commits"]["data"], fn %{"data" => commit} ->
        {"commit:#{commit["sha"]}",
         %{label: "Commit #{String.slice(commit["sha"], 0, 8)}", url: commit["url"], pull: nil}}
      end)

    Map.new(pulls ++ commits)
  end

  defp selectors?(result, sources) do
    shipped = Enum.map(result["what_shipped"], & &1["source_id"])
    selected = shipped ++ Enum.flat_map(result["what_we_learned"], & &1["source_ids"])

    length(Enum.uniq(shipped)) == length(shipped) and
      Enum.all?(selected, &Map.has_key?(sources, &1))
  end

  defp shipped([], _sources), do: "## What shipped\n\nNo changes in the selected window.\n"

  defp shipped(items, sources) do
    "## What shipped\n\n" <>
      Enum.map_join(items, "\n\n", fn item ->
        source = sources[item["source_id"]]

        "- #{link(source)} — #{prose(item["summary"])} #{prose(item["why_it_matters"])}\n  Validation: #{validation(source.pull)}"
      end) <> "\n"
  end

  defp lessons([], _sources), do: ""

  defp lessons(items, sources) do
    "\n## What we learned\n\n" <>
      Enum.map_join(items, "\n", fn item ->
        refs = Enum.map_join(item["source_ids"], ", ", &link(sources[&1]))
        "- #{prose(item["lesson"])} (#{refs})"
      end) <> "\n"
  end

  defp health(evidence) do
    pulls = evidence["pull_requests"]["data"]

    rows =
      Enum.map_join(pulls, "\n", fn pull ->
        data = pull["health"]["data"]

        "- PR ##{pull["number"]}: review rounds #{metric(data, "review_round_count")}; " <>
          "time to ready #{metric(data, "time_to_ready_ms", " ms")}; " <>
          "failed managed operations #{metric(data, "failed_managed_operation_count")}."
      end)

    "\n## Delivery health\n\n" <>
      if(pulls == [], do: "No pull requests in this window.", else: rows) <> "\n"
  end

  defp metric(data, key, suffix \\ "") do
    if data["metric_coverage"][key] == "complete" and is_integer(data[key]),
      do: "#{data[key]}#{suffix}",
      else: "unknown"
  end

  defp validation(nil), do: "unavailable for this direct commit."

  defp validation(pull) do
    producer = Enum.find(pull["attempts"]["data"], &(&1["inclusion_reason"] == "producing_job"))
    head = pull["github"]["data"]["head_sha"]
    record = producer && producer["validation"]

    if head && record && record["binding"] == "exact" && record["head_sha"] == head &&
         record["data"]["state"] in ~w(passed failed),
       do:
         "recorded #{record["data"]["state"]} for captured PR head #{String.slice(head, 0, 8)}.",
       else:
         "unavailable for the captured PR head; historical or missing validation is not proof."
  end

  defp link(source), do: "[#{source.label}](#{source.url})"

  defp prose(text),
    do:
      text
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/[\\`*_\[\]<>#|]/u, fn char -> "\\" <> char end)

  defp shipped?(item),
    do:
      keys?(item, ~w(source_id summary why_it_matters)) and
        text?(item["source_id"], 80) and text?(item["summary"], 800) and
        text?(item["why_it_matters"], 800)

  defp lesson?(item),
    do:
      keys?(item, ~w(source_ids lesson)) and text?(item["lesson"], 1_200) and
        list?(item["source_ids"], 10, &text?(&1, 80)) and item["source_ids"] != [] and
        Enum.uniq(item["source_ids"]) == item["source_ids"]

  defp status?(%{"status" => "published", "change_count" => count, "what_shipped" => [_ | _]}),
    do: count > 0

  defp status?(%{
         "status" => "no-changes",
         "change_count" => 0,
         "pull_request_numbers" => [],
         "what_shipped" => [],
         "what_we_learned" => []
       }),
       do: true

  defp status?(_), do: false
  defp keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)

  defp text?(value, max),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        byte_size(value) <= max

  defp list?(value, max, valid),
    do: is_list(value) and length(value) <= max and Enum.all?(value, valid)

  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp iso?(value),
    do: is_binary(value) and match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
end
