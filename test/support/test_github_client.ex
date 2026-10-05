defmodule PtcManager.TestGitHubClient do
  @behaviour PtcManager.GitHub

  def get_repository(owner, name), do: response({owner, name})
  def list_open_issues(_repository), do: {:ok, []}
  def get_issue(_repository, _number), do: {:error, :not_implemented}
  def review_context(_repository, _target), do: {:ok, %{"body" => ""}}

  def list_branches(_repository),
    do: {:ok, Application.get_env(:ptc_manager, :test_github_branches, ["main"])}

  def branch_exists?(_repository, branch),
    do: {:ok, branch in Application.get_env(:ptc_manager, :test_github_branches, ["main"])}

  defp response(key) do
    case Application.get_env(:ptc_manager, :test_github_repositories, :all) do
      :all ->
        {:ok,
         %{
           "nameWithOwner" => Enum.join(Tuple.to_list(key), "/"),
           "defaultBranchRef" => %{"name" => "main"}
         }}

      responses ->
        Map.get(responses, key, {:error, :repository_not_found})
    end
  end
end
