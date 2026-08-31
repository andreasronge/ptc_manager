defmodule PtcManager.Herdr do
  @moduledoc "Read-only boundary for observing agents in one configured Herdr session."

  @type snapshot :: %{
          required(:agents) => [map()],
          optional(:worker_incarnation_id) => String.t(),
          optional(:herdr_incarnation_id) => String.t(),
          optional(:snapshot_sequence) => non_neg_integer(),
          optional(:restart_reason) => String.t()
        }

  @callback list_agents() :: {:ok, [map()] | snapshot()} | {:error, term()}
end
