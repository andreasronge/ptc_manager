defmodule PtcManager.Toolchain.Manifest do
  @moduledoc """
  Reads `deploy/toolchain-versions` the way the deployment's own reader reads it.

  `deploy/ptc-manager-toolchain-version` refuses a line it cannot read rather
  than skipping it, because a typo that silently keeps the previous pin is the
  drift the manifest exists to end. This parser holds the same grammar, so a
  manifest that would stop a deployment cannot compile a release either.
  """

  @entry ~r/^([a-z0-9_]+)=([A-Za-z0-9][A-Za-z0-9._-]*)$/

  @doc "Every pin in `contents`, or a raised error naming the line that is not one."
  @spec parse!(String.t(), String.t()) :: %{String.t() => String.t()}
  def parse!(contents, source \\ "deploy/toolchain-versions") do
    contents
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, number}, pinned ->
      cond do
        String.trim(line) == "" -> pinned
        String.starts_with?(line, "#") -> pinned
        true -> pin(pinned, line, number, source)
      end
    end)
  end

  defp pin(pinned, line, number, source) do
    case Regex.run(@entry, line, capture: :all_but_first) do
      [key, _value] when is_map_key(pinned, key) ->
        raise "#{source} pins #{key} more than once"

      [key, value] ->
        Map.put(pinned, key, value)

      nil ->
        raise "#{source} line #{number} is not a pinned version: #{line}"
    end
  end
end
