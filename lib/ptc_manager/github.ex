defmodule PtcManager.GitHub do
  @moduledoc """
  Read-only boundary for fetching canonical GitHub issue snapshots.

  Implementations expose no mutation operation. A configured token should be a
  fine-grained token with read-only metadata, issues, pull requests, commit
  statuses, and checks permissions.
  """

  alias PtcManager.Operations.Repository

  @callback list_open_issues(Repository.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_issue(Repository.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
end
