defmodule PtcManager.RepositoryContractFixture do
  @moduledoc false

  alias PtcManager.Repository.Contract

  def contract do
    %Contract{
      version: 1,
      bootstrap_command: "./scripts/ptc/bootstrap",
      bootstrap_timeout_minutes: 10,
      before_publish_command: "./scripts/ci/pre-publication",
      verification_timeout_minutes: 45
    }
  end
end
