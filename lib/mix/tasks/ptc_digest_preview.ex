defmodule Mix.Tasks.Ptc.Digest.Preview do
  @shortdoc "Shows what a daily update keeps from a pull request body"

  @moduledoc """
  Prints the bounded sections a daily update extracts from one pull request
  body, beside the flat slice it used to receive, so the difference is visible
  without a database, a GitHub token, or a running server.

      mix ptc.digest.preview docs/example-body.md

  Reads standard input when the path is `-`, which pairs with the GitHub CLI:

      gh pr view 134 --json body -q .body | mix ptc.digest.preview -
  """

  use Mix.Task

  alias PtcManager.DailyDigests.PullRequestBody

  # What the body allowance used to be, kept here only to show what changed.
  @previous_limit 600

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

    shell.info("Previously (first #{@previous_limit} characters):")
    shell.info(indent(String.slice(body, 0, @previous_limit)))

    shell.info("\nNow:")
    Enum.each(@order, &report_section(shell, sections, &1))

    shell.info("\nUnder manifest pressure this is retained:")

    case PullRequestBody.priority_only(sections) do
      nil -> shell.info(indent("nothing; the body is dropped"))
      kept -> Enum.each(@order, &report_section(shell, kept, &1))
    end
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
