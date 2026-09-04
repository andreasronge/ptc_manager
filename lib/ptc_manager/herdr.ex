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

  @doc """
  Closes one Herdr pane so a maintainer can end an agent that is still running.

  This is the single control action PtcManager performs; it observes agents
  otherwise. Only the deterministic cancel path uses it, and the bookkeeping is
  already committed before the pane is asked to close.
  """
  @callback close_pane(pane_id :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks close_pane: 1
end
