defmodule PtcManager.Repo do
  use Ecto.Repo,
    otp_app: :ptc_manager,
    adapter: PtcManager.Repo.Adapter

  # SQLite has one writer. A deferred transaction that reads and then writes is
  # refused outright once another connection has committed in between, so every
  # transaction takes the write lock up front, where a waiting writer retries
  # instead of failing. See `PtcManager.RepoTransaction` and
  # `PtcManager.Repo.Adapter`.
  @impl true
  def default_options(:transaction), do: [mode: :immediate]
  def default_options(_operation), do: []
end
