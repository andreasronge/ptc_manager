defmodule PtcManager.Operations.ReportFile do
  @moduledoc """
  Reads a file a model wrote, safely.

  Every agent report shares the same hazard: the contents are model output, the
  path can be swapped between checking it and opening it, and the single
  reconciliation task must not be stalled or exhausted by either. The read is
  therefore bounded and runs under a deadline, and a stat is only a cheap early
  reject rather than a guarantee.

  Callers supply their own error reason so a malformed file is reported in the
  vocabulary of the contract that was being read.
  """

  @max_file_bytes 32_768
  @read_timeout_ms 2_000

  @doc "The largest report this reader will accept."
  def max_bytes, do: @max_file_bytes

  @doc """
  Returns `{:ok, decoded_map}`, `:none` when nothing was written, or
  `{:error, reason}` for anything that is not a JSON object within bounds.
  """
  def read_json(path, reason) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        path |> bounded_contents() |> decode(reason)

      {:ok, %File.Stat{}} ->
        {:error, reason}

      {:error, :enoent} ->
        :none

      {:error, _reason} ->
        {:error, reason}
    end
  end

  @doc """
  True when `token` can only ever name a file inside its own directory.
  """
  def safe_token?(token) when is_binary(token),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{16,64}\z/, token)

  def safe_token?(_token), do: false

  @doc "A fresh random identifier naming one attempt's report file."
  def new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp bounded_contents(path) do
    task = Task.async(fn -> read_head(path) end)

    case Task.yield(task, @read_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_crash -> {:error, :unreadable}
    end
  end

  defp read_head(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, handle} ->
        try do
          # One byte more than a report may be, so an oversized file is detected
          # rather than truncated into something that happens to parse.
          case :file.read(handle, @max_file_bytes + 1) do
            {:ok, body} when byte_size(body) <= @max_file_bytes -> {:ok, body}
            {:ok, _too_large} -> {:error, :too_large}
            :eof -> {:error, :empty}
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(handle)
        end

      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode({:ok, body}, reason) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, reason}
      {:error, _decode_error} -> {:error, reason}
    end
  end

  defp decode(:none, _reason), do: :none
  defp decode({:error, _cause}, reason), do: {:error, reason}
end
