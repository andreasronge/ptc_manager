defmodule PtcManager.Deployments do
  @moduledoc "Coordinates exact-revision, out-of-process repository deployments."

  import Ecto.Query

  alias Ecto.Multi
  alias PtcManager.Deployments.{Deployment, ReleaseRevision}
  alias PtcManager.Operations.{AgentRun, AuditEvent, Repository}
  alias PtcManager.Repository.{Checkout, Contract, GitProbe}
  alias PtcManager.{Gateway, OperationalMode, Operations, Repo, RepoTransaction}

  @active_run_states ~w(queued starting working blocked unknown)
  @active_deployment_states ~w(queued draining starting running)
  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def request(%Repository{} = repository, actor) when is_binary(actor) and actor != "" do
    source = Application.fetch_env!(:ptc_manager, :deployment_revision_source)

    with true <- repository.enabled,
         {:ok, requested_sha} <- Gateway.call(source, :latest, [repository]),
         true <- valid_sha?(requested_sha),
         {:ok, contract} <- contract_at(source, repository, requested_sha),
         true <- Contract.deployment_configured?(contract),
         previous_sha <- current_sha(),
         {:ok, deployment} <-
           insert_request(repository, requested_sha, previous_sha, contract, actor),
         :ok <- enter_drain_or_fail(deployment) do
      PtcManager.DeploymentCoordinator.wake()
      {:ok, Repo.preload(deployment, :repository)}
    else
      false -> {:error, :deployment_not_available}
      {:error, reason} -> {:error, reason}
    end
  end

  def request(_repository, _actor), do: {:error, :invalid_deployment_request}

  def list_recent(limit \\ 20) do
    Deployment
    |> order_by([deployment], desc: deployment.requested_at, desc: deployment.id)
    |> limit(^limit)
    |> preload(:repository)
    |> Repo.all()
  end

  def active do
    Deployment
    |> where([deployment], deployment.state in ^@active_deployment_states)
    |> order_by([deployment], asc: deployment.requested_at, asc: deployment.id)
    |> preload(:repository)
    |> Repo.all()
  end

  def active_for_repository(repository_id) do
    Deployment
    |> where(
      [deployment],
      deployment.repository_id == ^repository_id and
        deployment.state in ^@active_deployment_states
    )
    |> preload(:repository)
    |> Repo.one()
  end

  def configured_repositories do
    Operations.list_repositories()
    |> Enum.filter(& &1.enabled)
    |> Enum.map(fn repository -> {repository, contract(repository)} end)
    |> Enum.filter(fn {_repository, result} ->
      match?({:ok, %Contract{} = contract} when contract.deployment_command != nil, result)
    end)
  end

  def update_status(%Repository{} = repository, latest_sha) do
    deployed = current_sha()

    %{
      repository: repository,
      deployed_sha: deployed,
      latest_sha: latest_sha,
      update_available?: is_binary(deployed) and is_binary(latest_sha) and deployed != latest_sha,
      current?: is_binary(deployed) and deployed == latest_sha,
      active_deployment: active_for_repository(repository.id)
    }
  end

  def advance do
    had_active_deployment = active() != []
    if had_active_deployment, do: ensure_active_deployment_drains()
    ingest_status_files()
    expire_stalled_deployments()

    case active() do
      [] ->
        if had_active_deployment, do: leave_deployment_drain()
        :idle

      deployments ->
        Enum.each(deployments, &advance/1)
        :ok
    end
  end

  defp advance(%Deployment{state: state} = deployment) when state in ~w(queued draining) do
    _ = OperationalMode.enter_draining()

    unless active_managed_runs?() do
      launch(deployment)
    end
  end

  defp advance(%Deployment{}), do: :ok

  defp launch(deployment) do
    runner = Application.fetch_env!(:ptc_manager, :deployment_runner)

    result =
      RepoTransaction.immediate(fn ->
        current = Deployment |> Repo.get!(deployment.id) |> Repo.preload(:repository)

        if current.state in ~w(queued draining) and not active_managed_runs?() do
          current
          |> Deployment.changeset(%{
            state: "starting",
            started_at: now(),
            status_text: "Safe window reached; handing deployment to the host runner."
          })
          |> Repo.update!()
        else
          :deferred
        end
      end)

    case result do
      {:ok, %Deployment{} = starting} ->
        case Gateway.call(runner, :start, [starting, frozen_contract(starting)]) do
          :ok ->
            transition(starting, %{
              state: "running",
              status_text: "The host runner is building and installing the exact revision."
            })

          {:error, reason} ->
            fail(starting, reason)
        end

      _deferred ->
        :ok
    end
  end

  defp ingest_status_files do
    Enum.each(active(), fn deployment ->
      case File.read(status_path(deployment.id)) do
        {:ok, content} -> ingest_status(deployment, content)
        {:error, :enoent} -> :ok
        {:error, reason} -> fail(deployment, {:deployment_status_unreadable, reason})
      end
    end)
  end

  defp ingest_status(deployment, content) do
    deployment_id = deployment.id
    requested_sha = deployment.requested_sha

    with {:ok, status} when is_map(status) <- Jason.decode(content),
         ^deployment_id <- status["deployment_id"],
         ^requested_sha <- status["requested_sha"],
         state when state in ["completed", "failed"] <- status["state"] do
      attrs = %{
        state: state,
        finished_at: now(),
        release_id: bounded(status["release_id"], 200),
        status_text: bounded(status["status_text"], 2_000),
        last_error: bounded(status["error"], 4_000)
      }

      case transition(deployment, attrs) do
        {:ok, _deployment} -> File.rm(status_path(deployment.id))
        {:error, _changeset} = error -> error
      end
    else
      _invalid -> fail(deployment, :invalid_deployment_status)
    end
  end

  defp fail(deployment, reason) do
    transition(deployment, %{
      state: "failed",
      finished_at: now(),
      status_text: "Deployment did not start or complete safely.",
      last_error: bounded(inspect(reason), 4_000)
    })

    {:error, reason}
  end

  defp transition(deployment, attrs) do
    result = deployment |> Deployment.changeset(attrs) |> Repo.update()
    Operations.notify_changed(__MODULE__)
    result
  end

  defp insert_request(repository, requested_sha, previous_sha, contract, actor) do
    requested_at = now()

    Multi.new()
    |> Multi.insert(
      :deployment,
      Deployment.changeset(%Deployment{}, %{
        repository_id: repository.id,
        requested_sha: requested_sha,
        previous_sha: previous_sha,
        state: "draining",
        requested_by: actor,
        requested_at: requested_at,
        status_text: "Waiting for managed agents to finish; new work is paused.",
        deployment_command: contract.deployment_command,
        deployment_timeout_minutes: contract.deployment_timeout_minutes
      })
    )
    |> Multi.insert(:audit_event, fn %{deployment: deployment} ->
      AuditEvent.changeset(%AuditEvent{}, %{
        actor: actor,
        action: "deployment.requested",
        target_type: "deployment",
        target_id: deployment.id,
        details: %{
          "repository_id" => repository.id,
          "requested_sha" => requested_sha,
          "previous_sha" => previous_sha
        }
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{deployment: deployment}} ->
        Operations.notify_changed(__MODULE__)
        {:ok, deployment}

      {:error, :deployment, changeset, _changes} ->
        if Keyword.has_key?(changeset.errors, :state),
          do: {:error, :deployment_already_requested},
          else: {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp enter_drain_or_fail(deployment) do
    case OperationalMode.enter_draining() do
      :ok -> :ok
      {:error, reason} -> fail(deployment, reason)
    end
  end

  defp active_managed_runs? do
    AgentRun
    |> where([run], run.state in ^@active_run_states)
    |> Repo.exists?()
  end

  defp contract(%Repository{} = repository) do
    with {:ok, path} <- Checkout.available_path(repository),
         {:ok, contract} <- Contract.load(path) do
      {:ok, contract}
    end
  end

  defp contract_at(source, %Repository{} = repository, sha) do
    probe = Application.get_env(:ptc_manager, :checkout_probe, GitProbe)

    with {:ok, content} <- contract_content(source, probe, repository, sha),
         {:ok, contract} <- Contract.parse(content) do
      {:ok, contract}
    end
  end

  defp contract_content(source, probe, repository, sha) do
    if gateway_exports?(source, :contract, 2) do
      Gateway.call(source, :contract, [repository, sha])
    else
      with {:ok, path} <- Checkout.available_path(repository) do
        Gateway.call(probe, :repository_contract, [path, sha])
      end
    end
  end

  defp frozen_contract(%Deployment{} = deployment) do
    %Contract{
      version: 1,
      bootstrap_command: nil,
      bootstrap_timeout_minutes: nil,
      deployment_command: deployment.deployment_command,
      deployment_timeout_minutes: deployment.deployment_timeout_minutes
    }
  end

  defp ensure_active_deployment_drains do
    if active() != [] and OperationalMode.mode() != :draining do
      _ = OperationalMode.enter_draining()
    end
  end

  defp leave_deployment_drain do
    if OperationalMode.mode() == :draining, do: OperationalMode.leave_draining()
  end

  defp expire_stalled_deployments do
    current = now()
    starting_timeout = Application.get_env(:ptc_manager, :deployment_start_timeout_ms, 60_000)
    completion_grace = Application.get_env(:ptc_manager, :deployment_completion_grace_ms, 60_000)

    Enum.each(active(), fn deployment ->
      elapsed =
        if deployment.started_at,
          do: DateTime.diff(current, deployment.started_at, :millisecond),
          else: 0

      timeout =
        case deployment.state do
          "starting" ->
            starting_timeout

          "running" when is_integer(deployment.deployment_timeout_minutes) ->
            deployment.deployment_timeout_minutes * 60_000 + completion_grace

          "running" ->
            starting_timeout + completion_grace

          _other ->
            nil
        end

      if is_integer(timeout) and elapsed > timeout do
        reconcile_stalled_deployment(deployment)
      end
    end)
  end

  defp reconcile_stalled_deployment(deployment) do
    runner = Application.fetch_env!(:ptc_manager, :deployment_runner)

    case runner_status(runner, deployment) do
      :active ->
        if deployment.state == "starting" do
          transition(deployment, %{
            state: "running",
            status_text: "The host runner is active; waiting for its terminal status."
          })
        end

      :inactive ->
        case File.read(status_path(deployment.id)) do
          {:ok, content} ->
            ingest_status(deployment, content)

          {:error, :enoent} ->
            with :ok <- runner_cleanup(runner, deployment) do
              fail(deployment, {:deployment_status_timeout, deployment.state})
            end

          {:error, reason} ->
            fail(deployment, {:deployment_status_unreadable, reason})
        end

      {:unknown, reason} ->
        transition(deployment, %{
          status_text: "Host runner state is unknown; deployment remains drained for safety.",
          last_error: bounded(inspect(reason), 4_000)
        })
    end
  end

  defp runner_status(runner, deployment) do
    if gateway_exports?(runner, :status, 1),
      do: Gateway.call(runner, :status, [deployment]),
      else: :inactive
  end

  defp runner_cleanup(runner, deployment) do
    if gateway_exports?(runner, :cleanup, 1),
      do: Gateway.call(runner, :cleanup, [deployment]),
      else: :ok
  end

  defp gateway_exports?(module, function, arity) when is_atom(module),
    do: function_exported?(module, function, arity)

  defp gateway_exports?(%module{}, function, arity),
    do: function_exported?(module, function, arity + 1)

  defp current_sha do
    case ReleaseRevision.current() do
      {:ok, sha} -> sha
      {:error, _reason} -> nil
    end
  end

  defp status_path(id) do
    Path.join(
      Application.fetch_env!(:ptc_manager, :deployment_spool_path),
      "deployment-#{id}.status.json"
    )
  end

  defp valid_sha?(sha), do: is_binary(sha) and Regex.match?(@sha, sha)
  defp bounded(nil, _limit), do: nil
  defp bounded(value, limit), do: value |> to_string() |> String.slice(0, limit)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
