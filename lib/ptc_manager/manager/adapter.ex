defmodule PtcManager.Manager.Adapter do
  @moduledoc "Boundary for producing a private, non-authoritative issue analysis."

  alias PtcManager.Operations.Issue

  @callback analyze(Issue.t()) :: {:ok, map()} | {:error, term()}
end
