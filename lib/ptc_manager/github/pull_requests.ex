defmodule PtcManager.GitHub.PullRequests do
  @moduledoc "Read-only boundary for canonical pull-request status reconciliation."

  @callback status(struct()) :: {:ok, map()} | {:retry, term()} | {:blocked, term()}
end
