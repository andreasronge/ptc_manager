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

    test "keeps the sections a daily update needs and drops general prose" do
      sections = PullRequestBody.extract("intro prose\n\n" <> @body)
      priority = PullRequestBody.priority_only(sections)

      # summary leads: the prompt asks what changed, and a title cannot say.
      assert Map.keys(priority) |> Enum.sort() == ["retrospective", "summary", "validation"]
      refute Map.has_key?(priority, "preamble")
    end

    test "priority_only/1 drops a body that has no priority section" do
      assert PullRequestBody.extract("no headings here") |> PullRequestBody.priority_only() == nil
    end
  end

  describe "structure the old parser broke" do
    test "a shell comment inside a fenced block is not a heading" do
      body = """
      ## Validation
      Ran the extra probe:

      ```bash
      # Rebuild the snapshot and diff it
      mix ptc.digest.preview -
      ```

      Confirmed the byte count matched.

      ## Retrospective
      - none
      """

      sections = PullRequestBody.extract(body)

      assert sections["validation"] =~ "mix ptc.digest.preview"
      assert sections["validation"] =~ "Confirmed the byte count matched."
      assert sections["retrospective"] =~ "none"
    end

    test "a sub-heading does not end the section that contains it" do
      body = """
      ## Validation
      - ran mix precommit

      ### Manual check
      - clicked through the console and confirmed the digest rendered

      ## Retrospective
      - none
      """

      sections = PullRequestBody.extract(body)

      assert sections["validation"] =~ "ran mix precommit"
      assert sections["validation"] =~ "clicked through the console"
      refute sections["retrospective"] =~ "clicked through"
    end

    test "recognises the spellings GitHub templates use" do
      for {heading, key} <- [
            {"Test plan", "validation"},
            {"How to test", "validation"},
            {"What changed", "summary"},
            {"Changes", "summary"},
            {"1. Summary", "summary"},
            {"Follow-up", "retrospective"}
          ] do
        sections = PullRequestBody.extract("## #{heading}\nthe content\n")

        assert sections[key] == "the content", "expected #{heading} to map to #{key}"
      end
    end

    test "an unrecognised heading keeps its own title in the prose" do
      sections = PullRequestBody.extract("Top prose.\n\n## Notes\nsomething\n")

      assert sections["preamble"] =~ "Notes"
      assert sections["preamble"] =~ "something"
    end
  end

  describe "shorten/2" do
    test "trims every section to the byte budget" do
      sections = PullRequestBody.extract(@body)

      shortened = PullRequestBody.shorten(sections, 40)

      assert Enum.all?(shortened, fn {_key, text} -> byte_size(text) <= 40 end)
      assert shortened["validation"] =~ "Recreated"
    end

    test "never produces invalid UTF-8 when the cut lands inside a codepoint" do
      sections = PullRequestBody.extract("## Summary\n" <> String.duplicate("é", 50))

      shortened = PullRequestBody.shorten(sections, 25)

      assert String.valid?(shortened["summary"])
      assert {:ok, _json} = Jason.encode(shortened)
    end
  end

  describe "byte bounds" do
    test "bounds a multi-byte section by bytes, not characters" do
      body = "## Summary\n" <> String.duplicate("—", 2_000)

      sections = PullRequestBody.extract(body, section_limit: 300)

      assert byte_size(sections["summary"]) <= 300
    end
  end
end
