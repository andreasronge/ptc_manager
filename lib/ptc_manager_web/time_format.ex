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

  @doc "A coarse relative time such as \"12 min ago\" or \"in 3 h\"."
  def relative(_now, nil), do: nil

  def relative(now, at) do
    difference = DateTime.diff(at, now, :second)
    amount = coarse(abs(difference))

    cond do
      abs(difference) < 60 and difference <= 0 -> "just now"
      abs(difference) < 60 -> "in under a minute"
      difference < 0 -> "#{amount} ago"
      true -> "in #{amount}"
    end
  end

  defp coarse(value) when value < 3_600, do: "#{div(value, 60)} min"
  defp coarse(value) when value < 86_400, do: "#{div(value, 3_600)} h"
  defp coarse(value), do: "#{div(value, 86_400)} d"
end
