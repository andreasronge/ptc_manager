defmodule PtcManager.DailyDigests.Evidence do
  @moduledoc "Builds a bounded daily-change manifest through the GET-only GitHub client."

  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.DailyDigests.PullRequestBody
  alias PtcManager.GitHub.Client
  alias PtcManager.Operations.Repository

  @per_page 100
  @max_pages 3
  @max_pull_requests 50
  @max_direct_commits 50
  @max_manifest_bytes 60_000
  @max_capture_attempts 3
  @max_issue_event_pages 3

  def fetch(%Repository{} = repository, %DailyDigest{} = digest) do
    client = Application.get_env(:ptc_manager, :daily_digest_github_client, Client)
    owner = URI.encode_www_form(repository.github_owner)
    name = URI.encode_www_form(repository.github_name)
    base = "https://api.github.com/repos/#{owner}/#{name}"
    capture(client, base, repository.default_branch, digest, @max_capture_attempts)
  end

  defp capture(_client, _base, _branch, _digest, 0),
    do: {:error, :daily_digest_source_head_unstable}

  defp capture(client, base, branch, digest, attempts_left) do
    head_url = "#{base}/commits/#{URI.encode_www_form(branch)}"

    with {:ok, %{"sha" => head_sha}} <- client.get_json(head_url),
         :ok <- validate_sha(head_sha),
         {:ok, pull_requests} <-
           fetch_stable_merged_pull_requests(
             client,
             base,
             branch,
             digest
           ),
         :ok <-
           validate_limit(
             pull_requests,
             @max_pull_requests,
             :daily_digest_pull_request_limit_reached
           ),
         {:ok, candidates} <- fetch_commits(client, base, head_sha, digest, 1, []),
         {:ok, direct_commits} <-
           find_direct_commits(client, base, branch, candidates),
         :ok <-
           validate_limit(direct_commits, @max_direct_commits, :daily_digest_commit_limit_reached),
         {:ok, %{"sha" => final_head_sha}} <- client.get_json(head_url),
         :ok <- validate_sha(final_head_sha) do
      if head_sha == final_head_sha do
        build_manifest(head_sha, pull_requests, direct_commits)
      else
        # Discard both selections: only a fresh full capture can bind them to
        # the next head. Do not mix new PRs with commits from the earlier head.
        capture(client, base, branch, digest, attempts_left - 1)
      end
    else
      {:ok, _unexpected} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_stable_merged_pull_requests(client, base, branch, digest) do
    with {:ok, first} <- fetch_merged_pull_requests(client, base, branch, digest, 1, []),
         {:ok, second} <- fetch_merged_pull_requests(client, base, branch, digest, 1, []) do
      if pull_request_scan_signature(first) == pull_request_scan_signature(second) do
        {:ok, second}
      else
        with {:ok, third} <- fetch_merged_pull_requests(client, base, branch, digest, 1, []) do
          if pull_request_scan_signature(second) == pull_request_scan_signature(third),
            do: {:ok, third},
            else: {:error, :daily_digest_pull_request_scan_unstable}
        end
      end
    end
  end

  defp fetch_merged_pull_requests(_client, _base, _branch, _digest, page, _pulls)
       when page > @max_pages,
       do: {:error, :daily_digest_pull_request_limit_reached}

  defp fetch_merged_pull_requests(client, base, branch, digest, page, pulls) do
    query =
      URI.encode_query(%{
        "state" => "closed",
        "base" => branch,
        "sort" => "updated",
        "direction" => "desc",
        "per_page" => @per_page,
        "page" => page
      })

    case client.get_json("#{base}/pulls?#{query}") do
      {:ok, items} when is_list(items) ->
        with {:ok, window_items} <- pull_requests_in_window(client, base, items, branch, digest) do
          # The closed-PR feed is ordered by mutable updated_at. A concurrent
          # update can move one PR across page boundaries, so collapse repeats
          # before enforcing limits or freezing provenance.
          next = unique_pull_requests(pulls ++ window_items)

          cond do
            length(next) > @max_pull_requests ->
              {:error, :daily_digest_pull_request_limit_reached}

            length(items) < @per_page or page_is_before_window?(items, digest) ->
              {:ok, next}

            true ->
              fetch_merged_pull_requests(client, base, branch, digest, page + 1, next)
          end
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_github_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_commits(_client, _base, _head_sha, _digest, page, _commits)
       when page > @max_pages,
       do: {:error, :daily_digest_commit_limit_reached}

  defp fetch_commits(client, base, head_sha, digest, page, commits) do
    query =
      URI.encode_query(%{
        # Pin pagination to the head captured above. A branch name here would let
        # a concurrent merge change the evidence without changing provenance.
        "sha" => head_sha,
        "since" => DateTime.to_iso8601(digest.window_started_at),
        "until" => DateTime.to_iso8601(digest.window_ended_at),
        "per_page" => @per_page,
        "page" => page
      })

    case client.get_json("#{base}/commits?#{query}") do
      {:ok, items} when is_list(items) ->
        with {:ok, window_items} <- commits_in_window(items, digest) do
          next = commits ++ window_items

          cond do
            length(next) > @max_direct_commits + @max_pull_requests ->
              {:error, :daily_digest_commit_limit_reached}

            length(items) < @per_page ->
              {:ok, next}

            true ->
              fetch_commits(client, base, head_sha, digest, page + 1, next)
          end
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_github_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_direct_commits(client, base, branch, commits) do
    commits
    |> Enum.reduce_while({:ok, []}, fn commit, {:ok, entries} ->
      with %{"sha" => sha} <- commit,
           true <- valid_sha?(sha),
           {:ok, pulls} <- client.get_json("#{base}/commits/#{sha}/pulls?per_page=100"),
           true <- is_list(pulls) do
        if Enum.any?(pulls, &merged_to_branch?(&1, branch)) do
          {:cont, {:ok, entries}}
        else
          {:cont, {:ok, [normalize_direct_commit(commit) | entries]}}
        end
      else
        false -> {:halt, {:error, :unexpected_github_response}}
        nil -> {:halt, {:error, :unexpected_github_response}}
        {:ok, _unexpected} -> {:halt, {:error, :unexpected_github_response}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_manifest(head_sha, pull_requests, direct_commits) do
    pull_requests = pull_requests |> unique_pull_requests() |> Enum.sort_by(& &1["number"])

    commits =
      Enum.map(pull_requests, fn pull ->
        %{
          "sha" => pull["merge_commit_sha"],
          "message" => pull["title"],
          "included_by" => "pull_request_merged_at",
          "included_at" => pull["merged_at"],
          "pull_request_number" => pull["number"],
          "html_url" => pull["html_url"]
        }
      end) ++ direct_commits

    manifest =
      %{
        "source_head_sha" => head_sha,
        "change_count" => length(commits),
        "pull_request_numbers" => Enum.map(pull_requests, & &1["number"]),
        "commits" => commits,
        "pull_requests" => pull_requests,
        "selection_rules" => %{
          "pull_requests" => "merged_at in the requested half-open window",
          "direct_commits" =>
            "committer date in the requested half-open window; GitHub does not expose direct-push arrival time"
        },
        "evidence_limits" => %{
          "pull_requests" => @max_pull_requests,
          "direct_commits" => @max_direct_commits,
          "serialized_bytes" => @max_manifest_bytes
        },
        "evidence_truncated" => false
      }
      |> Map.update!("pull_requests", fn pulls ->
        Enum.map(pulls, &Map.put(&1, "body_coverage", body_coverage(&1, :complete)))
      end)

    encoded = Jason.encode!(manifest)

    if byte_size(encoded) <= @max_manifest_bytes,
      do: {:ok, manifest},
      else: compact_manifest(manifest)
  end

  # Bodies are given up in order of how much a daily update would miss them:
  # general prose first, then the sections are shortened, and only then given up
  # entirely. The middle rung matters — without it a day of long descriptions
  # falls straight from whole bodies to none, which is less than the flat slice
  # this replaced would have kept.
  defp compact_manifest(manifest) do
    Enum.find_value(
      PullRequestBody.compaction_steps(),
      {:error, :daily_digest_evidence_too_large},
      fn {coverage, reduce_body} ->
        compact = compact_bodies(manifest, coverage, reduce_body)

        if compact |> Jason.encode!() |> byte_size() <= @max_manifest_bytes,
          do: {:ok, compact}
      end
    )
  end

  # Each pull request states what happened to its own body. A missing key would
  # otherwise read as "this change had no description" when it means "we had no
  # room for it", and the digest would write the change up as having nothing to
  # say.
  defp compact_bodies(manifest, coverage, reduce_body) do
    manifest
    |> Map.update!("pull_requests", fn pulls ->
      Enum.map(pulls, fn pull ->
        case pull |> Map.get("body") |> reduce_body.() do
          nil ->
            pull
            |> Map.delete("body")
            |> Map.put("body_coverage", body_coverage(pull, :dropped))

          body ->
            pull
            |> Map.put("body", body)
            |> Map.put("body_coverage", body_coverage(pull, coverage))
        end
      end)
    end)
    |> Map.put("evidence_truncated", true)
  end

  defp body_coverage(pull, _coverage) when not is_map_key(pull, "body"), do: "none_written"
  defp body_coverage(%{"body" => nil}, _coverage), do: "none_written"
  defp body_coverage(_pull, coverage), do: to_string(coverage)

  defp pull_requests_in_window(client, base, items, branch, digest) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, included} ->
      case normalize_pull_request(client, base, item, branch, digest) do
        {:ok, nil} -> {:cont, {:ok, included}}
        {:ok, pull} -> {:cont, {:ok, [pull | included]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, included} -> {:ok, Enum.reverse(included)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_pull_request(_client, _base, %{"merged_at" => nil}, _branch, _digest),
    do: {:ok, nil}

  # The window decides first. The scan reads pages ordered by a mutable
  # updated_at, so it sees pull requests merged long before this digest covers,
  # and holding one of those to the evidence this digest needs failed the whole
  # day over a row it was never going to report on.
  defp normalize_pull_request(
         client,
         base,
         %{"number" => number, "merged_at" => merged_at, "base" => %{"ref" => branch}} = pull,
         branch,
         digest
       )
       when is_integer(number) and number > 0 and is_binary(merged_at) do
    case DateTime.from_iso8601(merged_at) do
      {:ok, merged_at_dt, _offset} ->
        if in_window?(merged_at_dt, digest),
          do: merged_pull_request(client, base, pull, number, merged_at, branch),
          else: {:ok, nil}

      _invalid ->
        {:error, :unexpected_github_pull_request}
    end
  end

  defp normalize_pull_request(_client, _base, _pull, _branch, _digest),
    do: {:error, :unexpected_github_pull_request}

  # Explicit null still means GitHub has not finished a merge. An absent field is
  # different: API versions can omit it permanently, so resolve it from the
  # merged issue event, whose commit_id and timestamp identify the exact merge.
  defp merged_pull_request(client, base, pull, number, merged_at, branch) do
    case Map.fetch(pull, "merge_commit_sha") do
      {:ok, sha} when is_binary(sha) ->
        normalize_merged_pull_request(pull, number, merged_at, branch, sha, "pull_request")

      {:ok, nil} ->
        {:error, :github_pull_request_merge_pending}

      {:ok, _invalid} ->
        {:error, :unexpected_github_pull_request}

      :error ->
        resolve_missing_merge_commit(client, base, pull, number, merged_at, branch)
    end
  end

  defp resolve_missing_merge_commit(client, base, pull, number, merged_at, branch) do
    case client.get_json("#{base}/pulls/#{number}") do
      {:ok, detail} when is_map(detail) ->
        case Map.fetch(detail, "merge_commit_sha") do
          {:ok, sha} when is_binary(sha) ->
            normalize_merged_pull_request(
              pull,
              number,
              merged_at,
              branch,
              sha,
              "pull_request_detail"
            )

          {:ok, nil} ->
            {:error, :github_pull_request_merge_pending}

          {:ok, _invalid} ->
            {:error, :unexpected_github_pull_request}

          :error ->
            fetch_merge_event(client, base, pull, number, merged_at, branch, 1)
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_github_response}

      {:error, reason} ->
        merge_identity_endpoint_error(reason)
    end
  end

  defp fetch_merge_event(_client, _base, _pull, _number, _merged_at, _branch, page)
       when page > @max_issue_event_pages,
       do: {:error, :github_pull_request_merge_identity_unavailable}

  defp fetch_merge_event(client, base, pull, number, merged_at, branch, page) do
    case client.get_json("#{base}/issues/#{number}/events?per_page=100&page=#{page}") do
      {:ok, events} when is_list(events) and events != [] ->
        if Enum.all?(events, &is_map/1),
          do: find_merge_event(client, base, pull, number, merged_at, branch, page, events),
          else: {:error, :unexpected_github_pull_request}

      {:ok, []} ->
        {:error, :github_pull_request_merge_identity_unavailable}

      {:ok, _unexpected} ->
        {:error, :unexpected_github_response}

      {:error, reason} ->
        merge_identity_endpoint_error(reason)
    end
  end

  defp find_merge_event(client, base, pull, number, merged_at, branch, page, events) do
    case Enum.find(events, &(&1["event"] == "merged")) do
      %{"commit_id" => sha, "created_at" => event_at}
      when is_binary(sha) and is_binary(event_at) ->
        with :ok <- same_instant(event_at, merged_at) do
          normalize_merged_pull_request(
            pull,
            number,
            merged_at,
            branch,
            sha,
            "issue_event.merged.commit_id"
          )
        end

      nil when length(events) == 100 ->
        fetch_merge_event(client, base, pull, number, merged_at, branch, page + 1)

      nil ->
        {:error, :github_pull_request_merge_identity_unavailable}

      _malformed ->
        {:error, :unexpected_github_pull_request}
    end
  end

  defp merge_identity_endpoint_error({:github_transport_error, _reason} = reason),
    do: {:error, reason}

  defp merge_identity_endpoint_error({:github_http_error, _status, _message, delay} = reason)
       when is_integer(delay),
       do: {:error, reason}

  defp merge_identity_endpoint_error({:github_http_error, status, _message, _delay} = reason)
       when status in 500..599 or status == 429,
       do: {:error, reason}

  defp merge_identity_endpoint_error({:github_http_error, 403, message, nil} = reason)
       when is_binary(message) do
    normalized = String.downcase(message)

    if String.contains?(normalized, "rate limit") or
         String.contains?(normalized, "secondary rate"),
       do: {:error, reason},
       else: {:error, :github_pull_request_merge_identity_unavailable}
  end

  defp merge_identity_endpoint_error(_permanent),
    do: {:error, :github_pull_request_merge_identity_unavailable}

  defp normalize_merged_pull_request(pull, number, merged_at, branch, sha, source) do
    if valid_sha?(sha) do
      {:ok,
       %{
         "number" => number,
         "title" => bounded(pull["title"], 300),
         "body" => PullRequestBody.extract(pull["body"]),
         "html_url" => pull["html_url"],
         "merged_at" => merged_at,
         "merge_commit_sha" => sha,
         "merge_commit_source" => source,
         "head_sha" => captured_pull_head(pull),
         "base_ref" => branch
       }}
    else
      {:error, :unexpected_github_pull_request}
    end
  end

  defp same_instant(left, right) do
    with {:ok, left, _offset} <- DateTime.from_iso8601(left),
         {:ok, right, _offset} <- DateTime.from_iso8601(right),
         true <- DateTime.compare(left, right) == :eq do
      :ok
    else
      _mismatch -> {:error, :unexpected_github_pull_request}
    end
  end

  defp captured_pull_head(%{"head" => %{"sha" => sha}}),
    do: if(valid_sha?(sha), do: sha)

  defp captured_pull_head(_), do: nil

  defp commits_in_window(items, digest) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, included} ->
      case commit_datetime(item) do
        {:ok, committed_at, _offset} ->
          if in_window?(committed_at, digest),
            do: {:cont, {:ok, [item | included]}},
            else: {:cont, {:ok, included}}

        _invalid ->
          {:halt, {:error, :unexpected_github_commit_date}}
      end
    end)
    |> case do
      {:ok, included} -> {:ok, Enum.reverse(included)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_direct_commit(commit) do
    %{
      "sha" => commit["sha"],
      "message" => commit |> get_in(["commit", "message"]) |> bounded(500),
      "included_by" => "committer_date_without_merged_pull_request",
      "included_at" => get_in(commit, ["commit", "committer", "date"]),
      "author" => get_in(commit, ["author", "login"]),
      "html_url" => commit["html_url"]
    }
  end

  defp merged_to_branch?(
         %{"merged_at" => merged_at, "base" => %{"ref" => branch}},
         branch
       ),
       do: is_binary(merged_at)

  defp merged_to_branch?(_pull, _branch), do: false

  defp page_is_before_window?(items, digest) do
    Enum.all?(items, fn item ->
      case item["updated_at"] do
        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, updated_at, _offset} ->
              DateTime.compare(updated_at, digest.window_started_at) == :lt

            _invalid ->
              false
          end

        _missing ->
          false
      end
    end)
  end

  defp in_window?(datetime, digest) do
    DateTime.compare(datetime, digest.window_started_at) in [:eq, :gt] and
      DateTime.compare(datetime, digest.window_ended_at) == :lt
  end

  defp commit_datetime(item) do
    case get_in(item, ["commit", "committer", "date"]) do
      value when is_binary(value) -> DateTime.from_iso8601(value)
      _missing -> {:error, :missing_commit_date}
    end
  end

  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)
  defp bounded(_value, _limit), do: nil

  defp validate_sha(sha),
    do: if(valid_sha?(sha), do: :ok, else: {:error, :invalid_github_head_sha})

  defp validate_limit(items, limit, reason),
    do: if(length(items) <= limit, do: :ok, else: {:error, reason})

  defp unique_pull_requests(pulls) do
    pulls
    |> Enum.reduce({MapSet.new(), []}, fn pull, {seen, unique} ->
      number = pull["number"]

      if MapSet.member?(seen, number),
        do: {seen, unique},
        else: {MapSet.put(seen, number), [pull | unique]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp pull_request_scan_signature(pulls) do
    pulls
    |> unique_pull_requests()
    |> Enum.map(&{&1["number"], &1["merged_at"], &1["merge_commit_sha"]})
    |> Enum.sort()
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha)
end
