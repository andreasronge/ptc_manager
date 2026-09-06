defmodule PtcManager.DeliveryLaneTest do
  use ExUnit.Case, async: true
  alias PtcManager.Operations.DeliveryLane

  test "review execution is progress while the internal job remains held" do
    item = %{active_job: %{state: "blocked", review_state: "running"}, publication: nil}
    assert PtcManager.Reviews.held?(item.active_job)
    assert DeliveryLane.lane_for(item) == :working
    refute DeliveryLane.stuck?(item)
  end

  test "decision pauses, failed jobs and stop reports still require attention" do
    for job <- [
          %{state: "blocked", review_state: "paused"},
          %{state: "failed", review_state: "running"},
          %{state: "reconciling", review_state: "running"},
          %{
            state: "blocked",
            review_state: "running",
            stop_reported_at: DateTime.utc_now(),
            stop_acknowledged_at: nil
          }
        ] do
      assert DeliveryLane.lane_for(%{active_job: job, publication: nil}) == :stuck
    end
  end

  test "a review does not hide publication failures or allow premature merge readiness" do
    item = %{
      active_job: %{state: "blocked", review_state: "running"},
      publication: %{checks_state: "failure"}
    }

    assert DeliveryLane.lane_for(item) == :stuck

    publication = %{
      state: "published",
      pr_state: "open",
      draft: false,
      checks_state: "success",
      mergeability: "mergeable"
    }

    assert DeliveryLane.lane_for(%{item | publication: publication}) == :working
  end
end
