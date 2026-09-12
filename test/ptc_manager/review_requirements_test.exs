defmodule PtcManager.ReviewRequirementsTest do
  use ExUnit.Case, async: true
  alias PtcManager.Reviews.Requirements

  defmodule Client do
    def review_context(repository, target) do
      send(self(), {:read, repository.github_owner, repository.github_name, target})

      case target do
        {:issue, 1} ->
          {:ok,
           %{
             "url" => "https://github.com/team/private/issues/1",
             "body" => "See #2 and https://github.com/team/private/blob/main/docs/rules.md",
             "comments" => %{
               "nodes" => [%{"body" => "Private clarification", "url" => "comment URL"}]
             }
           }}

        {:issue, 2} ->
          {:ok, %{"body" => "Linked private requirement"}}

        {:blob, "main/docs/rules.md"} ->
          {:ok, %{"text" => "Documented behavior"}}
      end
    end
  end

  defmodule ScopeClient do
    def review_context(%{github_owner: "team", github_name: "private"}, {:issue, 1}),
      do: {:ok, %{"body" => "https://github.com/other/secret/issues/9"}}

    def review_context(_, _), do: raise("request crossed the approved repository boundary")
  end

  defmodule Unavailable do
    def review_context(_, _), do: {:error, :github_unavailable}
  end

  # Job 109: ptc_manager#75 wrote ptc_runner's issue numbers bare, so `#1890`
  # resolved to an issue its own repository does not have.
  defmodule CrossRepositoryNumber do
    def review_context(_repository, {:issue, 1}),
      do: {:ok, %{"body" => "Jobs 106 (#1890) and 107 (#1891) failed"}}

    def review_context(_repository, {:issue, _absent}),
      do: {:error, :review_context_missing}
  end

  defp job do
    %{
      repository: %{github_owner: "team", github_name: "private"},
      issue: %{number: 1, body: "See #2"},
      execution_settings: %{}
    }
  end

  test "private comments and linked issues/documents use the authenticated read-only client" do
    assert {:ok, text} = Requirements.capture(job(), Client)
    assert text =~ "Private clarification"
    assert text =~ "Linked private requirement"
    assert text =~ "Documented behavior"
    assert_received {:read, "team", "private", {:issue, 1}}
    assert_received {:read, "team", "private", {:issue, 2}}
    assert_received {:read, "team", "private", {:blob, "main/docs/rules.md"}}
    refute_received {:read, _, _, _}
  end

  test "untrusted links cannot expand the approved repository scope" do
    assert {:ok, text} = Requirements.capture(put_in(job().issue.body, ""), ScopeClient)
    assert text =~ "outside the approved repository"
  end

  test "blob links retain slash refs, decode paths, and strip sentence punctuation" do
    assert Requirements.references(
             "https://github.com/team/private/blob/feature/foo/docs/rules%20v2.md.",
             "team",
             "private"
           ) ==
             [{"team", "private", {:blob, "feature/foo/docs/rules v2.md"}}]
  end

  test "unavailable linked context fails preparation instead of returning a clean review" do
    assert {:error, {:review_requirements_unavailable, "team/private", _}} =
             Requirements.capture(job(), Unavailable)
  end

  test "a number this repository does not have is noted, not a reason to withhold review" do
    assert {:ok, text} =
             Requirements.capture(put_in(job().issue.body, ""), CrossRepositoryNumber)

    assert text =~ "does not exist there"
    assert text =~ "{:issue, 1890}"
    assert text =~ "{:issue, 1891}"
    assert text =~ "Jobs 106"
  end

  test "links cannot redirect the context client to arbitrary network targets" do
    assert Requirements.references(
             "https://github.com.evil.test/team/private/issues/2 http://169.254.169.254/latest",
             "team",
             "private"
           ) == []

    assert Requirements.references("https://github.com/other/repo/issues/3", "team", "private") ==
             [{"other", "repo", {:issue, 3}}]
  end
end
