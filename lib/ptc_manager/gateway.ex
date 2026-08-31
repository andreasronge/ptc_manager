defmodule PtcManager.Gateway do
  @moduledoc """
  Calls either a stateless adapter module or a stateful adapter value.

  Production adapters remain ordinary modules. Deterministic scenarios can pass
  a struct whose module receives that struct as the first callback argument.
  This keeps mutable test state explicit without storing it in application
  configuration or the caller's process dictionary.
  """

  def call(module, function, arguments)
      when is_atom(module) and is_atom(function) and is_list(arguments) do
    apply(module, function, arguments)
  end

  def call(%module{} = gateway, function, arguments)
      when is_atom(function) and is_list(arguments) do
    apply(module, function, [gateway | arguments])
  end
end
