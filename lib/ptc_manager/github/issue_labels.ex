defmodule PtcManager.GitHub.IssueLabels do
  @moduledoc """
  Adds or removes one configured maintainer label on one GitHub issue.

  GitHub stays the source of truth: the write goes out through the wrapper, and
  PtcManager then re-synchronizes the issue rather than editing its own copy.

  A label write is GitHub activity like any other, so it moves the issue's
  `updated_at` and makes the latest analysis stale. PtcManager deliberately does
  not paper over that: a comment posted in the same second would be
  indistinguishable, and blessing an analysis written before it would let
  dispatch act on a question nobody had read. "Fix directly" exists for the case
  where another preparation round is not wanted.
  """

  alias PtcManager.GitHub.IssueLabelWriter
  alias PtcManager.GitHub.Sync, as: GitHubSync
  alias PtcManager.Operations
  alias PtcManager.Operations.{Issue, Repository}
  alias PtcManager.Repository.MaintainerLabels

  @doc """
  Toggles `name` on `issue`.

  Returns `{:ok, :added | :removed}`, or `{:ok, operation, {:sync_failed,
  reason}}` when GitHub accepted the write but PtcManager could not read the
  issue back. The name must be one the maintainer configured for this
  repository, so a defect cannot turn an arbitrary string into a GitHub write,
  and the three `ptc:` labels stay a read-only projection whatever their casing.
  """
  def toggle(%Repository{} = repository, %Issue{} = issue, name, actor)
      when is_binary(name) and is_binary(actor) and actor != "" do
    with :ok <- allowed?(repository, name),
         :ok <- open?(issue) do
      operation = if MaintainerLabels.reported?(issue, name), do: :remove, else: :add
      write(repository, issue, operation, name, actor)
    end
  end

  defp write(repository, issue, operation, name, actor) do
    full_name = "#{repository.github_owner}/#{repository.github_name}"

    case IssueLabelWriter.current().write(full_name, issue.number, operation, name) do
      :ok ->
        Operations.record_issue_label_change(issue, operation, name, actor)
        outcome = if operation == :add, do: :added, else: :removed

        # The write already happened on GitHub. A failed re-read is reported so
        # the console can say the local copy is behind, never as a failed write.
        case GitHubSync.sync_issue(repository, issue.number) do
          {:ok, _summary} -> {:ok, outcome}
          {:error, reason} -> {:ok, outcome, {:sync_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp allowed?(repository, name) do
    cond do
      MaintainerLabels.reserved?(name) -> {:error, :reserved_label_name}
      MaintainerLabels.configured?(repository, name) -> :ok
      true -> {:error, :label_not_configured}
    end
  end

  defp open?(%Issue{state: "open"}), do: :ok
  defp open?(%Issue{}), do: {:error, :issue_closed}
end
