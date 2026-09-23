defmodule PtcManager.GitHub.SyncRevision do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "github_sync_state_revisions" do
    field :revision, :integer
  end
end
