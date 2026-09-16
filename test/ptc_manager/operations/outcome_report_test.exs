defmodule PtcManager.Operations.OutcomeReportTest do
  use ExUnit.Case, async: false

  alias PtcManager.Operations.Job
  alias PtcManager.Operations.OutcomeReport

  @head String.duplicate("a", 40)
  @other String.duplicate("b", 40)

  setup do
    directory = Path.join(System.tmp_dir!(), "ptc-outcome-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    previous = Application.get_env(:ptc_manager, :agent_action_output_dir)
    Application.put_env(:ptc_manager, :agent_action_output_dir, directory)

    on_exit(fn ->
      Application.put_env(:ptc_manager, :agent_action_output_dir, previous)
      File.rm_rf(directory)
    end)

    {:ok, job: %Job{id: 7, fencing_token: 3, stop_report_token: String.duplicate("t", 20)}}
  end

  defp write!(job, contents), do: job |> OutcomeReport.path_for() |> File.write!(contents)

  defp completed(overrides \\ %{}) do
    %{
      "schema_version" => 2,
      "outcome" => "completed",
      "head_sha" => @head,
      "summary" => "Split the body on its headings.",
      "validation" => "Ran the new preview task against PR 134.",
      "retrospective" => "Untracked follow-up work: none."
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  describe "read/1" do
    test "reads a completed report", %{job: job} do
      write!(job, completed())

      assert {:ok, {:completed, payload}} = OutcomeReport.read(job)
      assert payload["head_sha"] == @head
      assert payload["validation"] =~ "preview task"
      refute Map.has_key?(payload, "outcome")
      refute Map.has_key?(payload, "schema_version")
    end

    test "reads a stopped report through the shared stopped contract", %{job: job} do
      write!(
        job,
        Jason.encode!(%{
          "schema_version" => 2,
          "outcome" => "stopped",
          "reason_code" => "missing_prerequisite",
          "summary" => "No build toolchain.",
          "detail" => "mix was not on PATH.",
          "progress" => "none"
        })
      )

      assert {:ok, {:stopped, payload}} = OutcomeReport.read(job)
      assert payload["reason_code"] == "missing_prerequisite"
      refute Map.has_key?(payload, "outcome")
      refute Map.has_key?(payload, "schema_version")
    end

    test "an absent report is none, not a failure", %{job: job} do
      assert OutcomeReport.read(job) == :none
    end

    test "rejects a report written against another schema version", %{job: job} do
      write!(job, completed(%{"schema_version" => 1}))

      assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
    end

    test "rejects a file that is not JSON", %{job: job} do
      write!(job, "not json at all")

      assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
    end

    test "rejects a file larger than the contract allows", %{job: job} do
      write!(job, completed(%{"summary" => String.duplicate("x", 40_000)}))

      assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
    end
  end

  describe "read/1 rejects a malformed completed report" do
    for {label, overrides} <- [
          {"a null section", %{"validation" => nil}},
          {"an empty section", %{"summary" => ""}},
          {"an oversized section", %{"retrospective" => String.duplicate("x", 2_001)}},
          {"a malformed head", %{"head_sha" => "not-a-sha"}},
          {"a field the contract does not define", %{"confidence" => "high"}}
        ] do
      test label, %{job: job} do
        write!(job, completed(unquote(Macro.escape(overrides))))

        assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
      end
    end

    test "a stopped report carrying an undefined field", %{job: job} do
      write!(
        job,
        Jason.encode!(%{
          "schema_version" => 2,
          "outcome" => "stopped",
          "reason_code" => "environment_broken",
          "summary" => "s",
          "detail" => "d",
          "progress" => "none",
          "head_sha" => String.duplicate("a", 40)
        })
      )

      assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
    end

    test "a missing section", %{job: job} do
      write!(
        job,
        Jason.encode!(%{
          "schema_version" => 2,
          "outcome" => "completed",
          "head_sha" => @head,
          "summary" => "only a summary"
        })
      )

      assert OutcomeReport.read(job) == {:error, :invalid_outcome_report}
    end
  end

  describe "completed_for?/2" do
    test "accepts a completed report only for the probed head", %{job: job} do
      write!(job, completed())
      assert {:ok, report} = OutcomeReport.read(job)

      assert OutcomeReport.completed_for?(report, @head)
      refute OutcomeReport.completed_for?(report, @other)
    end

    test "a stopped report is never completed for any head" do
      refute OutcomeReport.completed_for?(
               {:stopped, %{"reason_code" => "unsafe_to_proceed"}},
               @head
             )
    end

    test "accepts a SHA-256 head, which this pipeline supports elsewhere", %{job: job} do
      long = String.duplicate("a", 64)
      write!(job, completed(%{"head_sha" => long}))

      assert {:ok, report} = OutcomeReport.read(job)
      assert OutcomeReport.completed_for?(report, long)
    end
  end

  describe "path_for/1" do
    test "has no path before a token is issued" do
      assert OutcomeReport.path_for(%Job{id: 1, fencing_token: 1}) == nil
    end

    test "refuses a token that could leave the directory" do
      job = %Job{id: 1, fencing_token: 1, stop_report_token: "../../etc/passwd"}

      assert OutcomeReport.path_for(job) == nil
    end

    test "never collides with the v1 stop report name", %{job: job} do
      refute OutcomeReport.path_for(job) ==
               PtcManager.Operations.StopReport.path_for(job)
    end
  end

  describe "envelope/4" do
    test "records accepted completion material without the head twice" do
      report =
        {:completed,
         %{"head_sha" => @head, "summary" => "s", "validation" => "v", "retrospective" => "r"}}

      envelope = OutcomeReport.envelope({:ok, report}, @head, 2, ~U[2026-09-16 10:00:00Z])

      assert envelope["outcome"] == "completed"
      assert envelope["schema_version"] == 2
      assert envelope["head_sha"] == @head
      assert envelope["review_generation"] == 2
      assert envelope["observed_at"] == "2026-09-16T10:00:00Z"

      assert envelope["report"] == %{
               "summary" => "s",
               "validation" => "v",
               "retrospective" => "r"
             }
    end

    test "records an absent report as unavailable, distinct from an unusable one" do
      envelope = OutcomeReport.envelope(:none, @head, 1, ~U[2026-09-16 10:00:00Z])

      assert envelope["outcome"] == "unavailable"
      refute Map.has_key?(envelope, "report")
      refute Map.has_key?(envelope, "failure")
    end

    test "records a validation failure as unusable rather than as success" do
      envelope =
        OutcomeReport.envelope(
          {:error, :outcome_report_head_mismatch},
          @head,
          1,
          DateTime.utc_now()
        )

      assert envelope["outcome"] == "unusable"
      assert envelope["failure"] == "outcome_report_head_mismatch"
      refute Map.has_key?(envelope, "report")
    end
  end
end
