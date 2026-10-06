defmodule PtcManager.IntegratedDeliveryTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Collections.Structure
  alias PtcManager.Operations
  alias PtcManager.Operations.{DeliveryLane, Job, PrPublication}

  setup do
    {:ok, repository: mapped_repository_fixture()}
  end

  describe "dependencies" do
    test "a blocker merged into an integration branch unblocks work targeting that branch only",
         %{repository: repository} do
      blocker = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      integrate!(blocker)

      ska_dependent = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      main_dependent = issue_fixture(repository)

      for dependent <- [ska_dependent, main_dependent] do
        issue_dependency_fixture(dependent, %{
          blocking_issue: Repo.reload!(blocker),
          blocking_repository: repository
        })
      end

      assert Operations.dependencies_resolved?(Repo.reload!(ska_dependent))
      refute Operations.dependencies_resolved?(Repo.reload!(main_dependent))

      assert {:ok, %Job{base_branch: "feature/ska"}} =
               Operations.approve_issue_directly(ska_dependent.id, "andreas")

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue_directly(main_dependent.id, "andreas")
    end

    test "a blocker delivered by another issue's pull request counts as integrated",
         %{repository: repository} do
      carrier = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      blocker = issue_fixture(repository)
      publication = integrate!(carrier)

      publication
      |> PrPublication.changeset(%{
        linked_issue_numbers: %{"numbers" => [carrier.number, blocker.number]}
      })
      |> Repo.update!()

      dependent = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      issue_dependency_fixture(dependent, %{
        blocking_issue: blocker,
        blocking_repository: repository
      })

      assert Operations.dependencies_resolved?(Repo.reload!(dependent))

      item = Enum.find(Operations.dashboard_issues(), &(&1.issue.id == dependent.id))
      assert [%{satisfied: true, integrated_base: "feature/ska"}] = item.dependencies
    end

    test "sending one issue to the default branch needs its blockers completed, not integrated",
         %{repository: repository} do
      blocker = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      integrate!(blocker)
      dependent = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      issue_dependency_fixture(dependent, %{
        blocking_issue: Repo.reload!(blocker),
        blocking_repository: repository
      })

      assert {:error, :issue_dependencies_unresolved} =
               Operations.approve_issue_directly(dependent.id, "andreas", nil, nil,
                 base: :default
               )
    end

    test "Planning marks the integrated blocker as satisfied for the dependent",
         %{repository: repository} do
      blocker = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      integrate!(blocker)
      dependent = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      issue_dependency_fixture(dependent, %{
        blocking_issue: Repo.reload!(blocker),
        blocking_repository: repository
      })

      item = Enum.find(Operations.dashboard_issues(), &(&1.issue.id == dependent.id))
      assert [%{satisfied: true, integrated_base: "feature/ska"}] = item.dependencies
      assert item.base == "feature/ska"
    end

    test "a collection on the integration branch accepts an integrated blocker outside it",
         %{repository: repository} do
      outside = issue_fixture(repository, %{number: 50, github_labels: %{"names" => ["ska"]}})
      integrate!(outside)

      umbrella =
        issue_fixture(repository, %{
          number: 100,
          github_labels: %{"names" => ["ska"]},
          sub_issues: %{
            "nodes" =>
              for number <- [101, 102] do
                %{
                  "number" => number,
                  "state" => "open",
                  "repository_full_name" => Structure.repository_full_name(repository)
                }
              end,
            "total" => 2
          }
        })

      member =
        issue_fixture(repository, %{
          number: 101,
          parent_issue_number: 100,
          workflow_label: "ptc:ready"
        })

      issue_fixture(repository, %{
        number: 102,
        parent_issue_number: 100,
        workflow_label: "ptc:ready"
      })

      issue_dependency_fixture(member, %{
        blocking_issue: Repo.reload!(outside),
        blocking_repository: repository
      })

      assert :ok = Structure.validate(Repo.reload!(umbrella))

      assert {:error, {:foreign_blocker, 101, 50}} =
               Structure.validate(Repo.reload!(umbrella), "main")
    end
  end

  describe "the Integrated lane" do
    test "holds merged integration-branch work until GitHub closes the issue",
         %{repository: repository} do
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      publication = integrate!(issue)

      [item] =
        Enum.filter(Operations.delivery_board_items(), &(&1.publication.id == publication.id))

      assert DeliveryLane.lane_for(item) == :integrated
      assert item.base == "feature/ska"

      planning = Enum.find(Operations.dashboard_issues(), &(&1.issue.id == issue.id))
      assert PtcManager.Operations.PlanningGroup.classify(planning) == :in_delivery

      issue
      |> Ecto.Changeset.change(state: "closed", github_state_reason: "completed")
      |> Repo.update!()

      refute Enum.any?(
               Operations.delivery_board_items(),
               &(&1.publication && &1.publication.id == publication.id)
             )
    end

    test "follows every open issue the pull request links", %{repository: repository} do
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      other = issue_fixture(repository)
      publication = integrate!(issue)

      publication
      |> PrPublication.changeset(%{
        linked_issue_numbers: %{"numbers" => [issue.number, other.number]}
      })
      |> Repo.update!()

      [item] =
        Enum.filter(Operations.delivery_board_items(), &(&1.publication.id == publication.id))

      assert Enum.map(item.linked_issues, & &1.number) |> Enum.sort() ==
               Enum.sort([issue.number, other.number])

      assert PtcManagerWeb.DeliveryBoardLive.closes_lines([item]) ==
               Enum.map_join(Enum.sort([issue.number, other.number]), "\n", &"Closes ##{&1}")

      # Closing the job's own issue leaves the card for the other one.
      issue |> Ecto.Changeset.change(state: "closed") |> Repo.update!()

      [item] =
        Enum.filter(Operations.delivery_board_items(), &(&1.publication.id == publication.id))

      assert [%{number: number}] = item.linked_issues
      assert number == other.number
    end

    test "default-branch merges never enter it", %{repository: repository} do
      issue = issue_fixture(repository)
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      merged_publication!(job)

      refute Enum.any?(
               Operations.delivery_board_items(),
               &(DeliveryLane.lane_for(&1) == :integrated)
             )
    end
  end

  # A pull request PtcManager did not open, or whose job ended before it was
  # linked, still delivers what it closes once GitHub merged it.
  describe "external pull requests" do
    test "a blocker merged by an external pull request unblocks and is not implemented again",
         %{repository: repository} do
      blocker = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      external_merged!(repository, [blocker.number], "feature/ska")
      dependent = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})

      issue_dependency_fixture(dependent, %{
        blocking_issue: Repo.reload!(blocker),
        blocking_repository: repository
      })

      assert Operations.integrated_into?(blocker.id, "feature/ska")
      assert Operations.dependencies_resolved?(Repo.reload!(dependent))

      item = Enum.find(Operations.dashboard_issues(), &(&1.issue.id == dependent.id))
      assert [%{satisfied: true, integrated_base: "feature/ska"}] = item.dependencies

      assert {:error, :already_integrated} =
               Operations.approve_issue_directly(blocker.id, "andreas")
    end

    test "waits in the Integrated lane with the issue it closes", %{repository: repository} do
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      publication = external_merged!(repository, [issue.number], "feature/ska")

      [item] =
        Enum.filter(
          Operations.delivery_board_items(),
          &(&1.publication && &1.publication.id == publication.id)
        )

      assert DeliveryLane.lane_for(item) == :integrated
      assert item.issue.id == issue.id
      refute item.managed?
      assert PtcManagerWeb.DeliveryBoardLive.closes_lines([item]) == "Closes ##{issue.number}"
    end

    test "a collection member whose attempt was lost counts as merged", %{repository: repository} do
      issue = issue_fixture(repository, %{github_labels: %{"names" => ["ska"]}})
      {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
      job |> Job.changeset(%{state: "lost"}) |> Repo.update!()
      publication = external_merged!(repository, [issue.number], "feature/ska")
      run = %PtcManager.Collections.Run{base_branch: "feature/ska"}

      assert %{status: :merged, publication: %{id: id}} =
               PtcManager.Collections.classify(
                 %{number: issue.number, issue: Repo.reload!(issue)},
                 run
               )

      assert id == publication.id
    end
  end

  defp external_merged!(repository, linked_numbers, base_branch) do
    now = DateTime.utc_now()
    sha = String.duplicate("b", 40)
    number = 9000 + System.unique_integer([:positive])

    %PrPublication{}
    |> PrPublication.changeset(%{
      repository_id: repository.id,
      base_branch: base_branch,
      state: "published",
      idempotency_key: :crypto.hash(:sha256, "external-#{number}") |> Base.encode16(case: :lower),
      fencing_token: 0,
      branch_name: "feature/issue-#{number}",
      base_sha: sha,
      head_sha: sha,
      diff_digest: String.duplicate("d", 64),
      attempt_count: 0,
      pr_number: number,
      pr_url: "https://github.com/example/repo/pull/#{number}",
      remote_head_sha: sha,
      remote_base_sha: sha,
      published_at: now,
      pr_state: "merged",
      pr_checked_at: now,
      source: "external",
      title: "Merged elsewhere",
      head_ref: "feature/issue-#{number}",
      head_repository: "#{repository.github_owner}/#{repository.github_name}",
      linked_issue_numbers: %{"numbers" => linked_numbers}
    })
    |> Repo.insert!()
  end

  defp integrate!(issue) do
    {:ok, job} = Operations.approve_issue_directly(issue.id, "andreas")
    assert job.base_branch == "feature/ska"
    merged_publication!(job)
  end

  defp merged_publication!(job) do
    job = job |> Job.changeset(%{state: "done"}) |> Repo.update!()
    Repo.update_all(PtcManager.Automations.Invocation, set: [state: "succeeded"])
    now = DateTime.utc_now()
    sha = String.duplicate("a", 40)

    %PrPublication{}
    |> PrPublication.changeset(%{
      job_id: job.id,
      repository_id: job.repository_id,
      base_branch: job.base_branch,
      state: "published",
      idempotency_key: :crypto.hash(:sha256, "pub-#{job.id}") |> Base.encode16(case: :lower),
      fencing_token: job.fencing_token,
      branch_name: "ptc-manager/issue-job-#{job.id}",
      base_sha: sha,
      head_sha: sha,
      diff_digest: String.duplicate("c", 64),
      attempt_count: 1,
      pr_number: 4000 + job.id,
      pr_url: "https://github.com/example/repo/pull/#{4000 + job.id}",
      remote_head_sha: sha,
      remote_base_sha: sha,
      published_at: now,
      pr_state: "merged",
      pr_checked_at: now,
      source: "agent",
      title: "Merged work"
    })
    |> Repo.insert!()
  end
end
