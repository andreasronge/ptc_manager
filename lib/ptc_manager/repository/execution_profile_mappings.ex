defmodule PtcManager.Repository.ExecutionProfileMappings do
  @moduledoc "Repository label suggestions for execution presets; approval freezes the choice."
  import Ecto.Changeset
  alias PtcManager.ExecutionProfiles
  alias PtcManager.Repository.MaintainerLabels

  def list(%{execution_profile_mappings: %{"mappings" => mappings}}), do: mappings
  def list(_), do: []

  def resolve(repository, labels) do
    present = MapSet.new(labels, &String.downcase/1)

    matched =
      Enum.filter(list(repository), &MapSet.member?(present, String.downcase(&1["label"])))

    case Enum.uniq_by(matched, & &1["profile"]) do
      [] -> {:ok, nil}
      [%{"profile" => profile}] -> {:ok, profile}
      _ -> {:error, matched}
    end
  end

  def preselected(repository, issue, proposal) do
    case resolve(repository, MaintainerLabels.reported_names(issue)) do
      {:ok, profile} -> profile || ExecutionProfiles.suggested(proposal)
      {:error, _} -> ExecutionProfiles.suggested(proposal)
    end
  end

  def add(repository, label, profile) do
    label = String.trim(to_string(label))
    mappings = list(repository)

    cond do
      MaintainerLabels.reserved?(label) ->
        {:error, :reserved_label_name}

      not MaintainerLabels.valid_name?(label) ->
        {:error, :invalid_label_name}

      profile not in ExecutionProfiles.names() ->
        {:error, :invalid_execution_profile}

      Enum.any?(mappings, &(String.downcase(&1["label"]) == String.downcase(label))) ->
        {:error, :label_already_mapped}

      length(mappings) >= 20 ->
        {:error, :too_many_mappings}

      true ->
        {:ok, %{"mappings" => mappings ++ [%{"label" => label, "profile" => profile}]}}
    end
  end

  def remove(repository, label) do
    %{
      "mappings" =>
        Enum.reject(list(repository), &(String.downcase(&1["label"]) == String.downcase(label)))
    }
  end

  def validate(changeset) do
    changeset
    |> validate_required([:execution_profile_mappings])
    |> validate_change(:execution_profile_mappings, fn field, value ->
      if valid?(value),
        do: [],
        else: [
          {field,
           "must contain at most 20 unique labels mapped to execution presets, none starting with ptc:"}
        ]
    end)
  end

  defp valid?(%{"mappings" => mappings}) when is_list(mappings) do
    length(mappings) <= 20 and Enum.all?(mappings, &valid_mapping?/1) and
      Enum.uniq_by(mappings, &String.downcase(&1["label"])) == mappings
  end

  defp valid?(_), do: false

  defp valid_mapping?(%{"label" => label, "profile" => profile}) do
    MaintainerLabels.valid_name?(label) and not MaintainerLabels.reserved?(label) and
      profile in ExecutionProfiles.names()
  end

  defp valid_mapping?(_), do: false
end
