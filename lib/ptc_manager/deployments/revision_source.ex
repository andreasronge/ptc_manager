defmodule PtcManager.Deployments.RevisionSource do
  @moduledoc "Boundary for resolving the current default-branch revision."

  alias PtcManager.Operations.Repository

  @callback latest(Repository.t()) :: {:ok, binary()} | {:error, term()}
end
