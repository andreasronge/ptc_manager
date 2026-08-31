defmodule PtcManager.Clock.System do
  @moduledoc "Production wall clock."

  @behaviour PtcManager.Clock

  @impl true
  def utc_now, do: DateTime.utc_now()
end
