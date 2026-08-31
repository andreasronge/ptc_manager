defmodule PtcManager.Clock do
  @moduledoc "Injectable wall clock for deterministic coordinator decisions."

  alias PtcManager.Gateway

  @callback utc_now() :: DateTime.t()

  def utc_now(clock) do
    clock
    |> Gateway.call(:utc_now, [])
    |> DateTime.truncate(:microsecond)
  end
end
