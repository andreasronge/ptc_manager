defmodule PtcManagerWeb.OperatorController do
  @moduledoc "The operator read surface: the console's state and stalls as JSON."

  use PtcManagerWeb, :controller

  alias PtcManager.OperatorState

  def state(conn, _params), do: json(conn, OperatorState.snapshot())

  def stalls(conn, _params), do: json(conn, OperatorState.stalls())
end
