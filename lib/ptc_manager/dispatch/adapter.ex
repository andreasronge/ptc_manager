defmodule PtcManager.Dispatch.Adapter do
  @moduledoc "Boundary that starts one already-leased implementation attempt."

  @callback dispatch(map()) :: {:ok, map()} | {:error, term()}
  @callback remove_worktree(struct()) :: :ok | {:error, term()}
end
