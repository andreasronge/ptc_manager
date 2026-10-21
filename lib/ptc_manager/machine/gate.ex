defmodule PtcManager.Machine.Gate do
  @moduledoc """
  Admits work for a repository only on a machine that satisfies its
  requirements.

  Every admission point (implementation dispatch, review claims and retries,
  review continuations, resuming retained work, and maintainer actions) asks
  here before a lease, claim, or worktree reservation. The answer comes from
  the in-memory inventory and the repository's stored requirements, so
  checking writes nothing; work that fails the check simply stays queued, and
  pages derive the reason from `explain/1`.
  """

  import Ecto.Query

  alias PtcManager.Machine.{Inventory, Requirements}
  alias PtcManager.Operations.Repository
  alias PtcManager.Repo

  @doc """
  Ids of repositories this console may not admit work for now: their
  requirements are unmet here, or the cluster fences them
  (`PtcManager.Cluster.Fence`).
  """
  def unsatisfied_repository_ids(now \\ DateTime.utc_now()) do
    inventory = Inventory.current()

    incapable =
      for {id, requirements} <- requirement_rows(),
          not Requirements.evaluate(requirements, inventory, now).satisfied?,
          do: id

    Enum.uniq(incapable ++ PtcManager.Cluster.Fence.fenced_repository_ids())
  end

  @doc "Whether an admission error means the work waits rather than fails."
  def waiting?(reason), do: reason in [:machine_incapable, :cluster_fenced]

  @doc "Repository id => evaluation for every repository that declares requirements."
  def evaluations(now \\ DateTime.utc_now()) do
    inventory = Inventory.current()

    Map.new(requirement_rows(), fn {id, requirements} ->
      {id, Requirements.evaluate(requirements, inventory, now)}
    end)
  end

  defp requirement_rows do
    Repo.all(
      from repository in Repository,
        where:
          not is_nil(repository.machine_requirements) and
            fragment(
              "json_array_length(json_extract(?, '$.tools')) > 0",
              repository.machine_requirements
            ),
        select: {repository.id, repository.machine_requirements}
    )
  end

  @doc """
  `:ok` when work for the repository may start here, otherwise
  `{:error, :machine_incapable}`. Reads the repository row, so inside a write
  transaction it sees the requirements that transaction sees.
  """
  def check(repository_or_id, now \\ DateTime.utc_now())

  def check(%Repository{machine_requirements: requirements} = repository, now) do
    cond do
      not Requirements.evaluate(requirements, Inventory.current(), now).satisfied? ->
        {:error, :machine_incapable}

      PtcManager.Cluster.Fence.admission(repository) != :ok ->
        {:error, :cluster_fenced}

      true ->
        :ok
    end
  end

  def check(repository_id, now) when is_integer(repository_id) do
    case Repo.get(Repository, repository_id) do
      nil -> :ok
      repository -> check(repository, now)
    end
  end

  @doc "The evaluation for one repository, for pages that explain a wait."
  def evaluate(%Repository{machine_requirements: requirements}, now \\ DateTime.utc_now()),
    do: Requirements.evaluate(requirements, Inventory.current(), now)

  @doc """
  Details for the append-only `placement.admitted` audit event: the machine,
  the requirements, and the evaluated tool lines of each context with their
  capture time.
  """
  def placement_details(%Repository{} = repository, now \\ DateTime.utc_now()) do
    inventory = Inventory.current()
    names = repository.machine_requirements |> Requirements.lines() |> Enum.map(& &1["name"])

    %{
      "machine_id" => PtcManager.Machine.id(),
      "repository_id" => repository.id,
      "requirements" => Requirements.lines(repository.machine_requirements),
      "requirements_revision" => Requirements.revision(repository.machine_requirements),
      "tools" =>
        inventory
        |> Inventory.lines(now)
        |> Enum.filter(&(&1["name"] in names))
    }
  end
end
