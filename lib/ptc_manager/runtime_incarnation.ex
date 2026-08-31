defmodule PtcManager.RuntimeIncarnation do
  @moduledoc "Identifies the current coordinator process lifetime for worker admission fencing."

  @key {__MODULE__, :current}

  def initialize do
    incarnation = new_incarnation()
    :persistent_term.put(@key, incarnation)
    incarnation
  end

  def current do
    case :persistent_term.get(@key, nil) do
      nil ->
        incarnation = new_incarnation()
        :persistent_term.put(@key, incarnation)
        incarnation

      incarnation ->
        incarnation
    end
  end

  defp new_incarnation,
    do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
