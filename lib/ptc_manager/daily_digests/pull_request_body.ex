defmodule PtcManager.DailyDigests.PullRequestBody do
  @moduledoc """
  Extracts bounded Markdown sections from a pull request body.

  A daily update needs what a change did, what it was checked against, and what
  it left behind, but a flat character slice keeps whatever happens to come
  first. Splitting the body on its headings lets the manifest bound each section
  on its own and, under pressure, shorten or drop them in order of how much the
  update would miss them.
  """

  # Headings the repository's pull request convention defines, plus the spellings
  # GitHub's own templates use for the same thing. Anything else is general
  # prose: useful, but the first thing to go when the manifest is full.
  @known %{
    "summary" => "summary",
    "what changed" => "summary",
    "changes" => "summary",
    "description" => "summary",
    "validation" => "validation",
    "testing" => "validation",
    "test plan" => "validation",
    "how to test" => "validation",
    "retrospective" => "retrospective",
    "follow-up" => "retrospective",
    "follow up" => "retrospective"
  }

  # Ordered by how much a daily update loses without them. `summary` leads:
  # the prompt asks what was added, fixed, changed, or removed, and a title
  # alone cannot answer that.
  @priority ~w(summary validation retrospective)
  @preamble "preamble"

  @section_limit 1_500
  @preamble_limit 600
  @shortened_section_bytes 400

  @heading ~r/\A\s{0,3}(?<hashes>[#]{1,6})\s+(?<title>.*?)\s*[#]*\s*\z/
  @fence ~r/\A[ ]{0,3}(?<marker>`{3,}|~{3,})(?<tail>.*)\z/

  @doc """
  Splits `body` into bounded sections keyed by `summary`, `validation`,
  `retrospective`, and `preamble`.

  Empty sections are omitted, and a body with no usable content returns `nil`.
  `:section_limit` and `:preamble_limit` are byte bounds, matching the only
  ceiling that actually applies to the manifest.
  """
  def extract(body, opts \\ [])

  def extract(body, opts) when is_binary(body) do
    section_limit = Keyword.get(opts, :section_limit, @section_limit)
    preamble_limit = Keyword.get(opts, :preamble_limit, @preamble_limit)

    body
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({{@preamble, nil}, nil, %{}}, &collect_line/2)
    |> elem(2)
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

  @doc "Ordered body reductions shared by the manifest and its preview."
  def compaction_steps do
    [
      {:priority, &preferred_sections/1},
      {:shortened, &shorten(&1, @shortened_section_bytes)},
      {:shortened_priority, &(&1 |> preferred_sections() |> shorten(@shortened_section_bytes))},
      {:primary, &primary_section/1},
      {:dropped, fn _sections -> nil end}
    ]
  end

  # A plain description is the only account of a change when no headings exist.
  # Priority compaction must not erase it before a shorter version can be tried.
  defp preferred_sections(sections), do: priority_only(sections) || sections

  defp primary_section(sections) when is_map(sections) do
    Enum.find_value(@priority ++ [@preamble], fn key ->
      if is_binary(sections[key]), do: shorten(%{key => sections[key]}, @shortened_section_bytes)
    end)
  end

  defp primary_section(_sections), do: nil

  @doc """
  Shortens every section already extracted to `limit` bytes.

  Used between keeping the sections whole and giving them up entirely, so a busy
  day still reports something about each change rather than nothing about all of
  them.
  """
  def shorten(sections, limit) when is_map(sections) and is_integer(limit) do
    sections
    |> Enum.reduce(%{}, fn {key, text}, kept ->
      case trim_to(text, limit) do
        nil -> kept
        shortened -> Map.put(kept, key, shortened)
      end
    end)
    |> case do
      kept when map_size(kept) == 0 -> nil
      kept -> kept
    end
  end

  def shorten(_sections, _limit), do: nil

  # A fenced block's contents are not Markdown structure. A shell comment inside
  # one looks exactly like an ATX heading, and treating it as a section boundary
  # cuts the block in half and strands the rest of the section in prose.
  defp collect_line(line, {{key, _level} = current, fence, collected}) do
    marker = Regex.named_captures(@fence, line)

    cond do
      fence != nil ->
        next_fence = if closes_fence?(marker, fence), do: nil, else: fence
        {current, next_fence, keep(collected, key, line)}

      opens_fence?(marker) ->
        {current, marker["marker"], keep(collected, key, line)}

      true ->
        case heading(line, current) do
          nil -> {current, fence, keep(collected, key, line)}
          {next, nil} -> {next, fence, collected}
          {{next_key, _} = next, text} -> {next, fence, keep(collected, next_key, text)}
        end
    end
  end

  defp opens_fence?(nil), do: false

  defp opens_fence?(%{"marker" => marker, "tail" => tail}),
    do: String.starts_with?(marker, "~") or not String.contains?(tail, "`")

  defp closes_fence?(nil, _open), do: false

  defp closes_fence?(%{"marker" => marker, "tail" => tail}, open),
    do: String.starts_with?(marker, open) and String.trim(tail) == ""

  defp keep(collected, key, line), do: Map.update(collected, key, [line], &[line | &1])

  # A heading only closes a section at its own level or above. A `###` step
  # inside `## Validation` is part of that validation, not the end of it.
  defp heading(line, {current, current_level}) do
    case Regex.named_captures(@heading, line) do
      %{"hashes" => hashes, "title" => title} ->
        level = byte_size(hashes)
        key = Map.get(@known, normalize(title), @preamble)

        cond do
          current != @preamble and level > current_level -> nil
          key != @preamble -> {{key, level}, nil}
          # An unrecognized heading becomes prose, keeping its own title so the
          # preamble reads as text rather than orphaned lines.
          true -> {{@preamble, nil}, title}
        end

      nil ->
        nil
    end
  end

  defp normalize(title) do
    title
    |> String.replace(~r/[*_`:]/, "")
    |> String.replace(~r/\A\d+[.)]\s*/, "")
    |> String.trim()
    |> String.downcase()
  end

  # Bounded in bytes, because the manifest ceiling is in bytes: a section of
  # multi-byte text would otherwise claim several times its share of the budget.
  defp trim_to(text, limit) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed |> binary_part(0, min(byte_size(trimmed), limit)) |> repair()
    end
  end

  # binary_part/3 can land inside a codepoint; drop the partial tail rather than
  # emit invalid UTF-8 the JSON encoder would reject.
  defp repair(text) do
    if String.valid?(text), do: text, else: text |> binary_slice(0..-2//1) |> repair()
  end
end
