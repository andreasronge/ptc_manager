defmodule PtcManager.OperationsFixtures do
  alias PtcManager.Operations

  def repository_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      github_owner: "owner-#{suffix}",
      github_name: "repo-#{suffix}",
      default_branch: "main"
    }

    {:ok, repository} = Operations.create_repository(Map.merge(defaults, attrs))
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

  def worker_fixture(attrs \\ %{}) do
    suffix = System.unique_integer([:positive])

    defaults = %{
      worker_key: "worker-#{suffix}",
      name: "Worker #{suffix}",
      status: "online",
      capabilities: %{"herdr" => true},
      last_heartbeat_at: now()
    }

    {:ok, worker} = Operations.create_worker(Map.merge(defaults, attrs))
    worker
  end

  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  def digest(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
