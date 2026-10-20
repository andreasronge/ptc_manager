defmodule PtcManager.Cluster.Move do
  @moduledoc """
  Moving a repository's home from one member to another.

  The source disables the repository and lets its remaining work finish or
  cancels it, so it no longer claims the repository. The target, where the
  repository was onboarded disabled the ordinary way, checks that it is ready
  (checkout present and readable, commit identity resolves), fetches the
  source's settings, shows what they change, and claims the repository with
  one confirmation, importing the settings in the claim's own transaction.
  History stays on the source.
  """

  alias PtcManager.Cluster.{Claims, Peer, RepositorySettings}
  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.Checkout

  @doc "The target's readiness checks, each `%{check, ok?, detail}`."
  def readiness(%Repository{} = repository) do
    checkout =
      case Checkout.available_path(repository) do
        {:ok, path} ->
          %{check: "Checkout present and readable", ok?: true, detail: path}

        {:error, reason} ->
          %{check: "Checkout present and readable", ok?: false, detail: inspect(reason)}
      end

    identity =
      case PtcManager.CommitIdentities.resolve(repository) do
        {:ok, _identity} ->
          %{check: "Agent commit identity resolves", ok?: true, detail: nil}

        {:error, message} ->
          %{check: "Agent commit identity resolves", ok?: false, detail: to_string(message)}
      end

    [checkout, identity]
  end

  def ready?(repository), do: Enum.all?(readiness(repository), & &1.ok?)

  @doc "Fetches and validates the source's settings for the repository."
  def fetch(%Repository{} = repository, source, opts \\ []) do
    with {:ok, document} <-
           Peer.fetch(
             source,
             Peer.settings_path(repository.github_owner, repository.github_name),
             opts
           ),
         :ok <- RepositorySettings.validate(Map.delete(document, "_clock_skew_s"), repository) do
      {:ok, Map.delete(document, "_clock_skew_s")}
    end
  end

  @doc "The settings and what claiming with them would change."
  def preview(%Repository{} = repository, source, opts \\ []) do
    with {:ok, document} <- fetch(repository, source, opts) do
      {:ok, %{document: document, diff: RepositorySettings.diff(document, repository)}}
    end
  end

  @doc """
  Claims the repository with the settings the maintainer saw (`digest`).
  Settings are fetched again outside any transaction; a changed digest asks
  the maintainer to look again.
  """
  def claim(repository_id, source, digest, actor, opts \\ []) do
    repository = PtcManager.Repo.get!(Repository, repository_id)

    cond do
      repository.enabled ->
        {:error, :already_enabled, []}

      not ready?(repository) ->
        {:error, :target_not_ready, []}

      true ->
        case fetch(repository, source, opts) do
          {:ok, %{"digest" => ^digest} = document} ->
            Claims.acquire(
              repository_id,
              actor,
              fn current, checks ->
                RepositorySettings.import(document, current, %{
                  actor: actor,
                  source: source,
                  checks: checks
                })
              end,
              opts
            )

          {:ok, _changed} ->
            {:error, :settings_changed, []}

          {:error, reason} ->
            {:error, reason, []}
        end
    end
  end
end
