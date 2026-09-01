defmodule PtcManagerWeb.TimeFormat do
  @moduledoc false

  def elapsed(now, started_at), do: duration(now, started_at, nil)

  def duration(now, started_at, ended_at) do
    ended_at
    |> then(&DateTime.diff(&1 || now, started_at, :second))
    |> max(0)
    |> seconds()
  end

  def seconds(value) when value < 60, do: "#{value}s"

  def seconds(value) when value < 3_600,
    do: "#{div(value, 60)}m #{rem(value, 60)}s"

  def seconds(value),
    do: "#{div(value, 3_600)}h #{div(rem(value, 3_600), 60)}m"
end
