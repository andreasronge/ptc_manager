defmodule PtcManager.CodexTrust do
  @moduledoc """
  Builds the Codex configuration override that trusts managed workspaces.

  Codex asks an interactive "Do you trust this directory?" question before it
  accepts a prompt in an unknown project. For a linked worktree it resolves that
  question at the repository root, so a managed agent must trust both the
  checkout it was created from and the worktree it runs in. The override lives
  only in the arguments of that one Codex process.
  """

  @doc "Returns the `-c projects=...` arguments trusting every given path."
  def override_args(paths) when is_list(paths) and paths != [] do
    entries =
      paths
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.map_join(",", &"#{toml_basic_string(&1)}={trust_level=\"trusted\"}")

    ["-c", "projects={#{entries}}"]
  end

  @doc """
  The settings that keep a Codex start unattended, whatever the profile says:
  an update prompt at startup waits for a person nobody is watching.
  """
  def unattended_args, do: ["-c", "check_for_update_on_startup=false"]

  @doc "Quotes a value as a TOML basic string."
  def toml_basic_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
