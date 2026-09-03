defmodule PtcManager.Repository.Health do
  @moduledoc "Builds a read-only configuration health summary for one repository."

  alias PtcManager.Operations.Repository
  alias PtcManager.Repository.{Checkout, Contract, GitProbe, ServiceAccess}

  def summarize(%Repository{} = repository) do
    summarize(repository, Checkout.available_path(repository))
  end

  def summarize(%Repository{} = repository, availability) do
    checkout = checkout_health(availability)

    %{
      repository: repository,
      checkout: checkout,
      gate: gate_health(repository, checkout),
      github: github_health(repository),
      service_access: ServiceAccess.summarize(repository)
    }
  end

  defp checkout_health(availability) do
    case availability do
      {:ok, path} ->
        %{status: :ready, label: "Checkout verified", detail: path, path: path}

      {:error, reason} ->
        %{
          status: :attention,
          label: "Checkout needs attention",
          detail: checkout_error(reason),
          path: nil
        }
    end
  end

  defp gate_health(repository, %{status: :ready, path: path}) do
    with {:ok, branch_sha} <- GitProbe.branch_sha(path, repository.default_branch),
         {:ok, content} <- GitProbe.repository_contract(path, branch_sha),
         {:ok, contract} <- Contract.parse(content) do
      contract_health(contract)
    else
      {:error, reason} ->
        %{
          status: :attention,
          label: "Repository contract needs attention",
          detail: gate_error(reason)
        }
    end
  end

  defp gate_health(_repository, _checkout) do
    %{
      status: :unchecked,
      label: "Repository contract not checked",
      detail: "Verify the checkout first."
    }
  end

  defp contract_health(%Contract{} = contract) do
    if Contract.publication_verification_configured?(contract) do
      %{
        status: :ready,
        label: "Optional broker verification ready",
        detail: contract.before_publish_command
      }
    else
      %{
        status: :ready,
        label: "Repository setup ready",
        detail: "Agent publishing uses GitHub CI; broker verification is not configured."
      }
    end
  end

  defp github_health(%Repository{sync_status: "ok", last_synced_at: synced_at}) do
    %{status: :ready, label: "GitHub read access verified", detail: synced_at}
  end

  defp github_health(%Repository{sync_status: "error"}) do
    %{
      status: :attention,
      label: "GitHub read access needs attention",
      detail: "The last synchronization failed."
    }
  end

  defp github_health(%Repository{sync_status: "syncing"}) do
    %{
      status: :syncing,
      label: "GitHub read access syncing",
      detail: "Refreshing repository data now."
    }
  end

  defp github_health(%Repository{enabled: false}) do
    %{
      status: :unchecked,
      label: "GitHub read access not synchronized",
      detail:
        "Access was verified when this repository was added. Synchronization covers enabled " <>
          "repositories, so this turns green once it is enabled."
    }
  end

  defp github_health(_repository) do
    %{
      status: :unchecked,
      label: "GitHub read access not checked",
      detail: "Run GitHub synchronization to verify access."
    }
  end

  defp checkout_error(:repository_path_unavailable), do: "Configure an existing absolute path."

  defp checkout_error(:repository_origin_mismatch),
    do: "The GitHub origin does not match this repository."

  defp checkout_error(:repository_checkout_shared), do: "Another repository owns this checkout."

  defp checkout_error(:repository_checkout_root_mismatch),
    do: "The configured path is not the Git checkout root."

  defp checkout_error(:repository_origin_not_github), do: "The origin is not a GitHub repository."
  defp checkout_error(_reason), do: "The checkout identity could not be verified."

  defp gate_error(:repository_contract_missing),
    do: "Add .ptc-manager.yml to the repository root."

  defp gate_error(:branch_missing), do: "Commit the repository before enabling agent work."

  defp gate_error(_reason), do: ".ptc-manager.yml is invalid or unreadable."
end
