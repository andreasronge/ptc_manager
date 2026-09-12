defmodule PtcManager.Collections.StructureTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Collections.Structure
  alias PtcManager.MaintainerActions
  alias PtcManager.MaintainerActions.{ActionAdapter, Catalog}
  alias PtcManager.Operations.{Issue, PrPublication}
  alias PtcManager.Repo

  defmodule FakeSourceSnapshot do
    def capture(repository),
      do: {:ok, %{sha: String.duplicate("7", 40), ref: repository.default_branch}}
  end

  defmodule SplitAdapter do
    @behaviour PtcManager.MaintainerActions.Adapter

    def run(_action) do
      {:ok,
       %{
         "outcome" => "split",
         "private_summary" => "The issue is a plan for five pull requests.",
         "why_it_matters" => "One pull request could not be reviewed in one pass.",
         "scope" => "large",
         "risk" => "medium",
         "technical_evidence" => "Five subsystems are named in the body.",
         "github_changes" => ["Created two sub-issues", "Added blocked-by relations"],
         "evidence" => ["Read the plan"],
         "created_issue_numbers" => Process.get(:split_created, [201, 202]),
         "suggestions" => [],
         "decision_question" => "",
         "decision_options" => []
       }}
    end
  end

  # What GitHub reports after the agent split the issue: two labelled members
  # in the same repository, ordered by a native relation.
  defmodule SplitSync do
    def sync_action(action), do: {:ok, %{repository: action.repository}}

    def sync_action(action, _result) do
      umbrella = Repo.get!(Issue, action.target_id)
      repository = action.repository
      spec = Process.get(:split_structure, :well_formed)

      first = member(repository, umbrella, 201, spec)
      second = member(repository, umbrella, 202, spec)

      if spec != :foreign_blocker do
        PtcManager.OperationsFixtures.issue_dependency_fixture(second, %{
          blocking_issue: first,
          blocking_repository: repository
        })
      else
        outsider = PtcManager.OperationsFixtures.issue_fixture(repository, %{number: 300})

        PtcManager.OperationsFixtures.issue_dependency_fixture(second, %{
          blocking_issue: outsider,
          blocking_repository: repository
        })
      end

      umbrella
      |> Issue.changeset(%{
        workflow_label: if(spec == :umbrella_ready, do: "ptc:ready", else: nil),
        sub_issues: %{
          "nodes" => [
            %{
              "number" => 201,
              "state" => "open",
              "state_reason" => nil,
              "repository_full_name" => Structure.repository_full_name(repository)
            },
            %{
              "number" => 202,
              "state" => "open",
              "state_reason" => nil,
              "repository_full_name" => Structure.repository_full_name(repository)
            }
          ],
          "total" => 2
        }
      })
      |> Repo.update!()

      {:ok, %{repository: repository}}
    end

    defp member(repository, umbrella, number, spec) do
      PtcManager.OperationsFixtures.issue_fixture(repository, %{
        number: number,
        parent_issue_number: umbrella.number,
        workflow_label: if(spec == :unlabelled and number == 202, do: nil, else: "ptc:ready")
      })
    end
  end

  setup do
    Process.put(:agent_action_test_pid, self())
    previous = Application.get_env(:ptc_manager, :planning_source_snapshot)
    Application.put_env(:ptc_manager, :planning_source_snapshot, FakeSourceSnapshot)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ptc_manager, :planning_source_snapshot, previous),
        else: Application.delete_env(:ptc_manager, :planning_source_snapshot)
    end)

    :ok
  end

  defp umbrella_fixture(repository, nodes, attrs \\ %{}) do
    issue_fixture(
      repository,
      Map.merge(
        %{
          number: 100,
          sub_issues: %{
            "nodes" =>
              Enum.map(nodes, fn {number, state} ->
                %{
                  "number" => number,
                  "state" => state,
                  "state_reason" => if(state == "closed", do: "completed"),
                  "repository_full_name" => Structure.repository_full_name(repository)
                }
              end),
            "total" => length(nodes)
          }
        },
        attrs
      )
    )
  end

  describe "validate/1" do
    test "accepts a well-formed collection and names the first broken invariant" do
      repository = repository_fixture()
      umbrella = umbrella_fixture(repository, [{1, "open"}, {2, "open"}, {3, "closed"}])
      first = issue_fixture(repository, %{number: 1, workflow_label: "ptc:ready"})
      second = issue_fixture(repository, %{number: 2, workflow_label: "ptc:blocked"})

      issue_dependency_fixture(second, %{blocking_issue: first, blocking_repository: repository})

      # A closed member still has to be synchronized before its structure counts.
      assert Structure.validate(umbrella) == {:error, {:member_not_synchronized, 3}}
      issue_fixture(repository, %{number: 3, state: "closed", github_state_reason: "completed"})

      assert Structure.validate(umbrella) == :ok

      assert [%{number: 1}, %{number: 2}, %{number: 3, issue: %Issue{}}] =
               Structure.members(umbrella)

      assert Structure.validate(%{umbrella | structure_projected: false}) ==
               {:error, :issue_structure_unknown}

      assert Structure.validate(put_in(umbrella.sub_issues["overflow"], true)) ==
               {:error, :sub_issues_overflow}

      second |> Issue.changeset(%{workflow_label: nil}) |> Repo.update!()
      assert Structure.validate(umbrella) == {:error, {:member_without_workflow_label, 2}}
      Repo.reload!(second) |> Issue.changeset(%{workflow_label: "ptc:blocked"}) |> Repo.update!()

      outsider = issue_fixture(repository, %{number: 9})

      issue_dependency_fixture(first, %{blocking_issue: outsider, blocking_repository: repository})

      assert Structure.validate(umbrella) == {:error, {:foreign_blocker, 1, 9}}
    end

    test "refuses foreign, nested, unsynchronized, and cyclic members" do
      repository = repository_fixture()

      foreign =
        umbrella_fixture(repository, [{1, "open"}], %{number: 101})
        |> then(fn issue ->
          put_in(issue.sub_issues["nodes"], [
            %{"number" => 1, "state" => "open", "repository_full_name" => "other/repo"}
          ])
        end)

      assert Structure.validate(foreign) == {:error, {:cross_repository_member, 1}}

      nested_umbrella = umbrella_fixture(repository, [{5, "open"}], %{number: 102})

      issue_fixture(repository, %{
        number: 5,
        workflow_label: "ptc:ready",
        sub_issues: %{
          "nodes" => [%{"number" => 6, "state" => "open", "repository_full_name" => "x/y"}],
          "total" => 1
        }
      })

      assert Structure.validate(nested_umbrella) == {:error, {:nested_collection, 5}}

      unsynchronized = umbrella_fixture(repository, [{7, "open"}], %{number: 103})
      assert Structure.validate(unsynchronized) == {:error, {:member_not_synchronized, 7}}

      cyclic = umbrella_fixture(repository, [{11, "open"}, {12, "open"}], %{number: 104})
      a = issue_fixture(repository, %{number: 11, workflow_label: "ptc:ready"})
      b = issue_fixture(repository, %{number: 12, workflow_label: "ptc:ready"})
      issue_dependency_fixture(a, %{blocking_issue: b, blocking_repository: repository})
      issue_dependency_fixture(b, %{blocking_issue: a, blocking_repository: repository})
      assert {:error, {:dependency_cycle, _number}} = Structure.validate(cyclic)
    end
  end

  describe "result validation" do
    defp result(overrides) do
      Map.merge(
        %{
          "outcome" => "structured",
          "private_summary" => "s",
          "why_it_matters" => "w",
          "scope" => "large",
          "risk" => "low",
          "technical_evidence" => "t",
          "github_changes" => [],
          "evidence" => [],
          "decision_question" => "",
          "decision_options" => [],
          "created_issue_numbers" => [],
          "suggestions" => []
        },
        overrides
      )
    end

    # The agent fills the result from the JSON schema, so an action the schema
    # does not allow to ask a question answers needs-decision with empty
    # fields and is then rejected here as :invalid_issue_decision.
    test "the output schema lets every decision action fill decision_question" do
      description =
        :ptc_manager
        |> Application.app_dir("priv/codex/agent_action_output.schema.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["properties", "decision_question", "description"])

      for key <- ActionAdapter.decision_action_keys() do
        assert description =~ key, "schema description does not name #{key}"
      end
    end

    test "each collection action accepts only its own outcomes" do
      assert :ok = ActionAdapter.validate_result(result(%{}), "structure_collection")

      assert :ok =
               ActionAdapter.validate_result(
                 result(%{"created_issue_numbers" => [7, 8]}),
                 "structure_collection"
               )

      assert {:error, :invalid_created_issue_numbers} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "no-changes", "created_issue_numbers" => [7]}),
                 "structure_collection"
               )

      assert {:error, :invalid_agent_action_outcome} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed"}),
                 "structure_collection"
               )

      assert :ok =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "split", "created_issue_numbers" => [7]}),
                 "review_issue"
               )

      assert :ok =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed"}),
                 "collection_handoff"
               )

      assert {:error, :invalid_created_issue_numbers} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed"}),
                 "collection_closeout"
               )

      assert :ok =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed", "created_issue_numbers" => [9]}),
                 "collection_closeout"
               )

      # An escalation may only ask, and must ask properly.
      assert {:error, :invalid_agent_action_outcome} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed"}),
                 "report_collection_blocker"
               )

      assert {:error, :invalid_issue_decision} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "needs-decision"}),
                 "report_collection_blocker"
               )

      assert :ok =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "repaired"}),
                 "merge_reviewed_pr"
               )

      assert {:error, :invalid_agent_action_outcome} =
               ActionAdapter.validate_result(
                 result(%{"outcome" => "completed"}),
                 "merge_reviewed_pr"
               )
    end
  end

  describe "catalog" do
    test "builds the collection prompts with PtcManager's own protocol and pins the narrow outcome" do
      repository = repository_fixture()
      umbrella = umbrella_fixture(repository, [{1, "open"}])

      assert {:ok, attrs} =
               Catalog.build("structure_collection", %{issue: umbrella, repository: repository})

      assert attrs.prompt =~ ~s(allowed_outcomes="structured,no-changes,needs-decision")
      assert attrs.prompt =~ "/dependencies/blocked_by"
      assert attrs.prompt =~ "/sub_issues"

      assert {:ok, blocker} =
               Catalog.build("report_collection_blocker", %{
                 issue: umbrella,
                 repository: repository,
                 member_number: 1,
                 reason: "The agent stopped <script>; see the console",
                 console_url: "https://console.example/"
               })

      assert blocker.target_snapshot == %{"allowed_outcomes" => ["needs-decision"]}
      assert blocker.prompt =~ ~s(allowed_outcomes="needs-decision")
      refute blocker.prompt =~ "<script>"

      publication =
        %PrPublication{
          repository_id: repository.id,
          job_id: 1,
          state: "published",
          pr_state: "open",
          pr_number: 55,
          branch_name: "ptc-manager/issue-1-job-1",
          remote_head_sha: String.duplicate("c", 40),
          draft: true,
          checks_state: "success",
          mergeability: "mergeable"
        }

      assert {:ok, merge} =
               Catalog.build("merge_reviewed_pr", %{
                 publication: publication,
                 issue: nil,
                 repository: repository
               })

      assert merge.target_snapshot == %{"authorized_head_sha" => String.duplicate("c", 40)}
      assert merge.prompt =~ ~s(push_authorized="false")
      assert merge.prompt =~ ~s(authorized_head="#{String.duplicate("c", 40)}")

      assert Catalog.pull_request_actions(publication)
             |> Enum.map(& &1.key)
             |> Enum.member?("merge_reviewed_pr") == false
    end
  end

  describe "routing" do
    defmodule RecordingRepairAdapter do
      def run(action), do: {:ok, {:routed, action.action_key}}
      def ensure_ready(_action), do: :ready
    end

    test "the collection merge runs through the repair adapter like a fix-and-merge" do
      previous = Application.get_env(:ptc_manager, :repair_agent_adapter)
      Application.put_env(:ptc_manager, :repair_agent_adapter, RecordingRepairAdapter)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ptc_manager, :repair_agent_adapter, previous),
          else: Application.delete_env(:ptc_manager, :repair_agent_adapter)
      end)

      action = %PtcManager.Operations.AgentAction{
        action_key: "merge_reviewed_pr",
        target_snapshot: %{"repair_mode" => "retained"}
      }

      assert {:ok, {:routed, "merge_reviewed_pr"}} = ActionAdapter.run(action)
      assert :ready = ActionAdapter.ensure_ready(action)
    end
  end

  describe "split" do
    test "a split is accepted only when GitHub shows a well-formed collection" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{number: 200})
      {:ok, queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")

      assert {:ok, completed} = MaintainerActions.run_once(adapter: SplitAdapter, sync: SplitSync)
      assert completed.id == queued.id
      assert completed.state == "done"

      assert Repo.get_by!(PtcManager.Operations.Proposal, issue_id: issue.id).readiness ==
               "needs_breakdown"

      assert {:error, :issue_is_collection} =
               PtcManager.Operations.approve_issue_directly(issue.id, "andreas")
    end

    test "a split whose members are not all labelled, or that leaves the parent ready, fails" do
      for {spec, reason} <- [
            {:unlabelled,
             {:collection_structure_mismatch, {:member_without_workflow_label, 202}}},
            {:umbrella_ready, :umbrella_ready}
          ] do
        repository = repository_fixture()
        issue = issue_fixture(repository, %{number: 200})
        {:ok, _queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
        Process.put(:split_structure, spec)

        assert {:ok, failed} = MaintainerActions.run_once(adapter: SplitAdapter, sync: SplitSync)
        assert failed.state == "failed"

        case reason do
          :umbrella_ready -> assert failed.last_error =~ "github_outcome_mismatch"
          other -> assert failed.last_error =~ inspect(other)
        end
      end
    end

    test "a split that claims an issue older than the baseline fails" do
      repository = repository_fixture()
      issue = issue_fixture(repository, %{number: 200})
      issue_fixture(repository, %{number: 250})
      {:ok, _queued} = MaintainerActions.enqueue("prepare_issue", issue.id, "andreas")
      Process.put(:split_created, [201, 250])

      assert {:ok, failed} = MaintainerActions.run_once(adapter: SplitAdapter, sync: SplitSync)
      assert failed.state == "failed"
      assert failed.last_error =~ "created_issue_not_new"
    end
  end
end
