defmodule PtcManager.GitHub do
  @moduledoc """
  Read-only boundary for fetching canonical GitHub issue snapshots.

  Implementations expose no mutation operation. A configured token should be a
  fine-grained token with read-only metadata, issues, pull requests, commit
  statuses, and checks permissions.
  """

  alias PtcManager.Operations.Repository

  @callback get_repository(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_open_issues(Repository.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_issue(Repository.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  @callback review_context(Repository.t(), {:issue, pos_integer()} | {:blob, String.t()}) ::
              {:ok, map()} | {:error, term()}

  @doc """
  The login of the account whose token PtcManager reads GitHub with.

  Planning marks an issue as external when its author is somebody else, so it
  has to know who "me" is. GitHub answers that from the token itself.
  """
  @callback viewer_login() :: {:ok, String.t()} | {:error, term()}

  @doc """
  The label names that exist in one repository.

  PtcManager never creates a label, and `gh` fails against one that does not
  exist, so Configuration reads them to say which are missing before a
  maintainer enables the repository.
  """
  @callback list_labels(Repository.t()) :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks get_repository: 2, viewer_login: 0, list_labels: 1, review_context: 2
end
