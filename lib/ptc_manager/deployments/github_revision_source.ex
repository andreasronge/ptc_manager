defmodule PtcManager.Deployments.GitHubRevisionSource do
  @moduledoc false

  @behaviour PtcManager.Deployments.RevisionSource

  alias PtcManager.GitHub.Client
  alias PtcManager.Operations.Repository

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  @impl true
  def latest(%Repository{} = repository) do
    owner = URI.encode_www_form(repository.github_owner)
    name = URI.encode_www_form(repository.github_name)
    branch = URI.encode_www_form(repository.default_branch)

    with {:ok, %{"sha" => sha}} <-
           Client.get_json("https://api.github.com/repos/#{owner}/#{name}/commits/#{branch}"),
         true <- is_binary(sha) and Regex.match?(@sha, sha) do
      {:ok, sha}
    else
      false -> {:error, :invalid_github_head_sha}
      {:ok, _unexpected} -> {:error, :unexpected_github_response}
      {:error, reason} -> {:error, reason}
    end
  end
end
