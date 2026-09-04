defmodule PtcManager.Operations.AgentEnvironmentVariable do
  use Ecto.Schema
  import Ecto.Changeset

  @name_format ~r/\A[A-Z_][A-Z0-9_]*\z/

  schema "agent_environment_variables" do
    field :name, :string
    field :value, PtcManager.EncryptedBinary, redact: true

    belongs_to :repository, PtcManager.Operations.Repository

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(variable, attrs) do
    variable
    |> cast(attrs, [:repository_id, :name, :value])
    |> validate_required([:repository_id, :name, :value])
    |> validate_format(:name, @name_format)
    |> validate_change(:name, &validate_unreserved_name/2)
    |> validate_change(:value, fn :value, value ->
      if String.contains?(value, <<0>>), do: [value: "cannot contain a null byte"], else: []
    end)
    |> foreign_key_constraint(:repository_id)
    |> unique_constraint([:repository_id, :name])
  end

  defp validate_unreserved_name(:name, name) do
    if name in ["PATH", "HOME", "CODEX_HOME"] or String.starts_with?(name, ["PTC_", "HERDR_"]) do
      [name: "is reserved"]
    else
      []
    end
  end
end
