defmodule PtcManager.Deployments.LocalRevisionSource do
  @moduledoc "Demo-only revision source backed by the verified local checkout."

  @behaviour PtcManager.Deployments.RevisionSource

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.{Checkout, GitProbe}

  @impl true
  def latest(%Repository{} = repository) do
    with {:ok, path} <- Checkout.available_path(repository),
         {:ok, sha} <- GitProbe.branch_sha(path, repository.default_branch) do
      {:ok, sha}
    end
  end
end
