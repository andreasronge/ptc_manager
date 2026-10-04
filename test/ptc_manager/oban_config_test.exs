defmodule PtcManager.ObanConfigTest do
  use ExUnit.Case, async: true

  test "production prunes finished jobs so the every-minute cron rows stay bounded" do
    oban_config =
      "config/config.exs"
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:ptc_manager)
      |> Keyword.fetch!(Oban)
      |> Oban.Config.new()

    assert {Oban.Pruner, pruner_opts} = List.keyfind(oban_config.plugins, Oban.Pruner, 0)
    assert pruner_opts[:max_age] == {7, :days}
    assert pruner_opts[:limit] <= 1_000
  end
end
