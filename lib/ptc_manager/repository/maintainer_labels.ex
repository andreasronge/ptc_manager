defmodule PtcManager.Repository.MaintainerLabels do
  @moduledoc """
  The maintainer's own GitHub labels, per repository, and what each one means.

  A `badge` label is shown on the Planning card. A `park` label moves the issue
  into the Waiting group and changes nothing else: parking is a placement, never
  an approval gate. Names starting with `ptc:` are refused, because those three
  labels are PtcManager's own display projection and must keep coming only from
  GitHub synchronization.

  GitHub matches label names case-insensitively, so every comparison here does
  too. Otherwise `PTC:ready` would be a configurable name that writes the
  protected `ptc:ready` label, turning a placement into a workflow-state change.
  """

  import Ecto.Changeset

  @roles ~w(badge park)
  @max_name_length 50
  @max_labels 20
  @name_format ~r{\A[A-Za-z0-9 ._/:-]+\z}

  def roles, do: @roles

  @doc "The configured entries, each `%{\"name\" => name, \"role\" => role}`."
  def list(%{maintainer_labels: %{"labels" => labels}}) when is_list(labels), do: labels
  def list(_repository), do: []

  def names(repository), do: Enum.map(list(repository), & &1["name"])
  def parked_names(repository), do: names_with_role(repository, "park")
  def badge_names(repository), do: names_with_role(repository, "badge")

  @doc "True when the maintainer configured this name for this repository."
  def configured?(repository, name) do
    downcased = String.downcase(name)
    Enum.any?(names(repository), &(String.downcase(&1) == downcased))
  end

  @doc "True when GitHub currently reports this label on this issue."
  def reported?(issue, name) do
    downcased = String.downcase(name)
    Enum.any?(reported_names(issue), &(String.downcase(&1) == downcased))
  end

  @doc "True when this name is one of PtcManager's own workflow labels."
  def reserved?(name), do: name |> String.downcase() |> String.starts_with?("ptc:")

  @doc "The GitHub labels that are not configured here, for the expanded card."
  def unconfigured_on(repository, issue) do
    configured = MapSet.new(names(repository), &String.downcase/1)
    Enum.reject(reported_names(issue), &MapSet.member?(configured, String.downcase(&1)))
  end

  @doc "Every label name GitHub last reported on this issue."
  def reported_names(%{github_labels: %{"names" => names}}) when is_list(names), do: names
  def reported_names(_issue), do: []

  @doc "The stored shape with `name` added, or an error explaining the refusal."
  def add(repository, name, role) do
    name = String.trim(to_string(name))

    cond do
      role not in @roles -> {:error, :invalid_label_role}
      name == "" -> {:error, :invalid_label_name}
      reserved?(name) -> {:error, :reserved_label_name}
      String.length(name) > @max_name_length -> {:error, :invalid_label_name}
      not Regex.match?(@name_format, name) -> {:error, :invalid_label_name}
      configured?(repository, name) -> {:error, :label_already_configured}
      length(list(repository)) >= @max_labels -> {:error, :too_many_labels}
      true -> {:ok, %{"labels" => list(repository) ++ [%{"name" => name, "role" => role}]}}
    end
  end

  @doc "The stored shape without one name."
  def remove(repository, name) do
    downcased = String.downcase(name)
    %{"labels" => Enum.reject(list(repository), &(String.downcase(&1["name"]) == downcased))}
  end

  @doc "Refuses a stored shape a repository changeset must not accept."
  def validate(changeset) do
    validate_change(changeset, :maintainer_labels, fn :maintainer_labels, value ->
      case value do
        %{"labels" => labels} when is_list(labels) ->
          if valid_labels?(labels),
            do: [],
            else: [
              maintainer_labels:
                "must be unique names of 1 to #{@max_name_length} characters with role badge or park, none starting with ptc:"
            ]

        _other ->
          [maintainer_labels: "must contain a labels list"]
      end
    end)
  end

  defp names_with_role(repository, role) do
    repository |> list() |> Enum.filter(&(&1["role"] == role)) |> Enum.map(& &1["name"])
  end

  defp valid_labels?(labels) do
    length(labels) <= @max_labels and Enum.all?(labels, &valid_label?/1) and
      Enum.uniq_by(labels, &String.downcase(&1["name"])) == labels
  end

  defp valid_label?(%{"name" => name, "role" => role})
       when is_binary(name) and is_binary(role) do
    role in @roles and name != "" and String.length(name) <= @max_name_length and
      not reserved?(name) and Regex.match?(@name_format, name)
  end

  defp valid_label?(_label), do: false
end
