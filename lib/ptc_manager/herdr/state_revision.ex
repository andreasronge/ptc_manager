defmodule PtcManager.Herdr.StateRevision do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "herdr_state_revisions" do
    field :revision, :integer
  end
end
