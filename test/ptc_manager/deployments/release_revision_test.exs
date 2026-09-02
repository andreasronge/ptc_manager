defmodule PtcManager.Deployments.ReleaseRevisionTest do
  use ExUnit.Case, async: false

  alias PtcManager.Deployments.ReleaseRevision

  test "reads a validated release marker and allows an explicit override" do
    path = Path.join(System.tmp_dir!(), "ptc-release-sha-#{System.unique_integer([:positive])}")
    previous_path = Application.get_env(:ptc_manager, :deployed_sha_path)
    previous_sha = Application.get_env(:ptc_manager, :deployed_sha)

    on_exit(fn ->
      restore(:deployed_sha_path, previous_path)
      restore(:deployed_sha, previous_sha)
      File.rm(path)
    end)

    marker_sha = String.duplicate("a", 40)
    File.write!(path, marker_sha <> "\n")
    Application.put_env(:ptc_manager, :deployed_sha_path, path)
    Application.delete_env(:ptc_manager, :deployed_sha)
    assert {:ok, ^marker_sha} = ReleaseRevision.current()

    override_sha = String.duplicate("b", 40)
    Application.put_env(:ptc_manager, :deployed_sha, override_sha)
    assert {:ok, ^override_sha} = ReleaseRevision.current()
  end

  test "fails closed for a missing or malformed marker" do
    previous_path = Application.get_env(:ptc_manager, :deployed_sha_path)
    previous_sha = Application.get_env(:ptc_manager, :deployed_sha)

    on_exit(fn ->
      restore(:deployed_sha_path, previous_path)
      restore(:deployed_sha, previous_sha)
    end)

    Application.delete_env(:ptc_manager, :deployed_sha)
    Application.put_env(:ptc_manager, :deployed_sha_path, "/missing/ptc-manager-release-sha")
    assert {:error, :deployed_revision_unknown} = ReleaseRevision.current()
  end

  defp restore(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore(key, value), do: Application.put_env(:ptc_manager, key, value)
end
