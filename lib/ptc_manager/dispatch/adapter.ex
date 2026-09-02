defmodule PtcManager.Dispatch.Adapter do
  @moduledoc "Boundary that starts one already-leased implementation attempt."

  @callback dispatch(map()) :: {:ok, map()} | {:error, term()}
  @callback remove_worktree(struct()) :: :ok | {:error, term()}
  @doc "Removes a retained worktree even when it holds uncommitted work."
  @callback discard_worktree(struct()) :: :ok | {:error, term()}

  @optional_callbacks discard_worktree: 1
end
