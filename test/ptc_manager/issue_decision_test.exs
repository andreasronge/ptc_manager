defmodule PtcManager.IssueDecisionTest do
  use ExUnit.Case, async: true

  alias PtcManager.IssueDecision

  @result %{
    "outcome" => "needs-decision",
    "decision_question" => "Should misses identify exact exports or only a shipped namespace?",
    "decision_options" => [
      %{
        "label" => "Exact export",
        "description" => "Only redirect names that are real shipped commands.",
        "example" => "agent.core/run gets help; agent.core/typo stays an ordinary miss."
      },
      %{
        "label" => "Namespace hint",
        "description" => "Give a broad hint whenever the library name is shipped.",
        "example" => "Both agent.core/run and agent.core/typo mention the unattached library."
      }
    ]
  }

  test "validates a schema-backed decision into stable choices" do
    assert {:ok, decision} = IssueDecision.from_result(@result)

    assert decision.question ==
             "Should misses identify exact exports or only a shipped namespace?"

    assert [exact, namespace] = decision.options
    assert exact.letter == "A"
    assert exact.label == "Exact export"
    assert exact.example =~ "agent.core/typo"
    assert namespace.letter == "B"
  end

  test "resolves either a canonical option or a bounded custom answer" do
    {:ok, decision} = IssueDecision.from_result(@result)

    assert {:ok, %{kind: "option", option_index: 0, value: answer}} =
             IssueDecision.answer(decision, "0", "")

    assert answer =~ "Exact export"
    assert answer =~ "agent.core/run"

    assert {:ok, %{kind: "custom", value: "Do the narrow fix first."}} =
             IssueDecision.answer(decision, "", "  Do the narrow fix first.  ")

    assert {:error, :decision_answer_missing} = IssueDecision.answer(decision, "", "")
  end

  test "rejects option indexes outside the available choices" do
    {:ok, decision} = IssueDecision.from_result(@result)

    assert {:error, :decision_answer_missing} = IssueDecision.answer(decision, "-1", "")
    assert {:error, :decision_answer_missing} = IssueDecision.answer(decision, "2", "")
  end

  test "counts custom answer characters instead of UTF-8 bytes" do
    {:ok, decision} = IssueDecision.from_result(@result)

    assert {:ok, %{kind: "custom"}} =
             IssueDecision.answer(decision, "", String.duplicate("å", 2_000))

    assert {:error, :decision_answer_too_long} =
             IssueDecision.answer(decision, "", String.duplicate("å", 2_001))
  end

  test "rejects missing, incomplete, and non-decision output" do
    assert {:error, :decision_format_invalid} = IssueDecision.from_result(%{})

    assert {:error, :decision_format_invalid} =
             IssueDecision.from_result(%{
               "outcome" => "needs-decision",
               "decision_question" => "Only one option?",
               "decision_options" => [hd(@result["decision_options"])]
             })

    assert {:error, :decision_format_invalid} =
             IssueDecision.from_result(Map.put(@result, "outcome", "ready"))
  end
end
