defmodule PtcManager.Repository.Contract do
  @moduledoc """
  Strict, versioned repository-owned setup and optional publication verification.

  Contract files are untrusted repository input. Unknown keys and malformed
  values fail closed so a typo cannot silently weaken a publication gate.
  """

  @filename ".ptc-manager.yml"
  @top_keys MapSet.new(["version", "bootstrap", "verification"])
  @required_top_keys MapSet.new(["version", "bootstrap"])
  @bootstrap_keys MapSet.new(["command", "timeout_minutes"])
  @verification_keys MapSet.new(["before_publish", "timeout_minutes"])
  @max_command_bytes 2_000
  @max_timeout_minutes 24 * 60

  @enforce_keys [
    :version,
    :bootstrap_command,
    :bootstrap_timeout_minutes
  ]
  defstruct @enforce_keys ++ [before_publish_command: nil, verification_timeout_minutes: nil]

  @type t :: %__MODULE__{
          version: 1,
          bootstrap_command: binary(),
          bootstrap_timeout_minutes: pos_integer(),
          before_publish_command: binary() | nil,
          verification_timeout_minutes: pos_integer() | nil
        }

  alias PtcManager.Operations.Job
  alias PtcManager.Repository.GitProbe

  @doc "Freezes the contract committed at a verified implementation result SHA."
  @spec for_result(struct(), map()) :: {:ok, t()} | {:error, term()}
  def for_result(%Job{worktree_allocation: %{path: path}}, %{head_sha: head_sha})
      when is_binary(path) and is_binary(head_sha) do
    with {:ok, content} <- GitProbe.repository_contract(path, head_sha),
         {:ok, contract} <- parse(content) do
      {:ok, contract}
    end
  end

  def for_result(%Job{}, _result), do: {:error, :worktree_allocation_missing}

  @doc "Reads the repository contract from the exact commit used to create a worktree."
  @spec for_workspace(binary(), binary()) :: {:ok, t()} | {:error, term()}
  def for_workspace(path, source_sha) when is_binary(path) and is_binary(source_sha) do
    with {:ok, content} <- GitProbe.repository_contract(path, source_sha),
         {:ok, contract} <- parse(content) do
      {:ok, contract}
    end
  end

  @doc "Returns the bootstrap entrypoint as one contained relative executable path."
  @spec bootstrap_script(t()) :: {:ok, binary()} | {:error, term()}
  def bootstrap_script(%__MODULE__{bootstrap_command: command}) when is_binary(command) do
    normalized = String.trim_leading(command, "./")

    cond do
      command == "" or String.contains?(command, [" ", "\t", "\n", "\r", <<0>>]) ->
        {:error, :workspace_setup_must_be_one_script}

      Path.type(command) == :absolute or Path.type(normalized) == :absolute ->
        {:error, :workspace_setup_script_must_be_relative}

      normalized in ["", "."] or Enum.any?(Path.split(normalized), &(&1 in ["", ".", ".."])) ->
        {:error, :workspace_setup_script_escapes_worktree}

      true ->
        {:ok, normalized}
    end
  end

  def bootstrap_script(_contract), do: {:error, :workspace_setup_script_missing}

  @doc "Whether the repository opted into the independent broker publication gate."
  @spec publication_verification_configured?(t()) :: boolean()
  def publication_verification_configured?(%__MODULE__{
        before_publish_command: command,
        verification_timeout_minutes: timeout
      }) do
    is_binary(command) and command != "" and is_integer(timeout) and timeout > 0
  end

  @doc "Requires verification before protected broker credentials may publish a result."
  @spec require_publication_verification(t()) :: :ok | {:error, atom()}
  def require_publication_verification(%__MODULE__{} = contract) do
    if publication_verification_configured?(contract),
      do: :ok,
      else: {:error, :repository_publication_verification_missing}
  end

  @doc "Stable digest for the publication-relevant contract values."
  @spec publication_digest(t()) :: binary()
  def publication_digest(%__MODULE__{} = contract) do
    [
      Integer.to_string(contract.version),
      contract.bootstrap_command,
      Integer.to_string(contract.bootstrap_timeout_minutes),
      contract.before_publish_command,
      Integer.to_string(contract.verification_timeout_minutes)
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Recomputes the digest from the immutable gate fields frozen on a job."
  @spec frozen_publication_digest(struct()) :: {:ok, binary()} | {:error, term()}
  def frozen_publication_digest(%Job{} = job) do
    with {:ok, bootstrap_command} <- command(job.pre_publication_bootstrap_command, :bootstrap),
         {:ok, bootstrap_timeout} <-
           timeout_ms(job.pre_publication_bootstrap_timeout_ms, :bootstrap),
         {:ok, before_publish_command} <-
           command(job.pre_publication_command, :before_publish),
         {:ok, verification_timeout} <-
           timeout_ms(job.pre_publication_timeout_ms, :verification) do
      {:ok,
       publication_digest(%__MODULE__{
         version: 1,
         bootstrap_command: bootstrap_command,
         bootstrap_timeout_minutes: bootstrap_timeout,
         before_publish_command: before_publish_command,
         verification_timeout_minutes: verification_timeout
       })}
    end
  end

  @doc "Checks that frozen gate fields still match their recorded digest."
  @spec frozen_publication_digest_matches?(struct()) :: boolean()
  def frozen_publication_digest_matches?(%Job{} = job) do
    case frozen_publication_digest(job) do
      {:ok, digest} -> digest == job.pre_publication_config_digest
      {:error, _reason} -> false
    end
  end

  @doc "Reads the repository contract from its canonical path."
  @spec load(binary()) :: {:ok, t()} | {:error, term()}
  def load(repository_path) when is_binary(repository_path) do
    path = Path.join(repository_path, @filename)

    with true <- Path.type(repository_path) == :absolute,
         {:ok, content} <- File.read(path) do
      parse(content)
    else
      false -> {:error, :repository_path_must_be_absolute}
      {:error, :enoent} -> {:error, :repository_contract_missing}
      {:error, reason} -> {:error, {:repository_contract_unreadable, reason}}
    end
  end

  @doc "Parses and validates contract content without executing repository code."
  @spec parse(binary()) :: {:ok, t()} | {:error, term()}
  def parse(content) when is_binary(content) do
    with {:ok, decoded} <- decode(content),
         :ok <- allowed_keys(decoded, @top_keys, @required_top_keys, :contract),
         1 <- decoded["version"],
         {:ok, bootstrap} <- mapping(decoded["bootstrap"], :bootstrap),
         :ok <- exact_keys(bootstrap, @bootstrap_keys, :bootstrap),
         {:ok, bootstrap_command} <- command(bootstrap["command"], :bootstrap),
         {:ok, bootstrap_timeout} <- timeout(bootstrap["timeout_minutes"], :bootstrap),
         {:ok, before_publish_command, verification_timeout} <-
           optional_verification(decoded["verification"]) do
      {:ok,
       %__MODULE__{
         version: 1,
         bootstrap_command: bootstrap_command,
         bootstrap_timeout_minutes: bootstrap_timeout,
         before_publish_command: before_publish_command,
         verification_timeout_minutes: verification_timeout
       }}
    else
      version when is_integer(version) -> {:error, {:unsupported_contract_version, version}}
      nil -> {:error, :repository_contract_version_missing}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_repository_contract}
    end
  end

  def parse(_content), do: {:error, :invalid_repository_contract}

  defp decode(content) do
    case YamlElixir.read_all_from_string(content, maps_as_keywords: true) do
      {:ok, [decoded]} -> normalize_mapping(decoded)
      {:ok, []} -> {:error, :repository_contract_must_be_a_mapping}
      {:ok, _documents} -> {:error, :repository_contract_must_have_one_document}
      {:error, _reason} -> {:error, :invalid_repository_contract_yaml}
    end
  rescue
    _error -> {:error, :invalid_repository_contract_yaml}
  end

  defp normalize_mapping(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}, MapSet.new()}, fn
      {key, value}, {:ok, mapping, seen} when is_binary(key) ->
        if MapSet.member?(seen, key) do
          {:halt, {:error, :duplicate_repository_contract_key}}
        else
          case normalize_value(value) do
            {:ok, normalized} ->
              {:cont, {:ok, Map.put(mapping, key, normalized), MapSet.put(seen, key)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end

      _invalid, _acc ->
        {:halt, {:error, :repository_contract_must_be_a_mapping}}
    end)
    |> case do
      {:ok, mapping, _seen} -> {:ok, mapping}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_mapping(_value), do: {:error, :repository_contract_must_be_a_mapping}

  defp normalize_value(value) when is_list(value), do: normalize_mapping(value)
  defp normalize_value(value), do: {:ok, value}

  defp mapping(value, _section) when is_map(value), do: {:ok, value}
  defp mapping(_value, section), do: {:error, {:invalid_contract_section, section}}

  defp exact_keys(mapping, allowed, section) do
    keys = Map.keys(mapping)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, {:invalid_contract_keys, section}}

      MapSet.new(keys) != allowed ->
        {:error, {:unexpected_contract_keys, section}}

      true ->
        :ok
    end
  end

  defp allowed_keys(mapping, allowed, required, section) do
    keys = Map.keys(mapping)
    key_set = MapSet.new(keys)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, {:invalid_contract_keys, section}}

      not MapSet.subset?(required, key_set) or not MapSet.subset?(key_set, allowed) ->
        {:error, {:unexpected_contract_keys, section}}

      true ->
        :ok
    end
  end

  defp optional_verification(nil), do: {:ok, nil, nil}

  defp optional_verification(value) do
    with {:ok, verification} <- mapping(value, :verification),
         :ok <- exact_keys(verification, @verification_keys, :verification),
         {:ok, before_publish_command} <-
           command(verification["before_publish"], :before_publish),
         {:ok, verification_timeout} <-
           timeout(verification["timeout_minutes"], :verification) do
      {:ok, before_publish_command, verification_timeout}
    end
  end

  defp command(value, field)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_command_bytes do
    if String.trim(value) == value and not String.contains?(value, ["\n", "\r", <<0>>]),
      do: {:ok, value},
      else: {:error, {:invalid_contract_command, field}}
  end

  defp command(_value, field), do: {:error, {:invalid_contract_command, field}}

  defp timeout(value, _field)
       when is_integer(value) and value > 0 and value <= @max_timeout_minutes,
       do: {:ok, value}

  defp timeout(_value, field), do: {:error, {:invalid_contract_timeout, field}}

  defp timeout_ms(value, field) when is_integer(value) and rem(value, 60_000) == 0,
    do: timeout(div(value, 60_000), field)

  defp timeout_ms(_value, field), do: {:error, {:invalid_contract_timeout, field}}
end
