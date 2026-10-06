defmodule PtcManager.CommitIdentities do
  @moduledoc "Plain-text agent commit identities, resolved by owner then default."
  import Ecto.Query
  alias PtcManager.Operations.{AuditEvent, CommitIdentity, Repository}
  alias PtcManager.{AgentEnvironmentVariables, Operations, Repo, RepoTransaction}

  def list, do: Repo.all(from identity in CommitIdentity, order_by: identity.owner)

  def put(attrs, actor) do
    RepoTransaction.immediate(fn ->
      changeset = CommitIdentity.changeset(%CommitIdentity{}, attrs)
      unless changeset.valid?, do: Repo.rollback(changeset)
      owner = Ecto.Changeset.get_field(changeset, :owner)
      existing = Repo.get_by(CommitIdentity, owner: owner) || %CommitIdentity{}

      case existing |> CommitIdentity.changeset(attrs) |> Repo.insert_or_update() do
        {:ok, identity} ->
          audit!(identity, actor, "commit_identity.saved")
          identity

        {:error, invalid} ->
          Repo.rollback(invalid)
      end
    end)
    |> notify()
  end

  def delete(owner, actor) do
    RepoTransaction.immediate(fn ->
      case Repo.get_by(CommitIdentity, owner: owner) do
        nil ->
          Repo.rollback(:not_found)

        identity ->
          Repo.delete!(identity)
          audit!(identity, actor, "commit_identity.deleted")
          identity
      end
    end)
    |> notify()
  end

  def resolve(%Repository{github_owner: owner}) do
    identity =
      Repo.get_by(CommitIdentity, owner: String.downcase(owner)) ||
        Repo.get_by(CommitIdentity, owner: "")

    case identity do
      nil ->
        {:error,
         "No agent commit identity resolves for #{owner}. Configure a default or owner override on Configuration."}

      identity ->
        {:ok, identity}
    end
  end

  def resolve(repository_id) when is_integer(repository_id) do
    case Repo.get(Repository, repository_id) do
      nil -> {:error, "No repository exists for resolving the agent commit identity."}
      repository -> resolve(repository)
    end
  end

  def ensure(repository) do
    case resolve(repository) do
      {:ok, _identity} -> :ok
      error -> error
    end
  end

  def environment(repository_id, opts \\ []) do
    with {:ok, identity} <- resolve(repository_id) do
      variables =
        for role <- ["AUTHOR", "COMMITTER"],
            {field, value} <- [{"NAME", identity.name}, {"EMAIL", identity.email}],
            do: %{name: "GIT_#{role}_#{field}", value: value}

      # Identity wins over repository variables with the same Git names.
      names = Enum.map(variables, & &1.name)

      repository_variables =
        if Keyword.get(opts, :repository_variables, true),
          do: AgentEnvironmentVariables.list(repository_id),
          else: []

      {:ok, Enum.reject(repository_variables, &(&1.name in names)) ++ variables}
    end
  end

  def source(identity),
    do: if(identity.owner == "", do: "default", else: "owner override: #{identity.owner}")

  defp audit!(identity, actor, action) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: actor,
      action: action,
      target_type: "commit_identity",
      target_id: identity.id,
      details: %{"owner" => identity.owner, "name" => identity.name, "email" => identity.email}
    })
    |> Repo.insert!()
  end

  defp notify({:ok, result}) do
    Operations.notify_changed(__MODULE__)
    {:ok, result}
  end

  defp notify(error), do: error
end
