defmodule PtcManager.Machine do
  @moduledoc """
  This machine's identity in a cluster of PtcManager instances.

  `PTC_MACHINE_ID` names the machine to its peers and `PTC_MACHINE_NAME` is the
  label people read. An unclustered instance is `local`. The badge colour is
  derived from the id, so the same machine looks the same on every console.
  """

  @id_pattern ~r/\A[a-z0-9][a-z0-9-]{1,62}\z/

  def id, do: Application.get_env(:ptc_manager, :machine_id, "local")

  def name do
    case Application.get_env(:ptc_manager, :machine_name) do
      name when is_binary(name) and name != "" -> name
      _unset -> id()
    end
  end

  @doc "The operating system this release runs on, as the inventory reports it."
  def os do
    case :os.type() do
      {:unix, :linux} -> "linux"
      {:unix, :darwin} -> "darwin"
      {family, name} -> "#{family}-#{name}"
    end
  end

  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  def valid_id?(_id), do: false

  @doc "A stable hue (0-359) for a machine id."
  def hue(id) when is_binary(id), do: :erlang.phash2(id, 360)

  def describe do
    %{id: id(), name: name(), os: os(), hue: hue(id())}
  end
end
