defmodule PtcManager.Repo.Migrations.ReclassifyObservedAgentRuns do
  use Ecto.Migration

  alias PtcManager.Operations.AgentRun

  # Herdr.Sync used to record every pane it saw as an implementer (or by its
  # name as a manager or reviewer), so a maintainer's own interactive pane
  # held deployment drains. Panes no job or action owns are now observed.
  def up do
    execute(fn -> AgentRun.reclassify_unowned(repo()) end)
  end

  def down, do: :ok
end
