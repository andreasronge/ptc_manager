defmodule PtcManager.MaintainerActions.Adapter do
  @moduledoc "Boundary for running one authorized maintainer-action prompt."

  alias PtcManager.Operations.AgentAction

  @callback run(AgentAction.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Answers whether this adapter could run the action at all.

  Preflight reserves a repair worktree before the adapter runs. An action that
  can never start would otherwise take that reservation, fail, and leave it held
  with no live attempt, so every later action on the same pull request stops at
  preflight instead of reporting what is actually missing. An adapter that can
  fail for a reason preflight could have seen implements this; the rest do not.
  """
  @callback ensure_ready(AgentAction.t()) :: :ok | {:error, term()}

  @optional_callbacks ensure_ready: 1
end
