defmodule PtcManager.GitHub.IssueLabels do
  @moduledoc """
  Adds or removes one configured maintainer label on one GitHub issue.

  GitHub stays the source of truth: the write goes out through the wrapper, and
  PtcManager then re-synchronizes the issue rather than editing its own copy.
  """

  alias PtcManager.GitHub.IssueLabelWriter
  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Operations
  alias PtcManager.Operations.{Issue, Repository}
  alias PtcManager.Repository.MaintainerLabels

  @doc """
  Toggles `name` on `issue` and returns `{:ok, :added | :removed}`.

  The name must be one the maintainer configured for this repository, so a
  defect cannot turn an arbitrary string into a GitHub write, and the three
  `ptc:` labels stay a read-only projection.
  """
  def toggle(%Repository{} = repository, %Issue{} = issue, name, actor)
      when is_binary(name) and is_binary(actor) and actor != "" do
    with :ok <- allowed?(repository, name),
         :ok <- open?(issue) do
      operation = if name in MaintainerLabels.reported_names(issue), do: :remove, else: :add
      write(repository, issue, operation, name, actor)
    end
  end

  defp write(repository, issue, operation, name, actor) do
    full_name = "#{repository.github_owner}/#{repository.github_name}"
    before = Operations.issue_restamp_snapshot(issue)

    case IssueLabelWriter.current().write(full_name, issue.number, operation, name) do
      :ok ->
        Operations.record_issue_label_change(issue, operation, name, actor)
        GitHubSync.sync_issue(repository, issue.number)
        Operations.restamp_proposal_after_label_change(issue.id, before, actor)
        {:ok, if(operation == :add, do: :added, else: :removed)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed?(repository, name) do
    cond do
      String.starts_with?(name, "ptc:") -> {:error, :reserved_label_name}
      MaintainerLabels.configured?(repository, name) -> :ok
      true -> {:error, :label_not_configured}
    end
  end

  defp open?(%Issue{state: "open"}), do: :ok
  defp open?(%Issue{}), do: {:error, :issue_closed}
end
