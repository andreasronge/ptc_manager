defmodule PtcManager.AgentEnvironmentVariables do
  @moduledoc "Manages write-only repository variables for implementation agents."

  import Ecto.Query
  import Ecto.Changeset, only: [get_change: 2]

  alias PtcManager.Operations
  alias PtcManager.Operations.{AgentEnvironmentVariable, AuditEvent}
  alias PtcManager.Repo
  alias PtcManager.RepoTransaction

  def list(repository_id) do
    AgentEnvironmentVariable
    |> where([variable], variable.repository_id == ^repository_id)
    |> order_by([variable], asc: variable.name)
    |> Repo.all()
  end

  def list_metadata(repository_id) do
    AgentEnvironmentVariable
    |> where([variable], variable.repository_id == ^repository_id)
    |> order_by([variable], asc: variable.name)
    |> select([variable], %{id: variable.id, name: variable.name, updated_at: variable.updated_at})
    |> Repo.all()
  end

  def put(repository_id, attrs, actor) when is_binary(actor) and actor != "" do
    attrs = Map.put(attrs, "repository_id", repository_id)
    changeset = AgentEnvironmentVariable.changeset(%AgentEnvironmentVariable{}, attrs)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    RepoTransaction.immediate(fn ->
      existed? =
        Repo.exists?(
          from variable in AgentEnvironmentVariable,
            where: variable.repository_id == ^repository_id and variable.name == ^attrs["name"]
        )

      case Repo.insert(changeset,
             on_conflict: [set: [value: get_change(changeset, :value), updated_at: now]],
             conflict_target: [:repository_id, :name],
             returning: true
           ) do
        {:ok, variable} ->
          audit!(
            actor,
            if(existed?,
              do: "repository.agent_environment_variable_rotated",
              else: "repository.agent_environment_variable_added"
            ),
            variable
          )

          variable

        {:error, invalid} ->
          Repo.rollback(invalid)
      end
    end)
    |> notify()
  end

  def delete(repository_id, id, actor) when is_binary(actor) and actor != "" do
    RepoTransaction.immediate(fn ->
      case Repo.get_by(AgentEnvironmentVariable, id: id, repository_id: repository_id) do
        nil ->
          Repo.rollback(:not_found)

        variable ->
          Repo.delete!(variable)
          audit!(actor, "repository.agent_environment_variable_deleted", variable)
          variable
      end
    end)
    |> notify()
  end

  defp audit!(actor, action, variable) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: actor,
      action: action,
      target_type: "repository",
      target_id: variable.repository_id,
      details: %{"name" => variable.name}
    })
    |> Repo.insert!()
  end

  defp notify({:ok, result}) do
    Operations.notify_changed(AgentEnvironmentVariable)
    {:ok, result}
  end

  defp notify(error), do: error
end
