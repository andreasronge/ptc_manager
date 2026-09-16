defmodule PtcManager.DailyDigests.PullRequestBody do
  @moduledoc """
  Extracts bounded Markdown sections from a pull request body.

  A daily update needs what a change was validated against and what it left
  behind far more than it needs the opening prose, but a flat character slice
  keeps exactly the opposite. Splitting the body on its headings lets the
  manifest bound each section on its own and, under pressure, drop general
  prose while retaining validation and retrospective material.
  """

  # Headings the repository's pull request convention defines. Anything else is
  # general prose: useful, but the first thing to go when the manifest is full.
  @known %{
    "summary" => "summary",
    "validation" => "validation",
    "testing" => "validation",
    "retrospective" => "retrospective"
  }

  @priority ~w(validation retrospective)
  @preamble "preamble"

  @section_limit 1_500
  @preamble_limit 600

  @heading ~r/\A\s{0,3}[#]{1,6}\s+(?<title>.*?)\s*[#]*\s*\z/

  @doc """
  Splits `body` into bounded sections keyed by `summary`, `validation`,
  `retrospective`, and `preamble`.

  Empty sections are omitted, and a body with no usable content returns `nil`.
  `:section_limit` and `:preamble_limit` override the character bounds.
  """
  def extract(body, opts \\ [])

  def extract(body, opts) when is_binary(body) do
    section_limit = Keyword.get(opts, :section_limit, @section_limit)
    preamble_limit = Keyword.get(opts, :preamble_limit, @preamble_limit)

    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({@preamble, %{}}, &collect_line/2)
    |> elem(1)
    |> Enum.reduce(%{}, fn {key, lines}, sections ->
      limit = if key == @preamble, do: preamble_limit, else: section_limit

      case lines |> Enum.reverse() |> Enum.join("\n") |> trim_to(limit) do
        nil -> sections
        text -> Map.put(sections, key, text)
      end
    end)
    |> case do
      sections when map_size(sections) == 0 -> nil
      sections -> sections
    end
  end

  def extract(_body, _opts), do: nil

  @doc """
  Keeps only the sections a full manifest cannot afford to lose, or `nil` when
  the body has none of them.
  """
  def priority_only(sections) when is_map(sections) do
    case Map.take(sections, @priority) do
      kept when map_size(kept) == 0 -> nil
      kept -> kept
    end
  end

  def priority_only(_sections), do: nil

  defp collect_line(line, {current, collected}) do
    case heading_key(line) do
      nil -> {current, Map.update(collected, current, [line], &[line | &1])}
      key -> {key, collected}
    end
  end

  # An unrecognized heading keeps its own text as prose so the preamble still
  # reads as sentences rather than orphaned body lines.
  defp heading_key(line) do
    case Regex.named_captures(@heading, line) do
      %{"title" => title} -> Map.get(@known, normalize(title), @preamble)
      nil -> nil
    end
  end

  defp normalize(title) do
    title
    |> String.replace(~r/[*_`:]/, "")
    |> String.trim()
    |> String.downcase()
  end

  defp trim_to(text, limit) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, limit)
    end
  end
end
