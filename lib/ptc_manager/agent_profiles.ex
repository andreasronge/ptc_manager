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

  A profile also carries the model that kind runs. Left unset, every kind
  reaches for the strongest model its account offers, which is more than a
  routine maintenance job needs, so each kind has a default here and a profile
  may override it with its own `model`. The model joins the arguments the agent
  starts with; a profile that already passes `--model` itself is left alone.
  """

  @type profile :: %{kind: binary(), args: [binary()]}

  # Identifiers taken from each CLI's own catalogue: `codex debug models` lists
  # gpt-5.6-sol as GPT-5.6-Sol, `cursor-agent models` lists cursor-grok-4.6-high
  # as Cursor Grok 4.6, and `claude --help` documents opus as the alias tracking
  # the latest Opus. Every kind accepts `--model`.
  @default_models %{
    "codex" => "gpt-5.6-sol",
    "claude" => "opus",
    "cursor" => "cursor-grok-4.6-high"
  }

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

  @doc """
  Returns the start arguments of one kind, including the model it runs.

  An unconfigured kind has no arguments of its own but still receives its
  default model, so a kind enabled through `PTC_AGENT_PROFILES_JSON` with no
  arguments does not silently fall back to the account's strongest model.
  """
  @spec args(binary()) :: [binary()]
  def args(kind) when is_binary(kind) do
    configured_args = get_in(configured(), [kind, "args"]) || []
    configured_args ++ model_args(kind, configured_args)
  end

  @doc """
  Returns the model one kind runs, or `nil` when neither profile nor default
  names one.
  """
  @spec model(binary()) :: binary() | nil
  def model(kind) when is_binary(kind) do
    args = get_in(configured(), [kind, "args"]) || []
    argument_model(args) || configured_model(kind)
  end

  defp configured_model(kind) do
    case get_in(configured(), [kind, "model"]) do
      model when is_binary(model) and model != "" -> model
      _unset -> Map.get(@default_models, kind)
    end
  end

  # A profile that names its own model on the command line has said what it
  # wants; appending a second --model would let the CLI pick between them.
  defp model_args(kind, configured_args) do
    cond do
      argument_model(configured_args) != nil -> []
      model = model(kind) -> ["--model", model]
      true -> []
    end
  end

  defp argument_model([flag, value | _rest]) when flag in ["--model", "-m"], do: value
  defp argument_model(["--model=" <> value | _rest]), do: value
  defp argument_model([_arg | rest]), do: argument_model(rest)
  defp argument_model([]), do: nil

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
