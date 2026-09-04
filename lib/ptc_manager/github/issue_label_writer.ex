defmodule PtcManager.GitHub.IssueLabelWriter do
  @moduledoc """
  The one narrow GitHub write PtcManager performs without an agent.

  A maintainer pressed a chip on a Planning card; a root-owned wrapper then runs
  `gh issue edit` as the worker to add or remove exactly one configured label.
  Nothing else about the issue can be changed through this boundary, and no
  model output ever reaches it.
  """

  @callback write(
              repository_full_name :: String.t(),
              number :: pos_integer(),
              operation :: :add | :remove,
              label :: String.t()
            ) :: :ok | {:error, term()}

  @doc "The configured writer for this environment."
  def current,
    do:
      Application.get_env(
        :ptc_manager,
        :issue_label_writer,
        PtcManager.GitHub.DisabledIssueLabelWriter
      )
end

defmodule PtcManager.GitHub.DisabledIssueLabelWriter do
  @moduledoc "Refuses every label write, for development, demo mode, and tests."

  @behaviour PtcManager.GitHub.IssueLabelWriter

  @impl true
  def write(_repository, _number, _operation, _label), do: {:error, :label_writes_disabled}
end

defmodule PtcManager.GitHub.WorkerIssueLabelWriter do
  @moduledoc """
  Runs the root-owned label wrapper as the Herdr worker account.

  The wrapper validates its own arguments as well, so a defect on either side
  fails closed rather than widening what `gh` may do.
  """

  @behaviour PtcManager.GitHub.IssueLabelWriter

  alias PtcManager.Repository.WorkerHelper

  @impl true
  def write(repository, number, operation, label)
      when is_binary(repository) and is_integer(number) and number > 0 and
             operation in [:add, :remove] and is_binary(label) do
    if WorkerHelper.worker_boundary?() do
      run([repository, Integer.to_string(number), Atom.to_string(operation), label])
    else
      {:error, :label_writes_disabled}
    end
  end

  defp run(args) do
    wrapper =
      Application.get_env(
        :ptc_manager,
        :issue_label_wrapper,
        "/usr/local/bin/ptc-manager-worker-gh-label"
      )

    timeout = Application.get_env(:ptc_manager, :issue_label_timeout_ms, 30_000)
    task = Task.async(fn -> WorkerHelper.run(wrapper, args) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_output, 0}} -> :ok
      # The wrapper's own output can quote a GitHub label or issue title, so only
      # its exit status crosses this boundary.
      {:ok, {_output, status}} -> {:error, {:label_wrapper_exit, status}}
      nil -> {:error, :label_wrapper_timeout}
    end
  end
end
