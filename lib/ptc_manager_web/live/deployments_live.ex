defmodule PtcManagerWeb.DeploymentsLive do
  use PtcManagerWeb, :live_view

  alias PtcManager.{DeploymentCanary, Deployments, MaintainerActions, OperationalMode, Toolchain}
  alias PtcManager.Toolchain.Upstream
  alias PtcManager.OperationalMode.Audit
  alias PtcManagerWeb.TimeFormat

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      PtcManager.Operations.subscribe()
      Process.send_after(self(), :deployment_tick, 30_000)
    end

    {:ok,
     socket
     |> assign(:page_title, "Deployments")
     |> assign(:actor, session["actor"] || "maintainer")
     |> assign(:now, DateTime.utc_now())
     |> assign(:revision_results, %{})
     |> assign(:preview_results, %{})
     |> assign(:upstream_checking, [])
     |> load()}
  end

  @impl true
  def handle_event("refresh-revisions", _params, socket) do
    {:noreply, load(socket, refresh?: true)}
  end

  def handle_event("check-toolchain", %{"program" => program}, socket) do
    if program in Upstream.supported() and program not in socket.assigns.upstream_checking do
      {:noreply,
       socket
       |> update(:upstream_checking, &[program | &1])
       |> start_async({:check_toolchain, program}, fn -> Upstream.check(program) end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update-toolchain", %{"program" => program, "repository-id" => id}, socket) do
    with {repository_id, ""} <- Integer.parse(id),
         true <- MaintainerActions.enabled?(),
         {:ok, _action} <-
           MaintainerActions.enqueue_toolchain_bump(repository_id, program, socket.assigns.actor) do
      {:noreply, put_flash(socket, :info, "Draft update PR queued for an agent.")}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Update could not be queued: #{reason_text(reason)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Update is not available.")}
    end
  end

  def handle_event("deploy", %{"repository-id" => id}, socket) do
    with {repository_id, ""} <- Integer.parse(id),
         repository when not is_nil(repository) <-
           PtcManager.Operations.get_repository(repository_id),
         {:ok, _deployment} <- Deployments.request(repository, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Deployment queued. New work is paused while active agents finish.")
       |> load()}
    else
      {:error, :deployment_already_requested} ->
        {:noreply, put_flash(socket, :error, "Another deployment is already queued or running.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Deployment could not be queued: #{reason_text(reason)}")}

      _invalid ->
        {:noreply, put_flash(socket, :error, "Repository is no longer available.")}
    end
  end

  # The rescue the maintainer's agent performed by hand through the release
  # RPC: run the read-only canary and activate ordinary work. It is offered
  # only while nothing else owns the restricted mode (see `activation/0`) and
  # judged again at the click. The canary runs in a task linked to this view,
  # so a tab closed halfway leaves an abandoned canary; the page then offers
  # to replace it.
  def handle_event("activate", _params, socket) do
    actor = socket.assigns.actor

    case activation() do
      %{available?: true, stale_canary?: stale?} = activation ->
        {:noreply,
         socket
         |> assign(:activation, activation)
         |> start_async(:activate, fn -> activate(actor, stale?) end)}

      %{available?: false} ->
        {:noreply,
         socket
         |> put_flash(:error, "The console cannot be activated from here right now.")
         |> load()}
    end
  end

  def handle_event("cancel-deployment", %{"id" => id}, socket) do
    with {deployment_id, ""} <- Integer.parse(id),
         {:ok, _deployment} <- Deployments.cancel(deployment_id, socket.assigns.actor) do
      {:noreply,
       socket
       |> put_flash(:info, "Deployment cancelled. New work resumes.")
       |> load()}
    else
      {:error, :deployment_not_cancellable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The host runner has already started; wait for it to finish."
         )}

      _invalid ->
        {:noreply, put_flash(socket, :error, "The deployment could not be cancelled.")}
    end
  end

  @impl true
  def handle_info({:operations_changed, _source}, socket), do: {:noreply, load(socket)}

  def handle_info(:deployment_tick, socket) do
    Process.send_after(self(), :deployment_tick, 30_000)
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_async(:activate, {:ok, :ok}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "The canary passed and the console is active again.")
     |> load()}
  end

  def handle_async(:activate, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The canary did not pass: #{reason_text(reason)}")
     |> load()}
  end

  def handle_async(:activate, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, "The canary was interrupted: #{reason_text(reason)}")
     |> load()}
  end

  def handle_async({:latest_revision, repository_id}, {:ok, {:ok, sha}}, socket) do
    socket =
      socket
      |> update(:revision_results, &Map.put(&1, repository_id, {:ok, sha}))
      |> assign_statuses()

    {:noreply, start_preview(socket, repository_id, sha)}
  end

  def handle_async({:toolchain_preview, repository_id, sha}, {:ok, result}, socket) do
    {:noreply,
     socket
     |> update(:preview_results, &Map.put(&1, repository_id, {sha, result}))
     |> assign_statuses()}
  end

  def handle_async({:toolchain_preview, repository_id, sha}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> update(:preview_results, &Map.put(&1, repository_id, {sha, {:error, reason}}))
     |> assign_statuses()}
  end

  def handle_async({:check_toolchain, program}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:upstream_checking, &List.delete(&1, program))
     |> put_flash(:error, "The upstream check could not finish.")}
  end

  def handle_async({:check_toolchain, program}, _result, socket) do
    {:noreply,
     socket
     |> update(:upstream_checking, &List.delete(&1, program))
     |> assign(:upstream_checks, Upstream.list())}
  end

  def handle_async({:latest_revision, repository_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update(:revision_results, &Map.put(&1, repository_id, {:error, reason}))
     |> assign_statuses()}
  end

  def handle_async({:latest_revision, repository_id}, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> update(:revision_results, &Map.put(&1, repository_id, {:error, reason}))
     |> assign_statuses()}
  end

  defp load(socket, opts \\ []) do
    configured = Deployments.configured_repositories()
    repositories = Enum.map(configured, &elem(&1, 0))

    socket =
      socket
      |> assign(:repositories, repositories)
      |> assign(:recent_deployments, Deployments.list_recent())
      |> assign(:toolchain, Toolchain.report())
      |> assign(:upstream_checks, Upstream.list())
      |> assign(:mode, OperationalMode.mode())
      |> assign(:activation, activation())
      |> assign_statuses()

    if connected?(socket) do
      Enum.reduce(repositories, socket, fn repository, acc ->
        if Keyword.get(opts, :refresh?, false) or
             not Map.has_key?(acc.assigns.revision_results, repository.id) do
          source = Application.fetch_env!(:ptc_manager, :deployment_revision_source)

          start_async(acc, {:latest_revision, repository.id}, fn ->
            PtcManager.Gateway.call(source, :latest, [repository])
          end)
        else
          acc
        end
      end)
    else
      socket
    end
  end

  # A stale canary is replaced under the mode lock first, so two maintainers
  # cannot clobber a live canary; the new canary is then admitted like any
  # other.
  defp activate(actor, stale_canary?) do
    invocation_id = "console-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"

    with :ok <- replace_if_stale(actor, stale_canary?),
         {:ok, _summary} <- DeploymentCanary.run(invocation_id, actor: actor) do
      DeploymentCanary.activate(invocation_id, actor: actor)
    end
  end

  defp replace_if_stale(_actor, false), do: :ok

  defp replace_if_stale(actor, true) do
    case DeploymentCanary.replace_stale(actor) do
      {:ok, _invocation_id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Activation is offered in maintenance, or for a canary whose process is
  # gone, with no deployment in flight and while the deployment script does
  # not own the window: a direct deployment boots the release in maintenance
  # and runs its own canary inside `Audit.deploy_window_ms/0`, which a second
  # admission would break.
  defp activation do
    last = Audit.last_transition()
    mode = OperationalMode.mode()
    stale_canary? = OperationalMode.stale_canary?()
    recoverable? = mode == :maintenance or stale_canary?

    reason =
      cond do
        mode == :active ->
          nil

        not recoverable? ->
          "The console is in #{OperationalMode.label(mode)}; only maintenance or an " <>
            "abandoned canary can be activated from here."

        Deployments.active() != [] ->
          "A deployment is in flight; it activates the console when it finishes."

        Audit.deploy_owned?() ->
          "The deployment script owns this maintenance window for up to " <>
            "#{div(Audit.deploy_window_ms(), 60_000)} minutes after its last transition."

        true ->
          nil
      end

    %{
      available?: recoverable? and is_nil(reason),
      stale_canary?: stale_canary?,
      reason: reason,
      last_transition: last
    }
  end

  defp assign_statuses(socket) do
    statuses =
      Enum.map(socket.assigns[:repositories] || [], fn repository ->
        result = Map.get(socket.assigns.revision_results, repository.id, :loading)
        latest_sha = if match?({:ok, _sha}, result), do: elem(result, 1)

        preview = Map.get(socket.assigns.preview_results, repository.id)

        Deployments.update_status(repository, latest_sha)
        |> Map.put(:revision_result, result)
        |> Map.put(
          :toolchain_preview,
          if(match?({^latest_sha, _}, preview), do: elem(preview, 1))
        )
      end)

    assign(socket, :deployment_statuses, statuses)
  end

  defp start_preview(socket, repository_id, sha) do
    source = Application.fetch_env!(:ptc_manager, :deployment_revision_source)
    repository = Enum.find(socket.assigns.repositories, &(&1.id == repository_id))

    if repository && Toolchain.own_repository?(repository) && Code.ensure_loaded?(source) &&
         function_exported?(source, :content, 3) do
      start_async(socket, {:toolchain_preview, repository_id, sha}, fn ->
        case PtcManager.Gateway.call(source, :content, [
               repository,
               sha,
               "deploy/toolchain-versions"
             ]) do
          {:ok, contents} -> Toolchain.preview(contents)
          {:error, {:github_http_error, 404, _, _}} -> :missing
          {:error, :revision_content_missing} -> :missing
          other -> other
        end
      end)
    else
      socket
    end
  end

  def upstream_check(checks, program), do: Map.get(checks, Atom.to_string(program.key))

  def upstream_protocol(checks, program) do
    case upstream_check(checks, program) do
      %{protocol: protocol} when is_integer(protocol) -> protocol
      _ -> nil
    end
  end

  def upstream_status(nil, _pinned), do: "Not checked"
  def upstream_status(%{status: "failed"}, _pinned), do: "Check failed"

  def upstream_status(%{program: program, version: version} = check, pinned)
      when program in ["herdr", "mise", "cursor_agent"] and version == pinned do
    digest_key = program <> "_sha256"

    cond do
      check.digest != Toolchain.pinned()[digest_key] ->
        "Digest differs"

      program == "herdr" and to_string(check.protocol) != Toolchain.pinned()["herdr_protocol"] ->
        "Protocol differs"

      true ->
        "Current"
    end
  end

  def upstream_status(%{program: "cursor_agent", version: version}, pinned) do
    with [year, month, day] <-
           Regex.run(~r/\A([0-9]{4})\.([0-9]{2})\.([0-9]{2})-[0-9a-f]+\z/, version,
             capture: :all_but_first
           ),
         [old_year, old_month, old_day] <-
           Regex.run(~r/\A([0-9]{4})\.([0-9]{2})\.([0-9]{2})-[0-9a-f]+\z/, pinned,
             capture: :all_but_first
           ),
         {:ok, latest} <- Date.from_iso8601("#{year}-#{month}-#{day}"),
         {:ok, current} <- Date.from_iso8601("#{old_year}-#{old_month}-#{old_day}") do
      case Date.compare(latest, current) do
        :gt -> if latest.year > current.year, do: "Major update", else: "Update available"
        :eq -> if version == pinned, do: "Current", else: "Version found"
        :lt -> "Pinned is newer"
      end
    else
      _ -> "Version found"
    end
  end

  def upstream_status(%{version: version}, pinned) do
    case {Version.parse(version), Version.parse(pinned)} do
      {{:ok, latest}, {:ok, current}} ->
        case Version.compare(latest, current) do
          :gt -> if latest.major > current.major, do: "Major update", else: "Update available"
          :eq -> "Current"
          :lt -> "Pinned is newer"
        end

      _ ->
        "Version found"
    end
  end

  def toolchain_update_target(statuses) do
    case Enum.filter(statuses, &match?({:ok, _}, &1.toolchain_preview)) do
      [status] -> status.repository.id
      _ -> nil
    end
  end

  @doc "An exact UTC instant, so a deployment can be matched against host logs."
  def timestamp(nil), do: nil
  def timestamp(at), do: Calendar.strftime(at, "%d %b %Y · %H:%M:%S UTC")

  @doc "How long ago something happened, in the reader's own terms."
  def since(now, at), do: TimeFormat.relative(now, at)

  @doc """
  How long the deployment took, or has been running.

  A deployment that never started has no duration to report: the time between
  requesting it and giving up is the wait, not the work.
  """
  def deployment_duration(_now, %{started_at: nil}), do: nil

  def deployment_duration(now, %{started_at: started_at, finished_at: finished_at}),
    do: TimeFormat.duration(now, started_at, finished_at)

  def short_sha(nil), do: "Unknown"
  def short_sha(sha), do: String.slice(sha, 0, 12)

  def state_label("queued"), do: "Queued"
  def state_label("draining"), do: "Waiting for agents"
  def state_label("starting"), do: "Starting"
  def state_label("running"), do: "Deploying"
  def state_label("completed"), do: "Deployed"
  def state_label("failed"), do: "Failed"
  def state_label("cancelled"), do: "Cancelled"
  def state_label(state), do: state

  def outcome_classes("completed"), do: "border-teal-400/20 bg-teal-400/[0.07] text-teal-100"

  def outcome_classes(state) when state in ~w(failed cancelled),
    do: "border-rose-400/25 bg-rose-400/[0.07] text-rose-100"

  def outcome_classes(_state), do: "border-white/10 bg-white/[0.035] text-slate-200"

  @doc """
  What the machine links, compared with what this release pins.

  Staged is not drift: Herdr is installed before its link moves, because only a
  deployment that finds no agent session retained moves it.
  """
  def program_label(:matched), do: "Pinned version"
  def program_label(:staged), do: "Installed, awaiting deployment"
  def program_label(:drifted), do: "Not this release"
  def program_label(:absent), do: "Not on this machine"

  def program_classes(:matched), do: "bg-teal-400/15 text-teal-200"
  def program_classes(:staged), do: "bg-amber-400/15 text-amber-200"
  def program_classes(:drifted), do: "bg-rose-400/15 text-rose-200"
  def program_classes(:absent), do: "bg-white/5 text-slate-500"

  def toolchain_note(:matched),
    do: "Each program below links the version this release pins."

  def toolchain_note(:staged),
    do:
      "A pinned program is installed but not linked yet. A deployment is what moves Herdr's link, and only one that finds no agent session retained, so deploy again when none is rather than restarting the service by hand."

  def toolchain_note(:drifted),
    do:
      "The machine links something this release does not pin, or nothing at all. Deploy this revision to put the pinned version in place, or pin what the machine has in deploy/toolchain-versions."

  def toolchain_note(:absent),
    do: "This machine links none of these programs, so there is nothing to compare."

  def state_classes(state) when state in ~w(completed), do: "bg-teal-400/15 text-teal-200"
  def state_classes(state) when state in ~w(failed cancelled), do: "bg-rose-400/15 text-rose-200"
  def state_classes(_state), do: "bg-amber-400/15 text-amber-200"

  defp reason_text(:deployment_not_available), do: "deployment is not enabled for this repository"

  defp reason_text(:deployment_runner_not_configured),
    do: "the host deployment runner is not configured"

  defp reason_text(reason), do: inspect(reason, limit: 8, printable_limit: 300)
end
