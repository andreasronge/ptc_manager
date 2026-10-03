defmodule PtcManager.Repo do
  use Ecto.Repo,
    otp_app: :ptc_manager,
    adapter: Ecto.Adapters.SQLite3

  # SQLite has one writer. A deferred transaction that reads and then writes is
  # refused outright once another connection has committed in between, so every
  # transaction takes the write lock up front, where `busy_timeout` applies and
  # a waiting writer succeeds. See `PtcManager.RepoTransaction`.
  @impl true
  def default_options(:transaction), do: [mode: :immediate]
  def default_options(_operation), do: []
end
