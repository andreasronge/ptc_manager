defmodule PtcManager.Deployments.ReleaseRevision do
  @moduledoc "Reads the immutable revision marker installed with the running release."

  @sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  def current do
    with nil <- configured_sha(),
         {:ok, content} <- File.read(marker_path()),
         sha = String.trim(content),
         true <- valid?(sha) do
      {:ok, sha}
    else
      sha when is_binary(sha) -> {:ok, sha}
      _reason -> {:error, :deployed_revision_unknown}
    end
  end

  defp configured_sha do
    case Application.get_env(:ptc_manager, :deployed_sha) do
      sha when is_binary(sha) ->
        sha = String.trim(sha)
        if valid?(sha), do: sha

      _value ->
        nil
    end
  end

  defp marker_path do
    Application.get_env(:ptc_manager, :deployed_sha_path, "/opt/ptc_manager/RELEASE_SHA")
  end

  defp valid?(sha), do: is_binary(sha) and Regex.match?(@sha, sha)
end
