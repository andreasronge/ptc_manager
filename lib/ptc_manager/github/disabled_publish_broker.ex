defmodule PtcManager.GitHub.DisabledPublishBroker do
  @moduledoc false
  @behaviour PtcManager.GitHub.PublishBroker

  @impl true
  def publish(_publication), do: {:blocked, :github_publishing_not_configured}

  @impl true
  def status(_publication), do: {:blocked, :github_publishing_not_configured}
end
