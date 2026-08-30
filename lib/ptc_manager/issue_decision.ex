defmodule PtcManager.IssueDecision do
  @moduledoc "Validates and resolves schema-backed private maintainer decisions."

  @max_custom_answer 2_000

  def from_result(%{
        "outcome" => "needs-decision",
        "decision_question" => question,
        "decision_options" => options
      })
      when is_binary(question) and is_list(options) and length(options) in 2..4 do
    with question when question != "" <- clean(question),
         {:ok, normalized_options} <- normalize_options(options) do
      {:ok, %{question: question, options: normalized_options}}
    else
      _invalid -> {:error, :decision_format_invalid}
    end
  end

  def from_result(_result), do: {:error, :decision_format_invalid}

  def answer(decision, choice, custom_answer)
      when is_map(decision) and is_binary(choice) and is_binary(custom_answer) do
    case String.trim(custom_answer) do
      "" ->
        option_answer(decision, choice)

      custom ->
        if String.length(custom) <= @max_custom_answer,
          do: {:ok, %{kind: "custom", value: custom}},
          else: {:error, :decision_answer_too_long}
    end
  end

  def answer(_decision, _choice, _custom_answer), do: {:error, :decision_answer_missing}

  def option_letter(index) when is_integer(index) and index >= 0 and index < 26,
    do: <<?A + index>>

  defp normalize_options(options) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {%{"label" => label, "description" => description, "example" => example}, index},
      {:ok, normalized} ->
        option = %{
          index: index,
          letter: option_letter(index),
          label: clean(label),
          description: clean(description),
          example: clean(example)
        }

        if Enum.all?([option.label, option.description, option.example], &(&1 != "")),
          do: {:cont, {:ok, [option | normalized]}},
          else: {:halt, {:error, :decision_format_invalid}}

      _invalid, _acc ->
        {:halt, {:error, :decision_format_invalid}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp option_answer(%{options: options}, choice) do
    with {index, ""} <- Integer.parse(choice),
         true <- index >= 0 and index < length(options),
         %{label: label, description: description, example: example} <- Enum.at(options, index) do
      {:ok,
       %{
         kind: "option",
         value: "#{label}: #{description} Example: #{example}",
         option_index: index
       }}
    else
      _invalid -> {:error, :decision_answer_missing}
    end
  end

  defp clean(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp clean(_value), do: ""
end
