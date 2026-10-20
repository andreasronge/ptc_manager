defmodule PtcManager.Cluster.Fence do
  @moduledoc """
  Whether this member may admit new work for a repository, as far as the
  cluster is concerned.

  Unclustered, always. On a member, not until the startup round has heard from
  every peer, not while any peer refuses this machine as a member, not for a
  disabled repository (disabling is how a member gives up a claim), and not
  for a repository a peer also claims. Running work is never touched: it keeps
  reconciling and publishing.
  """

  import Ecto.Query

  alias PtcManager.{Cluster, Repo}
  alias PtcManager.Cluster.{Claims, PeerPoller}
  alias PtcManager.Operations.Repository

  @doc "`:ok` or `{:error, reason}` for one repository."
  def admission(%Repository{} = repository) do
    if Cluster.enabled?(), do: member_admission(repository, PeerPoller.current()), else: :ok
  end

  defp member_admission(repository, cluster) do
    cond do
      cluster.refused_by != [] -> {:error, :not_member}
      not cluster.startup_complete? -> {:error, :cluster_startup}
      not repository.enabled -> {:error, :repository_disabled}
      Claims.key(repository) in cluster.conflicts -> {:error, :ownership_conflict}
      true -> :ok
    end
  end

  @doc "Ids of repositories this member may not admit work for now."
  def fenced_repository_ids do
    if Cluster.enabled?() do
      cluster = PeerPoller.current()

      Repo.all(from(repository in Repository))
      |> Enum.reject(&(member_admission(&1, cluster) == :ok))
      |> Enum.map(& &1.id)
    else
      []
    end
  end

  @doc "A sentence for a banner, or nil when nothing fences the whole console."
  def console_banner do
    if Cluster.enabled?() do
      cluster = PeerPoller.current()

      cond do
        cluster.refused_by != [] ->
          "#{Enum.join(cluster.refused_by, ", ")} does not count this machine as a member, so it admits no new work. Fix the member maps and restart."

        not cluster.startup_complete? ->
          "Waiting to hear from every member before admitting new work. Running work continues."

        cluster.conflicts != [] ->
          "Another member also claims #{Enum.join(cluster.conflicts, ", ")}. No new work starts for it here until it is disabled on one side."

        true ->
          nil
      end
    end
  end

  def reason_words(:not_member), do: "another member does not count this machine as a member"

  def reason_words(:cluster_startup),
    do: "this console is still hearing from every member after a restart"

  def reason_words(:repository_disabled), do: "the repository is disabled on this machine"
  def reason_words(:ownership_conflict), do: "another member also claims the repository"
end
