defmodule PtcManager.Deployments.LocalRevisionSourceTest do
  use ExUnit.Case, async: false

  alias PtcManager.Deployments.LocalRevisionSource
  alias PtcManager.Operations.Repository

  defmodule FetchingUpdater do
    def refresh(repository) do
      send(self(), {:refreshed, repository.default_branch})
      {:ok, %{path: "/checkout", sha: String.duplicate("c", 40), ref: "refs/remotes/origin/main"}}
    end
  end

  defmodule FailingUpdater do
    def refresh(_repository), do: {:error, {:repository_source_fetch_failed, 128, "offline"}}
  end

  setup do
    previous = Application.fetch_env!(:ptc_manager, :source_updater)
    on_exit(fn -> Application.put_env(:ptc_manager, :source_updater, previous) end)
    %{repository: %Repository{github_owner: "o", github_name: "r", default_branch: "main"}}
  end

  test "the latest revision is the freshly fetched remote default branch", %{
    repository: repository
  } do
    Application.put_env(:ptc_manager, :source_updater, FetchingUpdater)
    sha = String.duplicate("c", 40)

    assert {:ok, ^sha} = LocalRevisionSource.latest(repository)
    assert_received {:refreshed, "main"}
  end

  test "a failed fetch is reported instead of a stale local revision", %{repository: repository} do
    Application.put_env(:ptc_manager, :source_updater, FailingUpdater)

    assert {:error, {:repository_source_fetch_failed, 128, "offline"}} =
             LocalRevisionSource.latest(repository)
  end
end
