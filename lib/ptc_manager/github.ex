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

  @doc """
  The branch names that exist in one repository.

  The repository page suggests a label → integration-branch mapping when a
  label `x` has a `feature/x` branch; it never routes on that match by itself.
  """
  @callback list_branches(Repository.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Whether one branch exists, checked when a mapping is saved and before dispatch."
  @callback branch_exists?(Repository.t(), String.t()) :: {:ok, boolean()} | {:error, term()}

  @optional_callbacks get_repository: 2,
                      viewer_login: 0,
                      list_labels: 1,
                      review_context: 2,
                      list_branches: 1,
                      branch_exists?: 2
end
