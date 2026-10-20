defmodule PtcManagerWeb.PeerController do
  @moduledoc "The read-only peer protocol: signed `GET`s between cluster members."

  use PtcManagerWeb, :controller

  alias PtcManager.Cluster.{Claims, RepositorySettings}
  alias PtcManager.Operations.Repository
  alias PtcManager.Repo
  alias PtcManagerWeb.PeerAuth

  def status(conn, _params),
    do: PeerAuth.send_signed(conn, 200, PtcManager.Cluster.Status.build())

  @doc """
  The transferable settings of a repository this member has disabled and no
  longer claims; refused while any claim condition remains.
  """
  def settings(conn, %{"owner" => owner, "name" => name}) do
    key = Claims.key(owner, name)

    {:ok, {status, document}} =
      Repo.transaction(fn ->
        case Enum.find(Repo.all(Repository), &(Claims.key(&1) == key)) do
          nil ->
            {404, %{"error" => "not_configured"}}

          repository ->
            case Claims.local(repository) do
              %{state: "none"} ->
                {200, RepositorySettings.export(repository)}

              %{state: state, blockers: blockers} ->
                {409, %{"error" => "claimed", "claim" => state, "claim_blockers" => blockers}}
            end
        end
      end)

    PeerAuth.send_signed(conn, status, document)
  end
end
