defmodule PtcManagerWeb.PeerController do
  @moduledoc "The read-only peer protocol: signed `GET`s between cluster members."

  use PtcManagerWeb, :controller

  alias PtcManagerWeb.PeerAuth

  def status(conn, _params),
    do: PeerAuth.send_signed(conn, 200, PtcManager.Cluster.Status.build())
end
