defmodule PtcManager.GitHub.LinkedIssues do
  @moduledoc false

  @max_count 10
  @max_number 2_147_483_647
  @closing_issue_pattern ~r/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+(?:#(?<local_number>\d+)|(?<qualified_repo>[^\s\/#]+\/[^\s\/#]+)#(?<qualified_number>\d+)|https:\/\/github\.com\/(?<url_repo>[^\s\/]+\/[^\s\/]+)\/issues\/(?<url_number>\d+))\b/i

  def from_body(body, repository_full_name) when is_binary(body) do
    names = Regex.names(@closing_issue_pattern)

    @closing_issue_pattern
    |> Regex.scan(body, capture: :all_names)
    |> Enum.map(&Map.new(Enum.zip(names, &1)))
    |> Enum.map(&issue_number_from_match(&1, repository_full_name))
    |> sanitize()
  end

  def from_body(_body, _repository_full_name), do: []

  def sanitize(numbers) when is_list(numbers) do
    numbers
    |> Enum.filter(&(is_integer(&1) and &1 in 1..@max_number))
    |> Enum.uniq()
    |> Enum.take(@max_count)
  end

  def sanitize(_numbers), do: []

  def valid?(numbers) when is_list(numbers), do: numbers == sanitize(numbers)
  def valid?(_numbers), do: false

  defp same_repository?(repository, expected)
       when is_binary(repository) and is_binary(expected),
       do: String.downcase(repository) == String.downcase(expected)

  defp same_repository?(_repository, _expected), do: false

  defp issue_number_from_match(%{"local_number" => number}, _repository)
       when number != "",
       do: parse_issue_number(number)

  defp issue_number_from_match(
         %{"qualified_repo" => repository, "qualified_number" => number},
         expected_repository
       )
       when repository != "" and number != "" do
    if same_repository?(repository, expected_repository), do: parse_issue_number(number)
  end

  defp issue_number_from_match(
         %{"url_repo" => repository, "url_number" => number},
         expected_repository
       )
       when repository != "" and number != "" do
    if same_repository?(repository, expected_repository), do: parse_issue_number(number)
  end

  defp issue_number_from_match(_match, _repository), do: nil

  defp parse_issue_number(value) do
    case Integer.parse(value) do
      {number, ""} when number in 1..@max_number -> number
      _ -> nil
    end
  end
end
