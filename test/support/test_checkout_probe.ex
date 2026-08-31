defmodule PtcManager.TestCheckoutProbe do
  @moduledoc false

  def checkout_identity(repository, path) do
    case Process.get(:checkout_probe_result) do
      nil -> default_identity(repository, path)
      result -> result
    end
  end

  defp default_identity(repository, path) do
    case PtcManager.Repository.Checkout.canonical_directory(path) do
      {:ok, canonical} ->
        {:ok,
         %{
           top_level: canonical,
           common_dir: canonical,
           remote_identity:
             {String.downcase(repository.github_owner || ""),
              String.downcase(repository.github_name || "")}
         }}

      {:error, _reason} ->
        {:error, :repository_identity_unavailable}
    end
  end
end
