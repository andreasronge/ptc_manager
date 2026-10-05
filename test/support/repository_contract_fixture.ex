defmodule PtcManager.RepositoryContractFixture do
  @moduledoc false

  alias PtcManager.Repository.Contract

  def contract do
    %Contract{
      version: 1,
      before_publish_command: "./scripts/ci/pre-publication",
      verification_timeout_minutes: 45
    }
  end

  @doc "The workspace setup `PtcManager.OperationsFixtures.repository_fixture/1` configures."
  def setup, do: %{command: "./scripts/ptc/bootstrap", timeout_minutes: 10}
end
