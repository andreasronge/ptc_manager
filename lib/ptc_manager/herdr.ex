defmodule PtcManager.Herdr do
  @moduledoc "Read-only boundary for observing agents in one configured Herdr session."

  @callback list_agents() :: {:ok, [map()]} | {:error, term()}
end
