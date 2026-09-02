defmodule PtcManager.Deployments.Runner do
  @moduledoc "Boundary that hands a typed deployment to a process outside the web release."

  alias PtcManager.Deployments.Deployment
  alias PtcManager.Repository.Contract

  @callback start(Deployment.t(), Contract.t()) :: :ok | {:error, term()}
end
