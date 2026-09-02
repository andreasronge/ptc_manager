defmodule PtcManager.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    PtcManager.RuntimeIncarnation.initialize()

    children = [
      PtcManagerWeb.Telemetry,
      PtcManager.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ptc_manager, :ecto_repos), skip: skip_migrations?()},
      PtcManager.CapacitySettings,
      PtcManager.Automations.Bootstrap,
      {Oban, Application.fetch_env!(:ptc_manager, Oban)},
      PtcManager.Repository.StartupPreflight,
      {DNSCluster, query: Application.get_env(:ptc_manager, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: PtcManager.PubSub},
      {Task.Supervisor, name: PtcManager.TaskSupervisor},
      PtcManager.MachineUsage.Sampler,
      PtcManager.DeploymentCoordinator,
      PtcManager.ResourceOperationBroker,
      maintainer_action_supervisor(),
      PtcManager.GitHub.Poller,
      PtcManager.Herdr.Poller,
      PtcManager.Dispatch.Poller,
      PtcManager.WorktreePoller,
      PtcManager.ResultPoller,
      PtcManager.PublisherPoller,
      PtcManager.PublicationStatusPoller,
      # Start a worker by calling: PtcManager.Worker.start_link(arg)
      # {PtcManager.Worker, arg},
      # Start to serve requests, typically the last entry
      PtcManagerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PtcManager.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maintainer_action_supervisor do
    children =
      for lane <- [:planning, :writing], index <- 1..8 do
        {PtcManager.MaintainerActions.Poller, lane: lane, index: index}
      end

    %{
      id: PtcManager.MaintainerActions.Supervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: PtcManager.MaintainerActions.Supervisor]]}
    }
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PtcManagerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
