defmodule PtcManager.Repository.StartupPreflight do
  @moduledoc "Reconciles the legacy checkout setting and blocks unsafe repository activation."

  use GenServer

  alias PtcManager.Operations
  alias PtcManager.Operations.Repository
  alias PtcManager.Repo
  alias PtcManager.Repository.Checkout

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    if Application.get_env(:ptc_manager, :demo_mode, false) do
      {:ok, %{status: :demo}}
    else
      case run(System.get_env("PTC_REPOSITORY_PATH")) do
        :ok -> {:ok, %{status: :ok}}
        {:error, reason} -> {:stop, {:repository_startup_preflight_failed, reason}}
      end
    end
  end

  @doc false
  def run(legacy_path) do
    case Repo.transaction(fn ->
           with :ok <- reconcile_legacy_path(legacy_path),
                :ok <- validate_enabled_repositories() do
             :ok
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_legacy_path(path) when path in [nil, ""], do: :ok

  defp reconcile_legacy_path(path) do
    case Operations.list_repositories() do
      [] ->
        :ok

      [%Repository{local_path: current} = repository] when current in [nil, ""] ->
        repository
        |> Repository.changeset(%{local_path: path})
        |> Repo.update()
        |> case do
          {:ok, _repository} -> :ok
          {:error, _changeset} -> {:error, :legacy_repository_path_invalid}
        end

      [%Repository{local_path: current}] ->
        if same_path?(current, path),
          do: :ok,
          else: {:error, :legacy_repository_path_conflict}

      _repositories ->
        {:error, :legacy_repository_path_ambiguous}
    end
  end

  defp validate_enabled_repositories do
    Operations.list_repositories()
    |> Enum.filter(& &1.enabled)
    |> Enum.reduce_while(:ok, fn repository, :ok ->
      case Checkout.available_path(repository) do
        {:ok, _path} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {repository_label(repository), reason}}}
      end
    end)
  end

  defp same_path?(left, right) do
    with true <- Path.type(left) == :absolute and Path.type(right) == :absolute,
         {:ok, left} <- Checkout.canonical_directory(left),
         {:ok, right} <- Checkout.canonical_directory(right) do
      left == right
    else
      _other -> Path.expand(left) == Path.expand(right)
    end
  end

  defp repository_label(repository),
    do: "#{repository.github_owner}/#{repository.github_name}"
end
