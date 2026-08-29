defmodule PtcManager.Repo do
  use Ecto.Repo,
    otp_app: :ptc_manager,
    adapter: Ecto.Adapters.SQLite3
end
