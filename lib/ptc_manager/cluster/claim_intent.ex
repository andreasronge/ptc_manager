defmodule PtcManager.Cluster.ClaimIntent do
  @moduledoc """
  A member's announced intent to claim a repository, written before it asks
  its peers and deleted when the claim completes or is refused. Peers that see
  it refuse their own claim on the same repository.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cluster_claim_intents" do
    field :repository_key, :string
    field :token, :string
    field :actor, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [:repository_key, :token, :actor, :expires_at])
    |> validate_required([:repository_key, :token, :actor, :expires_at])
    |> unique_constraint(:repository_key)
  end
end
