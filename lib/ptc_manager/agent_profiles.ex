defmodule PtcManager.AgentProfiles do
  @moduledoc """
  Chooses the Herdr agent kind an automation version runs with.

  Profiles are configured per Herdr kind (`PTC_AGENT_PROFILES_JSON`) and carry
  the arguments that kind needs to start unattended. An automation version's
  agent selector accepts any enabled profile, prefers one kind and falls back,
  or requires an exact kind. Every path that starts a managed agent, whether an
  implementation job, a fresh pull-request repair, or a generic ephemeral
  action, selects through here, so the kind a maintainer picked on the
  Automations page is the kind that starts.
  """

  @type profile :: %{kind: binary(), args: [binary()]}

  @doc """
  Selects the enabled profile an agent selector allows.

  Without a preference the configured implementation kind comes first, then
  every other enabled profile; a preferred kind is tried before them; a
  required kind is the only candidate.
  """
  @spec select(map() | nil) :: {:ok, profile()} | {:error, :no_healthy_agent_profile}
  def select(selector) when is_map(selector) or is_nil(selector) do
    profiles = configured()
    preferred = selector["preferred_kind"]
    mode = selector["mode"] || "any"
    fallback = Application.get_env(:ptc_manager, :implementation_agent_kind, "codex")

    candidates =
      case {mode, preferred} do
        {"require", kind} when is_binary(kind) -> [kind]
        {"prefer", kind} when is_binary(kind) -> Enum.uniq([kind, fallback] ++ Map.keys(profiles))
        _any -> Enum.uniq([fallback] ++ Map.keys(profiles))
      end

    case Enum.find(candidates, &(get_in(profiles, [&1, "enabled"]) == true)) do
      nil -> {:error, :no_healthy_agent_profile}
      kind -> {:ok, %{kind: kind, args: args(kind)}}
    end
  end

  @doc "Returns the configured start arguments of one kind; an unconfigured kind has none."
  @spec args(binary()) :: [binary()]
  def args(kind) when is_binary(kind), do: get_in(configured(), [kind, "args"]) || []

  @doc "Expands the workspace placeholders in profile arguments, keeping each argument whole."
  @spec expand_args([binary()], binary()) :: [binary()]
  def expand_args(args, workspace_path) when is_list(args) and is_binary(workspace_path) do
    expanded_path = Path.expand(workspace_path)
    toml_path = PtcManager.CodexTrust.toml_basic_string(expanded_path)

    Enum.map(args, fn argument ->
      argument
      |> String.replace("{{workspace_path_toml}}", toml_path)
      |> String.replace("{{workspace_path}}", expanded_path)
    end)
  end

  defp configured, do: Application.get_env(:ptc_manager, :agent_profiles, %{})
end
