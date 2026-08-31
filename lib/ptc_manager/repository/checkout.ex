defmodule PtcManager.Repository.Checkout do
  @moduledoc "Resolves the checkout owned by one configured repository."

  import Ecto.Query

  alias PtcManager.Operations.Repository
  alias PtcManager.Repo

  def configured_path(%Repository{local_path: path}) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    if Path.type(path) == :absolute,
      do: {:ok, expanded},
      else: {:error, :repository_path_unavailable}
  end

  def configured_path(%Repository{}), do: {:error, :repository_path_unavailable}

  @doc false
  def canonical_directory(path) when is_binary(path) do
    case System.cmd("/bin/pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {_output, _status} -> {:error, :repository_identity_unavailable}
    end
  rescue
    _error -> {:error, :repository_identity_unavailable}
  end

  def available_path(%Repository{} = repository) do
    with {:ok, path} <- configured_path(repository),
         true <- File.dir?(path),
         {:ok, identity} <- checkout_identity(repository, path),
         :ok <- expected_remote(repository, identity),
         :ok <- exclusive_identity(repository, identity) do
      {:ok, path}
    else
      false -> {:error, :repository_path_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def checkout_identity(%Repository{} = repository, path) when is_binary(path) do
    probe().checkout_identity(repository, path)
  end

  def slug(%Repository{} = repository) do
    "#{repository.github_owner}-#{repository.github_name}"
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
  end

  def external_worktree_name(%Repository{} = repository, pr_number, action_id, attempt)
      when is_integer(pr_number) and is_integer(action_id) and is_integer(attempt) do
    "#{slug(repository)}-external-pr-#{pr_number}-action-#{action_id}-f#{attempt}"
  end

  defp expected_remote(repository, %{remote_identity: remote_identity}) do
    expected =
      {String.downcase(repository.github_owner || ""),
       String.downcase(repository.github_name || "")}

    if remote_identity == expected,
      do: :ok,
      else: {:error, :repository_origin_mismatch}
  end

  defp exclusive_identity(%Repository{id: id}, identity) when is_integer(id) do
    Repository
    |> where([repository], repository.id != ^id and not is_nil(repository.local_path))
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn repository, :ok ->
      with {:ok, path} <- configured_path(repository),
           true <- File.dir?(path),
           {:ok, other_identity} <- checkout_identity(repository, path) do
        if identity.top_level == other_identity.top_level or
             identity.common_dir == other_identity.common_dir,
           do: {:halt, {:error, :repository_checkout_shared}},
           else: {:cont, :ok}
      else
        _unavailable -> {:cont, :ok}
      end
    end)
  end

  defp exclusive_identity(%Repository{}, _identity), do: :ok

  defp probe,
    do: Application.get_env(:ptc_manager, :checkout_probe, PtcManager.Repository.GitProbe)
end
