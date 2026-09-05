defmodule PtcManager.ExecutionProfiles do
  @moduledoc "Maintainer-owned execution presets, frozen into each implementation approval."
  alias PtcManager.{Repo, RepoTransaction, AgentProfiles, Operations}
  alias PtcManager.ExecutionProfiles.Profile
  alias PtcManager.Operations.AuditEvent

  def list do
    profiles = Repo.all(Profile)
    Enum.map(~w(small standard strong), fn name -> Enum.find(profiles, &(&1.name == name)) end)
  end

  def suggested(%{scope: "large"}), do: "strong"
  def suggested(%{risk: "high"}), do: "strong"
  def suggested(%{scope: "small", risk: "low"}), do: "small"
  def suggested(_assessment), do: "standard"

  def save(name, attrs, actor) do
    RepoTransaction.immediate(fn ->
      profile = Repo.get_by!(Profile, name: name)

      case profile |> Profile.changeset(Map.put(attrs, "name", name)) |> Repo.update() do
        {:ok, saved} ->
          audit(actor, "execution_profile.updated", saved.id, %{name: name}, "execution_profile")
          saved

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def freeze(proposal, choice, budget) do
    name = choice || suggested(proposal)

    with %Profile{} = profile <- Repo.get_by(Profile, name: name),
         {:ok, _} <-
           AgentProfiles.select(%{"mode" => "require", "preferred_kind" => profile.kind}),
         {:ok, _} <-
           AgentProfiles.select(%{"mode" => "require", "preferred_kind" => profile.reviewer_kind}) do
      settings =
        profile
        |> Map.from_struct()
        |> Map.take([
          :name,
          :kind,
          :model,
          :effort,
          :reviewer_kind,
          :reviewer_model,
          :reviewer_effort
        ])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, settings, budget || profile.max_reviews}
    else
      nil -> {:error, :execution_profile_missing}
      error -> error
    end
  end

  def audit(actor, action, id, details, target_type \\ "job") do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      actor: actor,
      action: action,
      target_type: target_type,
      target_id: id,
      details: details
    })
    |> Repo.insert!()
  end

  def notify, do: Operations.notify_changed(__MODULE__)
end
