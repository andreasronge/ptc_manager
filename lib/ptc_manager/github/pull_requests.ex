defmodule PtcManager.GitHub.PullRequests do
  @moduledoc "Read-only boundary for canonical pull-request status reconciliation."

  @callback status(struct()) :: {:ok, map()} | {:retry, term()} | {:blocked, term()}
  @callback discover(struct()) :: {:ok, map()} | {:retry, term()} | {:blocked, term()}
  @callback list_open(struct()) :: {:ok, [map()]} | {:retry, term()} | {:blocked, term()}

  @optional_callbacks discover: 1, list_open: 1
end
