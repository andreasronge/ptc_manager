defmodule PtcManager.OperationsFixtures do
  alias PtcManager.Operations
  alias PtcManager.Operations.IssueDependency
  alias PtcManager.Repo

  def repository_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      github_owner: "owner-#{suffix}",
      github_name: "repo-#{suffix}",
      default_branch: "main"
    }

    {:ok, repository} =
      retry_sqlite_sandbox_handoff(fn ->
        Operations.create_repository(Map.merge(defaults, attrs))
      end)

    repository
  end

  def issue_fixture(repository, attrs \\ %{}) do
    number = Map.get(attrs, :number, System.unique_integer([:positive]))
    title = Map.get(attrs, :title, "Issue #{number}")
    updated_at = Map.get(attrs, :github_updated_at, now())
    body_digest = digest("body-#{number}")

    defaults = %{
      repository_id: repository.id,
      number: number,
      title: title,
      html_url:
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/issues/#{number}",
      state: "open",
      dependencies_projected: true,
      github_assignment_projected: true,
      body_digest: body_digest,
      content_digest: digest("#{title}:#{body_digest}"),
      github_updated_at: updated_at
    }

    {:ok, issue} = Operations.create_issue(Map.merge(defaults, attrs))
    issue
  end

  def proposal_fixture(issue, attrs \\ %{}) do
    defaults = %{
      issue_id: issue.id,
      source_updated_at: issue.github_updated_at,
      source_digest: issue.content_digest,
      proposal_digest: digest("proposal-#{issue.id}"),
      plain_summary: "This is the private plain-language summary.",
      why_it_matters: "It makes the project easier to use.",
      scope: "small",
      risk: "low",
      readiness: "ready",
      technical_evidence: "The affected code path and tests were inspected."
    }

    {:ok, proposal} = Operations.create_proposal(Map.merge(defaults, attrs))
    proposal
  end

  def issue_dependency_fixture(issue, attrs) do
    blocker = Map.get(attrs, :blocking_issue)
    repository = Map.get(attrs, :blocking_repository)

    defaults = %{
      issue_id: issue.id,
      blocking_issue_id: blocker && blocker.id,
      blocking_repository_id: repository && repository.id,
      blocking_repository_full_name:
        repository && String.downcase("#{repository.github_owner}/#{repository.github_name}"),
      blocking_issue_number: blocker && blocker.number,
      blocking_title: blocker && blocker.title,
      blocking_html_url: blocker && blocker.html_url,
      blocking_state: blocker && blocker.state,
      blocking_state_reason: blocker && blocker.github_state_reason,
      lookup_state: "resolved"
    }

    persisted_attrs = Map.drop(attrs, [:blocking_issue, :blocking_repository])

    %IssueDependency{}
    |> IssueDependency.changeset(Map.merge(defaults, persisted_attrs))
    |> Repo.insert!()
  end

  def worker_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      worker_key: "worker-#{suffix}",
      name: "Worker #{suffix}",
      status: "online",
      capabilities: %{"herdr" => true},
      last_heartbeat_at: now(),
      coordinator_incarnation_id: PtcManager.RuntimeIncarnation.current()
    }

    {:ok, worker} = Operations.create_worker(Map.merge(defaults, attrs))
    worker
  end

  def external_pr_status(repository, number, head_sha) do
    %{
      pr_number: number,
      pr_url:
        "https://github.com/#{repository.github_owner}/#{repository.github_name}/pull/#{number}",
      state: "open",
      draft: false,
      title: "External repair candidate",
      author_login: "outside-author",
      body: "",
      head_sha: head_sha,
      head_ref: "external/fix-#{number}",
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      base_sha: String.duplicate("a", 40),
      base_ref: repository.default_branch,
      base_repository: "#{repository.github_owner}/#{repository.github_name}",
      mergeability: "conflicting",
      mergeable_state: "dirty",
      checks_state: "failure",
      checks_total: 1,
      checks_failed: 1,
      checks_pending: 0
    }
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  def digest(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # A LiveView from the preceding non-async test can release its sandbox owner
  # just after ExUnit starts the next test. SQLite reports that brief ownership
  # handoff as busy instead of waiting. Keep the retry inside test fixtures so
  # production writes retain their fail-closed behavior.
  defp retry_sqlite_sandbox_handoff(fun, attempts_left \\ 3)

  defp retry_sqlite_sandbox_handoff(fun, attempts_left) do
    fun.()
  rescue
    error in Exqlite.Error ->
      if attempts_left > 1 and error.message in ["Database busy", "database is locked"] do
        Process.sleep(10)
        retry_sqlite_sandbox_handoff(fun, attempts_left - 1)
      else
        reraise(error, __STACKTRACE__)
      end
  end
end
