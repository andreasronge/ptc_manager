defmodule PtcManager.Deployments.LocalRevisionSource do
  @moduledoc """
  Revision source backed by a verified local checkout.

  The latest revision is the remote default branch, fetched into the checkout
  through the configured source updater, so a merge on GitHub is visible
  without anyone pulling the checkout by hand. The checkout's own branches and
  working tree are left untouched.
  """

  @behaviour PtcManager.Deployments.RevisionSource

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.{Checkout, GitProbe}

  @impl true
  def latest(%Repository{} = repository) do
    updater = Application.fetch_env!(:ptc_manager, :source_updater)

    with {:ok, %{sha: sha}} <- updater.refresh(repository) do
      {:ok, sha}
    end
  end

  @impl true
  def content(%Repository{} = repository, sha, path) do
    with {:ok, checkout} <- Checkout.available_path(repository) do
      GitProbe.revision_content(checkout, sha, path)
    end
  end
end
