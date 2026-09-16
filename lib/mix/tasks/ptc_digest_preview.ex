defmodule Mix.Tasks.Ptc.Digest.Preview do
  @shortdoc "Shows what a daily update keeps from a pull request body"

  @moduledoc """
  Prints the bounded sections a daily update extracts from one pull request
  body, and what survives each rung of manifest compaction, without a database,
  a GitHub token, or a running server.

      mix ptc.digest.preview docs/example-body.md

  Reads standard input when the path is `-`, which pairs with the GitHub CLI:

      gh pr view 134 --json body -q .body | mix ptc.digest.preview -
  """

  use Mix.Task

  alias PtcManager.DailyDigests.PullRequestBody

  @order ~w(summary validation retrospective preamble)

  @impl Mix.Task
  def run(argv) do
    body =
      case argv do
        ["-"] -> IO.read(:stdio, :eof)
        [path] -> File.read!(path)
        _argv -> Mix.raise("usage: mix ptc.digest.preview <path|->")
      end

    case PullRequestBody.extract(body) do
      nil ->
        Mix.shell().info("No usable body content.")

      sections ->
        report(body, sections)
    end
  end

  defp report(body, sections) do
    shell = Mix.shell()

    shell.info("Body: #{byte_size(body)} bytes\n")

    shell.info("Extracted:")
    Enum.each(@order, &report_section(shell, sections, &1))

    shell.info("\nUnder manifest pressure, in the order they are given up:")

    Enum.each(
      PullRequestBody.compaction_steps(),
      fn {stage, reduce_body} ->
        label = stage |> Atom.to_string() |> String.replace("_", " ")
        kept = reduce_body.(sections)
        shell.info("\n  [#{label}]#{if kept, do: "", else: " nothing; the body is dropped"}")
        if kept, do: Enum.each(@order, &report_section(shell, kept, &1))
      end
    )
  end

  defp report_section(shell, sections, key) do
    case Map.get(sections, key) do
      nil ->
        :ok

      text ->
        shell.info("\n  [#{key}] #{String.length(text)} characters")
        shell.info(indent(text))
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
