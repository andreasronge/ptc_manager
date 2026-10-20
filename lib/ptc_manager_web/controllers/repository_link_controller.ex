defmodule PtcManagerWeb.RepositoryLinkController do
  @moduledoc """
  Resolves a repository by `owner/name` on this console. Record ids are local
  to each machine, so links between members (the machine switcher, the
  Cluster page) name repositories this way.
  """

  use PtcManagerWeb, :controller

  alias PtcManager.Cluster.Claims
  alias PtcManager.Operations

  def show(conn, %{"owner" => owner, "name" => name}) do
    key = Claims.key(owner, name)

    case Enum.find(Operations.list_repositories(), &(Claims.key(&1) == key)) do
      nil ->
        conn
        |> put_flash(:error, "#{owner}/#{name} is not configured on this machine.")
        |> redirect(to: ~p"/cluster")

      repository ->
        redirect(conn, to: ~p"/configuration/repositories/#{repository.id}")
    end
  end
end
