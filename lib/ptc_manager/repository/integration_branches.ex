defmodule PtcManager.Repository.IntegrationBranches do
  @moduledoc """
  A repository's label → integration-branch mappings.

  An issue carrying an active mapping's label, or a member of a collection whose
  umbrella carries one, has its pull request target that branch instead of the
  default branch, and its issue stays open after the merge. Only the maintainer
  decides a mapping: a label and branch that merely share a name are offered as
  a suggestion, never routed on by themselves.

  GitHub matches label names case-insensitively, so every comparison here does
  too. Branch names are compared exactly, as git does.
  """

  import Ecto.Changeset

  alias PtcManager.GitHub.Ref
  alias PtcManager.Repository.MaintainerLabels

  @max_mappings 20
  @max_label_length 50
  @label_format ~r{\A[A-Za-z0-9 ._/:-]+\z}
  @suggested_prefix "feature/"

  @doc "Every configured mapping, each `%{\"label\", \"branch\", \"active\"}`."
  def list(%{integration_branches: %{"mappings" => mappings}}) when is_list(mappings),
    do: mappings

  def list(_repository), do: []

  def active(repository), do: Enum.filter(list(repository), & &1["active"])

  @doc """
  The branch an issue with these labels targets.

  `{:ok, nil}` means the default branch. Labels that map to two different
  branches are refused, since either choice would be a guess.
  """
  def resolve(repository, label_names) when is_list(label_names) do
    present = MapSet.new(label_names, &String.downcase/1)

    repository
    |> active()
    |> Enum.filter(&MapSet.member?(present, String.downcase(&1["label"])))
    |> Enum.uniq_by(& &1["branch"])
    |> case do
      [] -> {:ok, nil}
      [mapping] -> {:ok, mapping}
      conflicting -> {:error, {:conflicting_integration_branches, conflicting}}
    end
  end

  @doc """
  Labels GitHub reports for the repository that have a matching `feature/<label>`
  branch and no mapping yet.
  """
  def suggestions(repository) do
    mapped = MapSet.new(list(repository), &String.downcase(&1["label"]))
    branches = branch_names(repository)

    for label <- label_names(repository),
        not MaintainerLabels.reserved?(label),
        not MapSet.member?(mapped, String.downcase(label)),
        branch =
          Enum.find(
            branches,
            &(String.downcase(&1) == @suggested_prefix <> String.downcase(label))
          ),
        valid_label?(label),
        Ref.safe?(branch),
        do: %{"label" => label, "branch" => branch}
  end

  def label_names(%{github_label_names: %{"names" => names}}) when is_list(names), do: names
  def label_names(_repository), do: []

  def branch_names(%{github_branch_names: %{"names" => names}}) when is_list(names), do: names
  def branch_names(_repository), do: []

  @doc "The stored shape with one active mapping added, or why it was refused."
  def add(repository, label, branch) do
    label = String.trim(to_string(label))
    branch = String.trim(to_string(branch))

    cond do
      not valid_label?(label) -> {:error, :invalid_label_name}
      MaintainerLabels.reserved?(label) -> {:error, :reserved_label_name}
      not Ref.safe?(branch) -> {:error, :invalid_branch}
      mapped?(repository, label) -> {:error, :label_already_mapped}
      length(list(repository)) >= @max_mappings -> {:error, :too_many_mappings}
      true -> {:ok, stored(list(repository) ++ [mapping(label, branch, true)])}
    end
  end

  @doc "The stored shape with one mapping switched on or off; its entry stays."
  def set_active(repository, label, active) when is_boolean(active) do
    downcased = String.downcase(label)

    repository
    |> list()
    |> Enum.map(fn mapping ->
      if String.downcase(mapping["label"]) == downcased,
        do: %{mapping | "active" => active},
        else: mapping
    end)
    |> stored()
  end

  @doc "The stored shape without one mapping."
  def remove(repository, label) do
    downcased = String.downcase(label)

    repository
    |> list()
    |> Enum.reject(&(String.downcase(&1["label"]) == downcased))
    |> stored()
  end

  def mapped?(repository, label) do
    downcased = String.downcase(label)
    Enum.any?(list(repository), &(String.downcase(&1["label"]) == downcased))
  end

  @doc "Refuses a stored shape a repository changeset must not accept."
  def validate(changeset) do
    validate_change(changeset, :integration_branches, fn :integration_branches, value ->
      case value do
        %{"mappings" => mappings} when is_list(mappings) ->
          if valid_mappings?(mappings),
            do: [],
            else: [
              integration_branches:
                "must be unique labels with a safe branch and an active flag, none starting with ptc:"
            ]

        _other ->
          [integration_branches: "must contain a mappings list"]
      end
    end)
  end

  defp mapping(label, branch, active),
    do: %{"label" => label, "branch" => branch, "active" => active}

  defp stored(mappings), do: %{"mappings" => mappings}

  defp valid_mappings?(mappings) do
    length(mappings) <= @max_mappings and Enum.all?(mappings, &valid_mapping?/1) and
      Enum.uniq_by(mappings, &String.downcase(&1["label"])) == mappings
  end

  defp valid_mapping?(%{"label" => label, "branch" => branch, "active" => active})
       when is_boolean(active) do
    valid_label?(label) and not MaintainerLabels.reserved?(label) and Ref.safe?(branch)
  end

  defp valid_mapping?(_mapping), do: false

  defp valid_label?(label) when is_binary(label),
    do:
      label != "" and String.length(label) <= @max_label_length and
        Regex.match?(@label_format, label)

  defp valid_label?(_label), do: false
end
