defmodule PtcManager.Repository.BranchPrefixes do
  @moduledoc """
  A repository's implementation branch prefix and its label → prefix mappings.

  An implementation job's branch is `<prefix>issue-<n>-job-<id>`. The prefix is
  the repository default unless one of the issue's own labels maps to another;
  a maintainer approving in the console may pick any configured prefix. The job
  stores its prefix at approval, so a later change here never renames work that
  is already approved.

  Only mapped labels count: a label that merely looks like a prefix routes
  nothing. Labels compare case-insensitively, as GitHub matches them; prefixes
  compare exactly, as git does.
  """

  import Ecto.Changeset

  alias PtcManager.GitHub.Ref
  alias PtcManager.Repository.MaintainerLabels

  @legacy_prefix "ptc-manager/"
  @max_mappings 20
  @max_prefix_bytes 64
  @segment ~r{\A[A-Za-z0-9][A-Za-z0-9._-]*\z}
  @ambiguous_roots ~w(refs origin head remotes)

  @doc "The prefix every repository and job had before prefixes were configurable."
  def legacy_prefix, do: @legacy_prefix

  @doc "The repository's default prefix."
  def default(%{branch_prefixes: %{"default" => prefix}}) when is_binary(prefix), do: prefix
  def default(_repository), do: @legacy_prefix

  @doc "Every configured mapping, each `%{\"label\", \"prefix\"}`."
  def list(%{branch_prefixes: %{"mappings" => mappings}}) when is_list(mappings), do: mappings
  def list(_repository), do: []

  @doc "The prefixes a maintainer may choose at approval: the default, then each mapped one."
  def choices(repository) do
    Enum.uniq([default(repository) | Enum.map(list(repository), & &1["prefix"])])
  end

  @doc """
  The prefix an issue with these labels gets.

  Labels that map to two different prefixes are a conflict; the error carries
  every matched mapping, so the audit can name each label involved.
  """
  def resolve(repository, label_names) when is_list(label_names) do
    present = MapSet.new(label_names, &String.downcase/1)

    matched =
      Enum.filter(list(repository), &MapSet.member?(present, String.downcase(&1["label"])))

    case Enum.uniq_by(matched, & &1["prefix"]) do
      [] -> {:ok, default(repository)}
      [%{"prefix" => prefix}] -> {:ok, prefix}
      _conflicting -> {:error, {:conflicting_branch_prefixes, matched}}
    end
  end

  @doc "The branch an implementation job gets, or why its prefix is refused."
  def branch_name(prefix, issue_number, job_id)
      when is_integer(issue_number) and is_integer(job_id) do
    if valid_prefix?(prefix),
      do: {:ok, "#{prefix}issue-#{issue_number}-job-#{job_id}"},
      else: {:error, :invalid_branch_prefix}
  end

  def branch_name(_prefix, _issue_number, _job_id), do: {:error, :invalid_branch_prefix}

  @doc """
  Whether a prefix is one to three safe path segments, each followed by `/`.

  The trailing slash keeps `issue-<n>-job-<id>` its own segment. A first
  segment git could read as a ref namespace or remote is refused.
  """
  def valid_prefix?(prefix)
      when is_binary(prefix) and byte_size(prefix) in 2..@max_prefix_bytes do
    segments = prefix |> binary_part(0, byte_size(prefix) - 1) |> String.split("/")

    String.ends_with?(prefix, "/") and length(segments) in 1..3 and
      Enum.all?(segments, &valid_segment?/1) and
      String.downcase(hd(segments)) not in @ambiguous_roots and
      Ref.safe?(prefix <> "issue-1-job-1")
  end

  def valid_prefix?(_prefix), do: false

  @doc """
  The cached GitHub branch that would make this prefix impossible to create.

  Git cannot hold both `team/bugfix` and `team/bugfix/issue-1-job-1`, so every
  ancestor of the prefix is checked. The list is a cached projection: a miss
  here can still fail at push time, as an ordinary failed job.
  """
  def colliding_branch(repository, prefix) when is_binary(prefix) do
    branches = MapSet.new(PtcManager.Repository.IntegrationBranches.branch_names(repository))

    prefix
    |> String.trim_trailing("/")
    |> String.split("/")
    |> Enum.scan(&"#{&2}/#{&1}")
    |> Enum.find(&MapSet.member?(branches, &1))
  end

  @doc "The stored shape with a new default prefix, or why it was refused."
  def set_default(repository, prefix) do
    prefix = String.trim(to_string(prefix))

    if valid_prefix?(prefix),
      do: {:ok, stored(prefix, list(repository))},
      else: {:error, :invalid_branch_prefix}
  end

  @doc "The stored shape with one mapping added, or why it was refused."
  def add(repository, label, prefix) do
    label = String.trim(to_string(label))
    prefix = String.trim(to_string(prefix))

    cond do
      MaintainerLabels.reserved?(label) -> {:error, :reserved_label_name}
      not MaintainerLabels.valid_name?(label) -> {:error, :invalid_label_name}
      not valid_prefix?(prefix) -> {:error, :invalid_branch_prefix}
      mapped?(repository, label) -> {:error, :label_already_mapped}
      length(list(repository)) >= @max_mappings -> {:error, :too_many_mappings}
      true -> {:ok, stored(default(repository), list(repository) ++ [mapping(label, prefix)])}
    end
  end

  @doc "The stored shape without one mapping."
  def remove(repository, label) do
    downcased = String.downcase(label)

    stored(
      default(repository),
      Enum.reject(list(repository), &(String.downcase(&1["label"]) == downcased))
    )
  end

  def mapped?(repository, label) do
    downcased = String.downcase(label)
    Enum.any?(list(repository), &(String.downcase(&1["label"]) == downcased))
  end

  @doc "Refuses a stored shape a repository changeset must not accept."
  def validate(changeset) do
    validate_change(changeset, :branch_prefixes, fn :branch_prefixes, value ->
      case value do
        %{"default" => default, "mappings" => mappings} when is_list(mappings) ->
          if valid_prefix?(default) and valid_mappings?(mappings),
            do: [],
            else: [
              branch_prefixes:
                "must be a safe default prefix and unique labels each with a safe prefix, none starting with ptc:"
            ]

        _other ->
          [branch_prefixes: "must contain a default prefix and a mappings list"]
      end
    end)
  end

  defp mapping(label, prefix), do: %{"label" => label, "prefix" => prefix}

  defp stored(default, mappings), do: %{"default" => default, "mappings" => mappings}

  defp valid_mappings?(mappings) do
    length(mappings) <= @max_mappings and Enum.all?(mappings, &valid_mapping?/1) and
      Enum.uniq_by(mappings, &String.downcase(&1["label"])) == mappings
  end

  defp valid_mapping?(%{"label" => label, "prefix" => prefix}) do
    MaintainerLabels.valid_name?(label) and not MaintainerLabels.reserved?(label) and
      valid_prefix?(prefix)
  end

  defp valid_mapping?(_mapping), do: false

  defp valid_segment?(segment) do
    Regex.match?(@segment, segment) and not String.ends_with?(segment, [".", ".lock"]) and
      not String.contains?(segment, "..")
  end
end
