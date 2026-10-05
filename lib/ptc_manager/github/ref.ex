defmodule PtcManager.GitHub.Ref do
  @moduledoc """
  The branch names PtcManager will pass to git and GitHub.

  Narrower than git's own rules: a name that could read as an option, a range,
  or a reflog expression is refused rather than quoted.
  """

  def safe?(value) when is_binary(value) do
    byte_size(value) in 1..240 and Regex.match?(~r/\A[A-Za-z0-9._\/-]+\z/, value) and
      not String.starts_with?(value, ["-", "/"]) and not String.ends_with?(value, [".", "/"]) and
      not String.contains?(value, ["..", "@{"])
  end

  def safe?(_value), do: false
end
