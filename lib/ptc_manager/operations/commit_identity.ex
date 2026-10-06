defmodule PtcManager.Operations.CommitIdentity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "commit_identities" do
    field :owner, :string, default: ""
    field :name, :string
    field :email, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:owner, :name, :email], empty_values: [])
    |> update_change(:owner, &normalize_owner/1)
    |> update_change(:name, &trim/1)
    |> update_change(:email, &trim/1)
    |> require_owner()
    |> validate_required([:name, :email])
    |> validate_length(:name, min: 1)
    |> validate_format(:owner, ~r/\A(?:[a-z0-9]+(?:-[a-z0-9]+)*)?\z/)
    |> validate_length(:owner, max: 39)
    |> validate_format(:email, ~r/\A[^\s@<>]+@[^\s@<>]+\z/)
    |> validate_change(:name, fn :name, value ->
      if String.contains?(value, ["\n", "\r", <<0>>, "<", ">"]),
        do: [name: "must be a single Git identity name"],
        else: []
    end)
    |> validate_change(:email, fn :email, value ->
      if String.contains?(value, <<0>>), do: [email: "cannot contain a null byte"], else: []
    end)
    |> unique_constraint(:owner)
  end

  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)
  defp normalize_owner(nil), do: nil
  defp normalize_owner(value), do: value |> String.trim() |> String.downcase()

  defp require_owner(changeset) do
    if is_nil(get_field(changeset, :owner)),
      do: add_error(changeset, :owner, "cannot be null"),
      else: changeset
  end
end
