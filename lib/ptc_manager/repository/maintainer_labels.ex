defmodule PtcManager.Repository.MaintainerLabels do
  @moduledoc """
  The maintainer's own GitHub labels, per repository, and what each one means.

  A `badge` label is shown on the Planning card. A `park` label moves the issue
  into the Waiting group and changes nothing else: parking is a placement, never
  an approval gate. Names starting with `ptc:` are refused, because those three
  labels are PtcManager's own display projection and must keep coming only from
  GitHub synchronization.
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

  @doc "True when the maintainer configured this exact name for this repository."
  def configured?(repository, name), do: name in names(repository)

  @doc "The GitHub labels that are not configured here, for the expanded card."
  def unconfigured_on(repository, issue) do
    configured = MapSet.new(names(repository))
    Enum.reject(reported_names(issue), &MapSet.member?(configured, &1))
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
      String.starts_with?(name, "ptc:") -> {:error, :reserved_label_name}
      String.length(name) > @max_name_length -> {:error, :invalid_label_name}
      not Regex.match?(@name_format, name) -> {:error, :invalid_label_name}
      configured?(repository, name) -> {:error, :label_already_configured}
      length(list(repository)) >= @max_labels -> {:error, :too_many_labels}
      true -> {:ok, %{"labels" => list(repository) ++ [%{"name" => name, "role" => role}]}}
    end
  end

  @doc "The stored shape without one name."
  def remove(repository, name) do
    %{"labels" => Enum.reject(list(repository), &(&1["name"] == name))}
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
      Enum.uniq_by(labels, & &1["name"]) == labels
  end

  defp valid_label?(%{"name" => name, "role" => role})
       when is_binary(name) and is_binary(role) do
    role in @roles and name != "" and String.length(name) <= @max_name_length and
      not String.starts_with?(name, "ptc:") and Regex.match?(@name_format, name)
  end

  defp valid_label?(_label), do: false
end
