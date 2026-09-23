defmodule PtcManager.Deployments.RevisionSource do
  @moduledoc "Boundary for resolving the current default-branch revision."

  alias PtcManager.Operations.Repository

  @callback latest(Repository.t()) :: {:ok, binary()} | {:error, term()}
  @callback contract(Repository.t(), binary()) :: {:ok, binary()} | {:error, term()}
  @callback content(Repository.t(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  @optional_callbacks contract: 2, content: 3
end
