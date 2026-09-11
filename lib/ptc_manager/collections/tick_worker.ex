defmodule PtcManager.Collections.TickWorker do
  @moduledoc """
  The once-a-minute backstop for collection runs.

  Every event that matters also reconciles directly (a GitHub sync, a
  pull-request status change, a finished agent action). This tick catches the
  case where such a hook was missed, for example after a restart, and is
  gated on the operational mode inside `Collections.reconcile/1` itself.
  """

  use Oban.Worker, queue: :automations, max_attempts: 1, unique: [period: 30]

  @impl Oban.Worker
  def perform(_job) do
    PtcManager.Collections.reconcile_all()
    :ok
  end
end
