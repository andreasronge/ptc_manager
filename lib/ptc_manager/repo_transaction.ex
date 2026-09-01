defmodule PtcManager.RepoTransaction do
  @moduledoc false

  alias PtcManager.Repo

  def immediate(fun) when is_function(fun, 0) do
    Repo.transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if busy_begin?(error) do
        {:error, :database_busy}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp busy_begin?(error) do
    error.message == "database is locked" and
      String.starts_with?(error.statement || "", "BEGIN IMMEDIATE")
  end
end
