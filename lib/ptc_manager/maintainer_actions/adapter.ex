defmodule PtcManager.MaintainerActions.Adapter do
  @moduledoc "Boundary for running one authorized maintainer-action prompt."

  alias PtcManager.Operations.AgentAction

  @callback run(AgentAction.t()) :: {:ok, map()} | {:error, term()}
end
