defmodule PtcManager.ResultReconcilerTest do
  use PtcManager.DataCase, async: false

  import Ecto.Query

  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Job, PrPublication}
  alias PtcManager.Repo
  alias PtcManager.ResultReconciler

  defmodule FakeProbe do
    @behaviour PtcManager.Repository.ResultProbe

    def verify(repository, job) do
      send(Process.get(:result_test_pid), {:probe, repository.id, job.id})
      Process.get(:result_probe_result)
    end
  end

  defmodule FakeContract do
    def for_result(_job, _result), do: {:ok, PtcManager.RepositoryContractFixture.contract()}
  end

  defmodule MissingContract do
    def for_result(_job, _result), do: {:error, :repository_contract_missing}
  end

  setup do
    Process.put(:result_test_pid, self())
    :ok
  end

  test "a committed branch becomes ready for the credential-isolated PR gate" do
    {_repository, _issue, job} = awaiting_job_fixture()

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 2
    }

    Process.put(:result_probe_result, {:ok, result})

    job_id = job.id

    assert {:ok, ready} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: FakeContract
             )

    assert_receive {:probe, _repository_id, ^job_id}
    assert ready.state == "ready_for_pr"
    assert ready.result_base_sha == result.base_sha
    assert ready.result_head_sha == result.head_sha
    assert ready.result_diff_digest == result.diff_digest
    assert ready.result_commit_count == 2
    assert ready.result_verified_at
    refute ready.last_error

    assert Repo.exists?(
             from audit in AuditEvent,
               where: audit.target_id == ^job.id and audit.action == "job.result_verified"
           )

    assert {:error, :already_active} = Operations.approve_issue(job.issue_id, "andreas")
  end

  test "publication ownership remains the mode captured when the job was leased" do
    previous = Application.get_env(:ptc_manager, :implementation_agent_publishes_pr)
    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, true)
    {_repository, _issue, job} = awaiting_job_fixture()
    assert job.publication_source == "agent"

    Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, false)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :implementation_agent_publishes_pr, previous)
    end)

    Process.put(
      :result_probe_result,
      {:ok,
       %{
         base_sha: String.duplicate("a", 40),
         head_sha: String.duplicate("b", 40),
         diff_digest: String.duplicate("c", 64),
         commit_count: 1
       }}
    )

    assert {:ok, _ready} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: MissingContract
             )

    assert Repo.get_by!(PrPublication, job_id: job.id).source == "agent"
    refute Repo.get!(Job, job.id).pre_publication_status
  end

  test "a missing repository contract cannot make a result publication-eligible" do
    {_repository, _issue, job} = awaiting_job_fixture()

    Process.put(
      :result_probe_result,
      {:ok,
       %{
         base_sha: String.duplicate("a", 40),
         head_sha: String.duplicate("b", 40),
         diff_digest: String.duplicate("c", 64),
         commit_count: 1
       }}
    )

    assert {:error, {:repository_contract_invalid, :repository_contract_missing}} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: MissingContract
             )

    pending = Repo.get!(Job, job.id)
    assert pending.state == "awaiting_reconciliation"
    assert pending.last_error =~ "repository_contract_missing"
    refute Repo.get_by(PrPublication, job_id: job.id)
  end

  test "reverification refreshes a pre-upgrade unpublished broker publication" do
    {_repository, _issue, job} = awaiting_job_fixture()

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 1
    }

    old_publication =
      %PrPublication{}
      |> PrPublication.changeset(%{
        job_id: job.id,
        repository_id: job.repository_id,
        state: "blocked",
        idempotency_key: String.duplicate("d", 64),
        fencing_token: job.fencing_token,
        branch_name: job.branch_name,
        base_sha: result.base_sha,
        head_sha: result.head_sha,
        diff_digest: result.diff_digest,
        attempt_count: 3,
        last_error: "pre_publication_gate_not_configured",
        source: "broker"
      })
      |> Repo.insert!()

    Process.put(:result_probe_result, {:ok, result})

    assert {:ok, ready} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: FakeContract
             )

    assert ready.state == "ready_for_pr"
    assert ready.pre_publication_status == "pending"

    refreshed = Repo.get_by!(PrPublication, job_id: job.id)
    assert refreshed.id == old_publication.id
    assert refreshed.state == "queued"
    assert refreshed.attempt_count == 0
    assert refreshed.last_error == nil
    assert refreshed.idempotency_key != old_publication.idempotency_key
  end

  test "a missing branch stays active and can be retried without GitHub writes" do
    {_repository, _issue, job} = awaiting_job_fixture()
    Process.put(:result_probe_result, {:error, :branch_missing})

    assert {:error, :branch_missing} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: FakeContract
             )

    pending = Repo.get!(Job, job.id)
    assert pending.state == "awaiting_reconciliation"
    assert pending.last_error =~ "branch_missing"
    refute pending.result_verified_at
    assert {:error, :already_active} = Operations.approve_issue(job.issue_id, "andreas")

    Process.put(
      :result_probe_result,
      {:ok,
       %{
         base_sha: String.duplicate("1", 40),
         head_sha: String.duplicate("2", 40),
         diff_digest: String.duplicate("3", 64),
         commit_count: 1
       }}
    )

    assert {:ok, %{state: "ready_for_pr"}} =
             ResultReconciler.run_job(job.id,
               probe: FakeProbe,
               contract_provider: FakeContract
             )
  end

  test "stale reconciliation results cannot overwrite a newer fenced attempt" do
    {_repository, _issue, job} = awaiting_job_fixture()
    {:ok, claimed} = Operations.claim_result_job(job.id)

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 1
    }

    assert {:error, :stale_fencing_token} =
             Operations.mark_result_verified(
               job.id,
               job.fencing_token - 1,
               claimed.result_attempt_token,
               result,
               contract()
             )

    assert Repo.get!(Job, job.id).state == "verifying_result"
  end

  test "only one verifier can claim a pending job" do
    {_repository, issue, job} = awaiting_job_fixture()

    assert {:ok, claimed} = Operations.claim_result_job(job.id)
    assert claimed.state == "verifying_result"
    assert claimed.result_attempt_token
    assert claimed.result_attempt_expires_at
    assert {:error, :result_already_claimed} = Operations.claim_result_job(job.id)
    assert {:error, :already_active} = Operations.approve_issue(issue.id, "andreas")
  end

  test "an expired verifier cannot publish after a newer claim" do
    {_repository, _issue, job} = awaiting_job_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assert {:ok, first} = Operations.claim_result_job(job.id, now)
    assert {:ok, second} = Operations.claim_result_job(job.id, DateTime.add(now, 181, :second))
    refute first.result_attempt_token == second.result_attempt_token

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 1
    }

    assert {:error, :stale_result_attempt} =
             Operations.mark_result_verified(
               job.id,
               job.fencing_token,
               first.result_attempt_token,
               result,
               contract()
             )

    assert Repo.get!(Job, job.id).result_attempt_token == second.result_attempt_token
  end

  test "a verifier cannot publish after its claim expires without a replacement" do
    {_repository, _issue, job} = awaiting_job_fixture()
    old_now = DateTime.add(DateTime.utc_now(), -181, :second) |> DateTime.truncate(:microsecond)
    assert {:ok, claimed} = Operations.claim_result_job(job.id, old_now)

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 1
    }

    assert {:error, :result_claim_expired} =
             Operations.mark_result_verified(
               job.id,
               job.fencing_token,
               claimed.result_attempt_token,
               result,
               contract()
             )

    assert Repo.get!(Job, job.id).state == "verifying_result"
  end

  test "a repeated successful completion is idempotent" do
    {_repository, _issue, job} = awaiting_job_fixture()
    {:ok, claimed} = Operations.claim_result_job(job.id)

    result = %{
      base_sha: String.duplicate("a", 40),
      head_sha: String.duplicate("b", 40),
      diff_digest: String.duplicate("c", 64),
      commit_count: 1
    }

    args = [job.id, job.fencing_token, claimed.result_attempt_token, result, contract()]
    assert {:ok, first} = apply(Operations, :mark_result_verified, args)
    assert {:ok, second} = apply(Operations, :mark_result_verified, args)
    assert first.id == second.id

    assert Repo.aggregate(
             from(audit in AuditEvent, where: audit.action == "job.result_verified"),
             :count
           ) == 1
  end

  test "a failed verification rotates behind untouched jobs" do
    {repository, _issue, first_job} = awaiting_job_fixture()
    second_issue = issue_fixture(repository)
    proposal_fixture(second_issue)
    {:ok, second_job} = Operations.approve_issue(second_issue.id, "andreas")

    second_job
    |> Job.changeset(%{
      state: "awaiting_reconciliation",
      fencing_token: 2,
      branch_name: "ptc-manager/issue-#{second_issue.number}-job-#{second_job.id}"
    })
    |> Repo.update!()

    {:ok, claimed} = Operations.claim_next_result_job()
    assert claimed.id == first_job.id

    assert {:ok, _pending} =
             Operations.record_result_error(
               claimed.id,
               claimed.fencing_token,
               claimed.result_attempt_token,
               :branch_missing
             )

    assert {:ok, next_claimed} = Operations.claim_next_result_job()
    assert next_claimed.id == second_job.id
  end

  defp awaiting_job_fixture do
    repository = repository_fixture(%{local_path: "/tmp/repository"})
    issue = issue_fixture(repository)
    proposal_fixture(issue)
    {:ok, job} = Operations.approve_issue(issue.id, "andreas")

    job =
      job
      |> Job.changeset(%{
        state: "awaiting_reconciliation",
        fencing_token: 3,
        lease_owner: "herdr:default",
        branch_name: "ptc-manager/issue-#{issue.number}-job-#{job.id}",
        publication_source:
          if(Application.get_env(:ptc_manager, :implementation_agent_publishes_pr, false),
            do: "agent",
            else: "broker"
          )
      })
      |> Repo.update!()

    {repository, issue, job}
  end

  defp contract, do: PtcManager.RepositoryContractFixture.contract()
end
