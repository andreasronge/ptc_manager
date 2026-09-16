defmodule PtcManager.DailyDigests.PullRequestBodyTest do
  use ExUnit.Case, async: true

  alias PtcManager.DailyDigests.PullRequestBody

  # The shape this repository's own pull requests use. A flat 600-character
  # slice of it keeps part of the summary and loses validation and the
  # retrospective entirely, which is the material a daily update needs most.
  @body """
  ## Summary
  - recover an oversized review patch when Git chooses a different object-ID abbreviation in the exact-commit snapshot
  - retain the recorded SHA-256 as the fail-closed acceptance condition and preserve existing review/publication digests
  - bound all regeneration attempts by one review deadline and cover asymmetric, multi-file index headers

  ## Validation
  - Recreated job 155's source snapshot on production and recovered the exact recorded 1,499,018-byte patch.
  - Ran the independent Pi review workflow; addressed its persisted-digest and mixed-width-header findings.

  ## Retrospective
  - Untracked follow-up work: none.
  - Repository instruction that was missing, wrong, or guessed: none.

  Closes #133
  """

  describe "extract/2" do
    test "keeps validation and retrospective that a flat slice would drop" do
      assert String.length(@body) > 600
      refute String.contains?(String.slice(@body, 0, 600), "Untracked follow-up work")

      sections = PullRequestBody.extract(@body)

      assert sections["validation"] =~ "Recreated job 155's source snapshot"
      assert sections["retrospective"] =~ "Untracked follow-up work: none."
      assert sections["summary"] =~ "recover an oversized review patch"
    end

    test "does not repeat the heading inside the section text" do
      sections = PullRequestBody.extract(@body)

      refute sections["summary"] =~ "## Summary"
      refute sections["validation"] =~ "## Validation"
    end

    test "bounds each section independently" do
      long = "## Summary\n" <> String.duplicate("a", 5_000) <> "\n\n## Validation\nshort\n"

      sections = PullRequestBody.extract(long, section_limit: 100)

      assert String.length(sections["summary"]) == 100
      assert sections["validation"] == "short"
    end

    test "collects prose with no recognized heading as preamble" do
      sections = PullRequestBody.extract("Just a sentence with no headings at all.")

      assert sections["preamble"] == "Just a sentence with no headings at all."
      refute Map.has_key?(sections, "summary")
    end

    test "treats an unrecognized heading as general prose, not a known section" do
      sections = PullRequestBody.extract("## Notes\nsomething\n\n## Validation\nran it\n")

      assert sections["validation"] == "ran it"
      assert sections["preamble"] =~ "something"
      refute Map.has_key?(sections, "summary")
    end

    test "matches headings case-insensitively and ignores emphasis and trailing hashes" do
      sections = PullRequestBody.extract("### **validation** ###\nran it\n")

      assert sections["validation"] == "ran it"
    end

    test "omits a recognized heading with no content" do
      sections = PullRequestBody.extract("## Summary\n\n## Validation\nran it\n")

      refute Map.has_key?(sections, "summary")
      assert sections["validation"] == "ran it"
    end

    test "returns nil for a body that is absent or blank" do
      assert PullRequestBody.extract(nil) == nil
      assert PullRequestBody.extract("   \n\n  ") == nil
    end

    test "keeps only the priority sections when asked" do
      sections = PullRequestBody.extract(@body)
      priority = PullRequestBody.priority_only(sections)

      assert Map.keys(priority) |> Enum.sort() == ["retrospective", "validation"]
    end

    test "priority_only/1 drops a body that has no priority section" do
      assert PullRequestBody.extract("no headings here") |> PullRequestBody.priority_only() == nil
    end
  end
end
