defmodule PtcManager.Deployments.Runner do
  @moduledoc "Boundary that hands a typed deployment to a process outside the web release."

  alias PtcManager.Deployments.Deployment
  alias PtcManager.Repository.Contract

  @callback start(Deployment.t(), Contract.t()) :: :ok | {:error, term()}
  @callback status(Deployment.t()) :: :active | :inactive | {:unknown, term()}
  @callback cleanup(Deployment.t()) :: :ok | {:error, term()}

  @optional_callbacks status: 1, cleanup: 1
end
