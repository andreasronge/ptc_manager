defmodule PtcManager.Cluster.Status do
  @moduledoc """
  The read-only status document this member serves to its peers.

  It carries what another console needs to show the whole cluster and to
  decide a claim: identity, deployed revision, membership revision, mode, tool
  inventory per context, each repository's claim and requirements, live work
  with links to this console, agent CLI login state, and execution-profile
  digests for drift. It never carries the operator state's `untrusted`
  section, prompts, issue text, agent output, or secret values.

  Peers treat the document as data: it decides nothing on its own.
  """

  import Ecto.Query

  alias PtcManager.{Cluster, Machine, OperationalMode, Repo}
  alias PtcManager.Collections.Run
  alias PtcManager.ExecutionProfiles.Profile
  alias PtcManager.Machine.{Inventory, Requirements, ToolInventory}
  alias PtcManager.Operations.{Job, Repository}

  def build(now \\ DateTime.utc_now()) do
    inventory = Inventory.current()

    %{
      "protocol_version" => Cluster.protocol_version(),
      "machine_id" => Machine.id(),
      "machine_name" => Machine.name(),
      "os" => Machine.os(),
      "captured_at" => DateTime.to_iso8601(now),
      "deployed_sha" => deployed_sha(),
      "membership_revision" => Cluster.membership_revision(),
      "operational_mode" => mode_name(OperationalMode.mode()),
      "inventory" => ToolInventory.summary(inventory.contexts, now),
      "agent_logins" => inventory.agent_logins,
      "execution_profiles" => execution_profile_digests(),
      "capacity" => capacity(now)
    }
    |> Map.merge(repositories_and_work())
  end

  defp deployed_sha do
    case PtcManager.Deployments.ReleaseRevision.current() do
      {:ok, sha} -> sha
      {:error, _reason} -> Application.get_env(:ptc_manager, :deployed_sha)
    end
  end

  defp mode_name({:canary, _invocation_id}), do: "canary"
  defp mode_name(mode) when is_atom(mode), do: Atom.to_string(mode)

  defp capacity(now) do
    settings = PtcManager.CapacitySettings.current()
    usage = PtcManager.Operations.agent_slot_usage(now)

    sample = PtcManager.MachineUsage.latest_sample()

    %{
      "light_agent_capacity" => settings.light_agent_capacity,
      "heavy_agent_capacity" => settings.heavy_agent_capacity,
      "operation_capacity" => settings.operation_capacity,
      "light_agents_in_use" => usage.light,
      "heavy_agents_in_use" => usage.heavy,
      "cpu_percent" => sample && sample.cpu_percent,
      "memory_percent" => sample && sample.memory_percent,
      "disk_percent" => sample && sample.disk_percent,
      "load_one" => sample && sample.load_one
    }
  end

  @doc "name => digest of each execution profile's settings."
  def execution_profile_digests do
    Repo.all(Profile)
    |> Map.new(fn profile ->
      settings =
        profile
        |> Map.take([
          :kind,
          :model,
          :effort,
          :reviewer_kind,
          :reviewer_model,
          :reviewer_effort,
          :review_timeout_ms,
          :max_reviews
        ])
        |> Enum.sort()
        |> Enum.map(fn {key, value} -> [key, value] end)

      {profile.name,
       :crypto.hash(:sha256, Jason.encode!(settings)) |> Base.encode16(case: :lower)}
    end)
  end

  # Every claim predicate is read in one read transaction, so a reader sees a
  # single WAL snapshot: an intent or the enabled row that replaced it, never
  # neither. It is deferred, so serving a peer never takes the write lock.
  defp repositories_and_work do
    {:ok, result} =
      Repo.transaction(
        fn ->
          repositories = Repo.all(from repository in Repository, order_by: repository.id)
          claims = PtcManager.Cluster.Claims.snapshot(repositories)

          %{
            "repositories" =>
              Enum.map(repositories, fn repository ->
                key = Cluster.Claims.key(repository)

                %{
                  "repository" => key,
                  "enabled" => repository.enabled,
                  "claim" => claims.states[key] || "none",
                  "claim_blockers" => claims.blockers[key] || [],
                  "requirements" => Requirements.lines(repository.machine_requirements),
                  "requirements_revision" =>
                    Requirements.revision(repository.machine_requirements),
                  "console_url" =>
                    Cluster.self_url(
                      "/repositories/#{repository.github_owner}/#{repository.github_name}"
                    )
                }
              end),
            "intents" => claims.intents,
            "jobs" => live_jobs(),
            "collection_runs" => live_runs()
          }
        end,
        mode: :deferred
      )

    result
  end

  defp live_jobs do
    Repo.all(
      from job in Job,
        join: repository in assoc(job, :repository),
        join: issue in assoc(job, :issue),
        where: job.state in ^Job.live_states(),
        order_by: job.id,
        select: %{
          id: job.id,
          state: job.state,
          owner: repository.github_owner,
          name: repository.github_name,
          issue_number: issue.number
        }
    )
    |> Enum.map(fn job ->
      %{
        "id" => job.id,
        "repository" => String.downcase("#{job.owner}/#{job.name}"),
        "issue_number" => job.issue_number,
        "state" => job.state,
        "url" => Cluster.self_url("/jobs/#{job.id}/report")
      }
    end)
  end

  defp live_runs do
    Repo.all(
      from run in Run,
        join: repository in assoc(run, :repository),
        join: issue in assoc(run, :issue),
        where: run.state in ^Run.live_states(),
        order_by: run.id,
        select: %{
          id: run.id,
          state: run.state,
          owner: repository.github_owner,
          name: repository.github_name,
          issue_number: issue.number
        }
    )
    |> Enum.map(fn run ->
      %{
        "id" => run.id,
        "repository" => String.downcase("#{run.owner}/#{run.name}"),
        "issue_number" => run.issue_number,
        "state" => run.state,
        "url" => Cluster.self_url("/board")
      }
    end)
  end
end
