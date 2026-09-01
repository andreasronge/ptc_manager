defmodule PtcManager.MaintainerActions.Catalog do
  @moduledoc "Button action catalog and suggested prompt builders for the durable action queue."

  alias PtcManager.DailyDigests.DailyDigest
  alias PtcManager.Manager.CodexAdapter, as: PrivateAnalysisAdapter
  alias PtcManager.Operations.{Issue, Job, PrPublication, Repository}
  alias PtcManager.Automations
  alias PtcManager.Dispatch.HerdrAdapter, as: ImplementationAdapter

  @prompt_version 1
  @issue_review_limit 3
  @repair_review_limit 2

  @configurable_actions [
    %{
      key: "private_issue_analysis",
      label: "Private issue analysis",
      button: "Investigate privately",
      description: "Create the simple, private planning summary shown in the backlog."
    },
    %{
      key: "implement_issue",
      label: "Implement issue",
      button: "Approve and start",
      description:
        "Implement, test, review, commit, push, and create the issue pull request, including its Agent retrospective section."
    },
    %{
      key: "prepare_issue",
      label: "Prepare issue",
      button: "Prepare issue",
      description: "Investigate an issue and make its GitHub state implementation-ready."
    },
    %{
      key: "review_issue",
      label: "Review issue",
      button: "Review issue",
      description: "Challenge issue readiness with independent Codex reviews."
    },
    %{
      key: "daily_digest",
      label: "Daily update",
      button: "Generate daily update",
      description:
        "Summarize the previous calendar day's merged pull requests and dated direct commits as a private, easy-to-read update."
    },
    %{
      key: "resolve_issue_decision",
      label: "Resolve issue decision",
      button: "Apply decision",
      description:
        "Apply the maintainer's selected answer to GitHub and move the issue out of needs-decision."
    },
    %{
      key: "repair_pr",
      label: "Fix pull request",
      button: "Fix",
      description: "Repair CI failures or conflicts and push the existing PR branch."
    },
    %{
      key: "repair_and_merge_pr",
      label: "Fix and merge pull request",
      button: "Fix and merge",
      description: "Repair, verify, push, wait for CI, and merge the exact PR."
    }
  ]

  def configurable_actions, do: @configurable_actions

  def configurable_action?(action_key) when is_binary(action_key),
    do: Enum.any?(@configurable_actions, &(&1.key == action_key))

  @doc "Returns a safe, realistic example of the complete configured action prompt."
  def preview(action_key, instructions \\ nil, repository \\ nil) when is_binary(action_key) do
    repository = repository || preview_repository()
    issue = preview_issue(repository)
    publication = preview_publication(repository)

    prompt =
      case action_key do
        "private_issue_analysis" ->
          PrivateAnalysisAdapter.build_prompt(issue, instructions)

        "implement_issue" ->
          ImplementationAdapter.build_prompt(
            repository,
            issue,
            preview_job(repository, issue, instructions)
          )

        "prepare_issue" ->
          configured_preview(prepare_issue_prompt(repository, issue), instructions)

        "review_issue" ->
          configured_preview(review_issue_prompt(repository, issue), instructions)

        "daily_digest" ->
          configured_preview(
            daily_digest_prompt(repository, preview_digest(repository)),
            instructions
          )

        "resolve_issue_decision" ->
          configured_preview(
            resolve_issue_decision_prompt(
              repository,
              issue,
              "Choose the smallest compatible change and document the compatibility behavior."
            ),
            instructions
          )

        "repair_pr" ->
          configured_preview(repair_prompt(repository, issue, publication), instructions)

        "repair_and_merge_pr" ->
          configured_preview(
            repair_and_merge_prompt(repository, issue, publication),
            instructions
          )

        _unknown ->
          nil
      end

    if is_binary(prompt), do: String.trim(prompt), else: nil
  end

  def issue_actions(%Issue{state: "open", repository_id: repository_id}),
    do: Automations.contextual_actions(repository_id, "planning_issue")

  def issue_actions(%Issue{}), do: []

  def pull_request_actions(%PrPublication{pr_state: state}) when state in ["merged", "closed"],
    do: []

  def pull_request_actions(%PrPublication{state: "published", pr_state: "open"} = publication) do
    Automations.contextual_actions(publication_repository_id(publication), "delivery_pr")
    |> Enum.filter(fn action ->
      case action.key do
        "repair_and_merge_pr" -> true
        "repair_pr" -> repair_needed?(publication)
        "prepare_merge_decision" -> false
        _other -> true
      end
    end)
  end

  def pull_request_actions(%PrPublication{}), do: []

  defp publication_repository_id(%PrPublication{repository_id: id}) when is_integer(id), do: id

  defp publication_repository_id(%PrPublication{job: %{repository_id: id}}) when is_integer(id),
    do: id

  defp publication_repository_id(_publication), do: nil

  def build("prepare_issue", %{issue: issue, repository: repository}) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "issue",
       target_id: issue.id,
       target_label: "#{repository.github_owner}/#{repository.github_name}##{issue.number}",
       prompt_version: @prompt_version,
       prompt: configured("prepare_issue", prepare_issue_prompt(repository, issue))
     }}
  end

  def build("review_issue", %{issue: issue, repository: repository}) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "issue",
       target_id: issue.id,
       target_label: "#{repository.github_owner}/#{repository.github_name}##{issue.number}",
       prompt_version: @prompt_version,
       prompt: configured("review_issue", review_issue_prompt(repository, issue))
     }}
  end

  def build("resolve_issue_decision", %{
        issue: issue,
        repository: repository,
        decision_answer: decision_answer,
        source_action_id: source_action_id
      })
      when is_binary(decision_answer) and is_integer(source_action_id) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "issue",
       target_id: issue.id,
       target_label: "#{repository.github_owner}/#{repository.github_name}##{issue.number}",
       prompt_version: @prompt_version,
       target_snapshot: %{
         "issue_content_digest" => issue.content_digest,
         "decision_answer" => decision_answer,
         "source_action_id" => source_action_id
       },
       prompt:
         configured(
           "resolve_issue_decision",
           resolve_issue_decision_prompt(repository, issue, decision_answer)
         )
     }}
  end

  def build("daily_digest", %{repository: repository, digest: digest}) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "daily_digest",
       target_id: digest.id,
       target_label:
         "#{repository.github_owner}/#{repository.github_name} · #{Date.to_iso8601(digest.digest_date)}",
       prompt_version: @prompt_version,
       target_snapshot: %{
         "digest_date" => Date.to_iso8601(digest.digest_date),
         "window_started_at" => DateTime.to_iso8601(digest.window_started_at),
         "window_ended_at" => DateTime.to_iso8601(digest.window_ended_at),
         "time_zone" => digest.time_zone
       },
       prompt: configured("daily_digest", daily_digest_prompt(repository, digest))
     }}
  end

  def build("pr_retrospective", %{
        publication: %PrPublication{source: "external", job_id: nil}
      }),
      do: {:error, :pull_request_has_no_retained_session}

  def build("pr_retrospective", %{
        publication: publication,
        issue: issue,
        repository: repository
      })
      when publication.pr_state in ["merged", "closed"] do
    if PrPublication.managed?(publication),
      do: build_retrospective(repository, issue, publication),
      else: {:error, :pull_request_has_no_retained_session}
  end

  def build("pr_retrospective", %{
        publication: %PrPublication{state: "published", pr_state: "open"} = publication,
        issue: issue,
        repository: repository
      }) do
    if PrPublication.managed?(publication) and retrospective_ready?(publication),
      do: build_retrospective(repository, issue, publication),
      else: {:error, :pull_request_not_ready_for_retrospective}
  end

  def build("pr_retrospective", _target), do: {:error, :pull_request_unavailable}

  def build("create_retrospective_issue", %{
        publication: publication,
        issue: issue,
        repository: repository,
        suggestion: suggestion,
        source_action_id: source_action_id,
        suggestion_index: suggestion_index
      })
      when publication.pr_state in ["open", "merged", "closed"] and
             is_map(suggestion) and is_integer(source_action_id) and
             is_integer(suggestion_index) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "pull_request",
       target_id: publication.id,
       target_label:
         "#{repository.github_owner}/#{repository.github_name}##{publication.pr_number}",
       prompt_version: @prompt_version,
       target_snapshot: %{
         "source_action_id" => source_action_id,
         "suggestion_index" => suggestion_index
       },
       prompt:
         configured(
           "create_retrospective_issue",
           create_retrospective_issue_prompt(repository, issue, publication, suggestion)
         )
     }}
  end

  def build("create_retrospective_issue", _target), do: {:error, :invalid_suggestion}

  def build("prepare_merge_decision", %{
        publication: %PrPublication{source: "external", job_id: nil}
      }),
      do: {:error, :external_pull_request_has_no_isolated_merge_reviewer}

  def build("prepare_merge_decision", %{
        publication: %PrPublication{state: "published", pr_state: "open"} = publication,
        issue: issue,
        repository: repository
      }) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "pull_request",
       target_id: publication.id,
       target_label:
         "#{repository.github_owner}/#{repository.github_name}##{publication.pr_number}",
       prompt_version: @prompt_version,
       prompt:
         configured(
           "prepare_merge_decision",
           merge_decision_prompt(repository, issue, publication)
         )
     }}
  end

  def build("prepare_merge_decision", _target), do: {:error, :pull_request_not_open}

  def build("repair_pr", %{
        publication: %PrPublication{state: "published", pr_state: "open"} = publication,
        issue: issue,
        repository: repository
      }) do
    if repair_needed?(publication) and repair_supported?(publication, repository) do
      {:ok,
       %{
         repository_id: repository.id,
         target_type: "pull_request",
         target_id: publication.id,
         target_label:
           "#{repository.github_owner}/#{repository.github_name}##{publication.pr_number}",
         prompt_version: @prompt_version,
         prompt: configured("repair_pr", repair_prompt(repository, issue, publication))
       }}
    else
      {:error, :pull_request_does_not_need_repair}
    end
  end

  def build("repair_pr", _target), do: {:error, :pull_request_not_open}

  def build("repair_and_merge_pr", %{
        publication: %PrPublication{state: "published", pr_state: "open"} = publication,
        issue: issue,
        repository: repository
      }) do
    if repair_supported?(publication, repository) do
      {:ok,
       %{
         repository_id: repository.id,
         target_type: "pull_request",
         target_id: publication.id,
         target_label:
           "#{repository.github_owner}/#{repository.github_name}##{publication.pr_number}",
         prompt_version: @prompt_version,
         prompt:
           configured(
             "repair_and_merge_pr",
             repair_and_merge_prompt(repository, issue, publication)
           )
       }}
    else
      {:error, :pull_request_cannot_be_merged_by_agent}
    end
  end

  def build("repair_and_merge_pr", _target), do: {:error, :pull_request_not_open}
  def build(_action_key, _target), do: {:error, :unknown_agent_action}

  def label("prepare_issue"), do: "Prepare issue"
  def label("review_issue"), do: "Review issue"
  def label("daily_digest"), do: "Daily update"
  def label("resolve_issue_decision"), do: "Apply decision"
  def label("pr_retrospective"), do: "PR retrospective"
  def label("create_retrospective_issue"), do: "Create follow-up issue"
  def label("repair_pr"), do: "Fix CI or conflicts"
  def label("repair_and_merge_pr"), do: "Approve and merge"
  def label(action_key), do: action_key |> String.replace("_", " ") |> String.capitalize()

  defp build_retrospective(repository, issue, publication) do
    {:ok,
     %{
       repository_id: repository.id,
       target_type: "pull_request",
       target_id: publication.id,
       target_label:
         "#{repository.github_owner}/#{repository.github_name}##{publication.pr_number}",
       prompt_version: @prompt_version,
       prompt:
         configured("pr_retrospective", retrospective_prompt(repository, issue, publication))
     }}
  end

  defp prepare_issue_prompt(repository, issue) do
    """
    <runtime_context action="prepare_issue" repository="#{repository.github_owner}/#{repository.github_name}" github_access="trusted_direct" allowed_outcomes="ready,blocked,needs-decision,reject" />
    <issue_data>
    Number: #{issue.number}
    Title: #{issue.title}
    Body:
    #{String.slice(issue.body || "", 0, 20_000)}
    </issue_data>
    """
  end

  defp resolve_issue_decision_prompt(repository, issue, decision_answer) do
    """
    <runtime_context action="resolve_issue_decision" repository="#{repository.github_owner}/#{repository.github_name}" github_access="trusted_direct" allowed_outcomes="ready,blocked,needs-decision,reject" />
    <maintainer_decision>
    #{decision_answer}
    </maintainer_decision>
    <issue_data>
    Number: #{issue.number}
    Title: #{issue.title}
    Body:
    #{String.slice(issue.body || "", 0, 20_000)}
    </issue_data>
    """
  end

  defp review_issue_prompt(repository, issue) do
    """
    <runtime_context action="review_issue" repository="#{repository.github_owner}/#{repository.github_name}" github_access="trusted_direct" review_limit="#{@issue_review_limit}" allowed_outcomes="ready,blocked,needs-decision,reject" />
    <issue_data>
    Number: #{issue.number}
    Title: #{issue.title}
    Body:
    #{String.slice(issue.body || "", 0, 20_000)}
    </issue_data>
    """
  end

  defp daily_digest_prompt(repository, digest) do
    started_at = DateTime.to_iso8601(digest.window_started_at)
    ended_at = DateTime.to_iso8601(digest.window_ended_at)

    """
    <runtime_context action="daily_digest" repository="#{repository.github_owner}/#{repository.github_name}" github_access="none" date="#{Date.to_iso8601(digest.digest_date)}" time_zone="#{digest.time_zone}" window_start="#{started_at}" window_end="#{ended_at}" />
    """
  end

  defp retrospective_prompt(repository, issue, publication) do
    """
    <runtime_context action="pr_retrospective" repository="#{repository.github_owner}/#{repository.github_name}" github_access="read" pr="#{publication.pr_number}" pr_state="#{publication.pr_state}" related_issue="#{issue.number}" allowed_outcomes="followups-proposed,no-followups" suggestion_limit="5" />
    """
  end

  defp create_retrospective_issue_prompt(repository, issue, publication, suggestion) do
    """
    <runtime_context action="create_retrospective_issue" repository="#{repository.github_owner}/#{repository.github_name}" github_access="trusted_direct" pr="#{publication.pr_number}" related_issue="#{issue.number}" allowed_outcomes="followups-created,no-followups" create_limit="1" />
    <suggestion>
    Title: #{suggestion["title"]}
    Simple summary: #{suggestion["simple_summary"]}
    Why it matters: #{suggestion["why_it_matters"]}
    Category: #{suggestion["category"]}
    Technical evidence: #{suggestion["technical_evidence"]}
    Suggested issue body:
    #{suggestion["suggested_issue_body"]}
    </suggestion>
    """
  end

  defp merge_decision_prompt(repository, issue, publication) do
    """
    <runtime_context action="prepare_merge_decision" repository="#{repository.github_owner}/#{repository.github_name}" github_access="read" allowed_outcomes="merge-ready,merge-blocked,merge-needs-decision" />
    <pull_request_data>
    PR: ##{publication.pr_number}
    Verified head: #{publication.remote_head_sha}
    Original verified base: #{publication.base_sha}
    Verified diff digest: #{publication.diff_digest}
    #{related_issue_snapshot(issue)}
    </pull_request_data>
    """
  end

  defp repair_prompt(repository, issue, publication, opts \\ []) do
    repo = "#{repository.github_owner}/#{repository.github_name}"
    merge_authorized? = Keyword.get(opts, :merge_authorized?, false)

    """
    <runtime_context action="repair_pr" repository="#{repo}" github_access="trusted_direct" merge_authorized="#{merge_authorized?}" default_branch="#{repository.default_branch}" retained_workspace="#{PrPublication.managed?(publication)}" review_limit="#{@repair_review_limit}" allowed_outcomes="repaired,repair-blocked" />
    <pull_request_data>
    PR: ##{publication.pr_number}
    Branch: #{publication.branch_name}
    Last observed head: #{publication.remote_head_sha}
    Checks: #{publication.checks_state}
    Mergeability: #{publication.mergeability}
    #{related_issue_snapshot(issue)}
    </pull_request_data>
    """
  end

  defp repair_and_merge_prompt(repository, issue, publication) do
    repair_prompt(repository, issue, publication, merge_authorized?: true)
  end

  defp repair_needed?(%PrPublication{} = publication) do
    publication.checks_state == "failure" or publication.mergeability == "conflicting"
  end

  defp repair_supported?(%PrPublication{} = publication, repository) do
    PrPublication.managed?(publication) or
      String.downcase(publication.head_repository || "") ==
        String.downcase("#{repository.github_owner}/#{repository.github_name}")
  end

  # Kept for legacy retrospective actions already present in durable history.
  defp retrospective_ready?(%PrPublication{} = publication) do
    PrPublication.managed?(publication) and not publication.draft and
      publication.checks_state in ["success", "none"] and
      publication.mergeability == "mergeable"
  end

  defp related_issue_snapshot(%Issue{number: number, title: title}),
    do: "Related issue: ##{number} — #{title}"

  defp related_issue_snapshot(_issue),
    do: "Related issue: none recorded in PtcManager; use the PR body and GitHub links as context."

  defp preview_repository do
    %Repository{
      id: 1,
      github_owner: "andreasronge",
      github_name: "example_repository",
      default_branch: "main",
      required_pre_pr_reviews: 2
    }
  end

  defp preview_issue(repository) do
    %Issue{
      id: 123,
      repository_id: repository.id,
      repository: repository,
      number: 123,
      state: "open",
      title: "Example: preserve compatibility when loading project configuration",
      body:
        "Users with an older configuration file should receive a clear migration message instead of an unexplained failure.",
      content_digest: String.duplicate("1", 64)
    }
  end

  defp preview_job(repository, issue, instructions) do
    %Job{
      id: 42,
      repository_id: repository.id,
      issue_id: issue.id,
      fencing_token: 7,
      branch_name: "ptc-manager/issue-123-job-42",
      publication_source: "agent",
      required_review_count: 2,
      prompt_instructions: instructions
    }
  end

  defp preview_publication(repository) do
    %PrPublication{
      id: 456,
      repository_id: repository.id,
      job_id: 42,
      source: "agent",
      state: "published",
      pr_state: "open",
      pr_number: 456,
      branch_name: "ptc-manager/issue-123-job-42",
      head_ref: "ptc-manager/issue-123-job-42",
      head_repository: "andreasronge/example_repository",
      base_sha: String.duplicate("a", 40),
      remote_base_sha: String.duplicate("b", 40),
      remote_head_sha: String.duplicate("c", 40),
      diff_digest: String.duplicate("d", 64),
      checks_state: "failure",
      mergeability: "conflicting"
    }
  end

  defp preview_digest(repository) do
    %DailyDigest{
      id: 789,
      repository_id: repository.id,
      digest_date: ~D[2026-08-31],
      window_started_at: ~U[2026-08-30 22:00:00Z],
      window_ended_at: ~U[2026-08-31 22:00:00Z],
      time_zone: "Europe/Stockholm"
    }
  end

  defp configured_preview(runtime_context, user_prompt),
    do: Automations.compose_prompt(user_prompt, runtime_context)

  defp configured(_action_key, prompt), do: prompt
end
