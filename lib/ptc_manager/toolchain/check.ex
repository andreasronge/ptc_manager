defmodule PtcManager.Toolchain.Check do
  use Ecto.Schema
  import Ecto.Changeset

  schema "toolchain_checks" do
    field :program, :string
    field :version, :string
    field :status, :string
    field :error, :string
    field :digest, :string
    field :protocol, :integer
    field :checked_at, :utc_datetime_usec
  end

  def changeset(check, attrs) do
    check
    |> cast(attrs, [:program, :version, :status, :error, :digest, :protocol, :checked_at])
    |> validate_required([:program, :status, :checked_at])
    |> validate_inclusion(:status, ["ok", "failed"])
    |> unique_constraint(:program)
  end
end
