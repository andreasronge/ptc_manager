defmodule PtcManager.DeliveryEvidence.Selection do
  @moduledoc false
  alias PtcManager.DeliveryEvidence.Fields, as: F

  @optional_text ~w(author_login)
  @optional_counts ~w(additions deletions changed_files commits)
  @body_keys ~w(summary validation retrospective preamble)

  def validate!(repository, window, selection, observed_at) do
    F.require!(is_map(window), :invalid_window)
    started = F.datetime(window[:started_at])
    ended = F.datetime(window[:ended_at])
    observed = F.datetime(observed_at)
    F.require!(started != nil and ended != nil and observed != nil, :invalid_window)
    seconds = DateTime.diff(ended, started)
    F.require!(seconds > 0 and seconds <= 31 * 86_400, :invalid_window)
    F.require!(DateTime.compare(ended, observed) != :gt, :invalid_observation_time)

    F.require!(
      is_map(selection) and byte_size(Jason.encode!(selection)) <= 120_000,
      :selection_limit
    )

    F.require!(F.sha(selection["source_head_sha"]) != nil, :invalid_source_head)
    pulls = F.list!(selection["pull_requests"], 50)
    commits = F.list!(selection["commits"], 100)
    F.require!(Enum.all?(pulls ++ commits, &is_map/1), :invalid_selection)
    numbers = Enum.map(pulls, & &1["number"])
    F.require!(length(Enum.uniq(numbers)) == length(numbers), :duplicate_pull_request)
    F.require!(Enum.sort(numbers) == selection["pull_request_numbers"], :selection_mismatch)
    F.require!(length(commits) == selection["change_count"], :selection_mismatch)

    pulls =
      Enum.map(pulls, &pull!(&1, repository, started, ended)) |> Enum.sort_by(& &1["number"])

    {merged, direct} = Enum.split_with(commits, &(&1["included_by"] == "pull_request_merged_at"))

    merged_ids =
      Enum.map(merged, &{&1["pull_request_number"], &1["sha"], &1["included_at"]}) |> Enum.sort()

    expected =
      Enum.map(pulls, &{&1["number"], &1["merge_commit_sha"], &1["merged_at"]}) |> Enum.sort()

    # Compare parsed instants: equivalent ISO8601 representations are acceptable.
    normalize = fn rows -> Enum.map(rows, fn {n, s, t} -> {n, s, F.datetime(t)} end) end
    F.require!(normalize.(merged_ids) == normalize.(expected), :selection_mismatch)
    F.list!(direct, 50)

    direct =
      Enum.map(direct, &direct!(&1, repository, started, ended))
      |> Enum.sort_by(&{&1["included_at"], &1["sha"]})

    F.require!(Enum.uniq_by(direct, & &1["sha"]) == direct, :duplicate_commit)

    %{
      "window" => %{"started_at" => F.timestamp(started), "ended_at" => F.timestamp(ended)},
      "observed_at" => F.timestamp(observed),
      "source_head_sha" => selection["source_head_sha"],
      "default_branch" => repository.default_branch,
      "pull_requests" => pulls,
      "direct_commits" => direct,
      "change_count" => length(commits)
    }
  end

  defp pull!(pull, repository, started, ended) do
    number = pull["number"]
    F.require!(is_integer(number) and number > 0, :invalid_pull_request)
    F.require!(pull["base_ref"] == repository.default_branch, :wrong_base)

    F.require!(
      repository_url?(pull["html_url"], repository, "pull", to_string(number)),
      :wrong_repository
    )

    F.require!(F.sha(pull["merge_commit_sha"]) != nil, :invalid_merge_head)
    in_window!(pull["merged_at"], started, ended)
    body = pull["body"]

    F.require!(
      is_nil(body) or
        (is_map(body) and
           Enum.all?(body, fn {key, value} ->
             key in @body_keys and is_binary(value) and String.valid?(value)
           end)),
      :invalid_body
    )

    %{
      "number" => number,
      "url" => pull["html_url"],
      "title" => F.text(pull["title"], 1_200),
      "base_ref" => pull["base_ref"],
      "head_sha" => F.sha(pull["head_sha"]),
      "merge_commit_sha" => pull["merge_commit_sha"],
      "merged_at" => F.timestamp(pull["merged_at"]),
      "body" => if(body, do: Map.new(body, fn {key, value} -> {key, F.text(value, 1_500)} end)),
      "body_coverage" =>
        F.enum(
          pull["body_coverage"],
          ~w(complete priority shortened shortened_priority primary dropped none_written)
        ),
      "labels" => labels(pull["labels"])
    }
    |> Map.merge(Map.new(@optional_text, &{&1, F.text(pull[&1], 240)}))
    |> Map.merge(Map.new(@optional_counts, &{&1, F.integer(pull[&1])}))
  end

  defp labels(nil), do: nil

  defp labels(labels) do
    F.list!(labels, 50)
    F.require!(Enum.all?(labels, &(is_binary(&1) and String.valid?(&1))), :invalid_labels)

    labels
    |> Enum.map(&F.text(&1, 128))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp direct!(commit, repository, started, ended) do
    F.require!(
      commit["included_by"] == "committer_date_without_merged_pull_request",
      :invalid_direct_commit
    )

    F.require!(F.sha(commit["sha"]) != nil, :invalid_direct_commit)

    F.require!(
      repository_url?(commit["html_url"], repository, "commit", commit["sha"]),
      :wrong_repository
    )

    in_window!(commit["included_at"], started, ended)

    %{
      "sha" => commit["sha"],
      "url" => commit["html_url"],
      "message" => F.text(commit["message"], 1_000),
      "author" => F.text(commit["author"], 240),
      "included_at" => F.timestamp(commit["included_at"]),
      "selection_caveat" => "committer_time_is_not_push_arrival_time"
    }
  end

  defp in_window!(value, started, ended) do
    datetime = F.datetime(value)
    F.require!(datetime != nil, :invalid_change_time)

    F.require!(
      DateTime.compare(datetime, started) != :lt and DateTime.compare(datetime, ended) == :lt,
      :change_outside_window
    )
  end

  defp repository_url?(url, repository, kind, id) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "https",
        host: host,
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil,
        path: path
      }
      when is_binary(host) and is_binary(path) ->
        case String.split(path, "/") do
          ["", owner, name, ^kind, ^id] ->
            String.downcase(host) == "github.com" and
              String.downcase(owner) == String.downcase(repository.github_owner) and
              String.downcase(name) == String.downcase(repository.github_name)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp repository_url?(_, _, _, _), do: false
end
