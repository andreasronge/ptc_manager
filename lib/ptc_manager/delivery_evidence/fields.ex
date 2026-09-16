defmodule PtcManager.DeliveryEvidence.Fields do
  @moduledoc false

  def require!(true, _reason), do: :ok
  def require!(_, reason), do: throw({:delivery_evidence, reason})

  def list!(value, limit) do
    require!(is_list(value) and length(value) <= limit, :collection_limit)
    value
  end

  def integer(value) when is_integer(value) and value >= 0 and value <= 9_000_000_000_000_000,
    do: value

  def integer(_), do: nil

  def sha(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, value), do: value
  end

  def sha(_), do: nil

  def text(value, limit \\ 1_000)

  def text(value, limit) when is_binary(value) do
    if String.valid?(value), do: PtcManager.Reviews.Context.bounded(value, limit)
  end

  def text(_, _), do: nil

  def enum(value, allowed), do: if(value in allowed, do: value)

  def datetime(%DateTime{} = value), do: DateTime.shift_zone!(value, "Etc/UTC")

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  def datetime(_), do: nil

  def timestamp(value) do
    case datetime(value) do
      nil -> nil
      value -> DateTime.to_iso8601(value)
    end
  end

  def source(type, id), do: %{"type" => type, "id" => id}

  def family(trust, coverage, data, sources, opts \\ []) do
    require!(trust in ~w(observed computed reported), :invalid_trust)
    require!(coverage in ~w(complete partial unavailable not_applicable), :invalid_coverage)
    head = sha(Keyword.get(opts, :head))
    binding = if head, do: "exact", else: Keyword.get(opts, :binding, "not_applicable")
    require!(binding in ~w(exact unavailable not_applicable), :invalid_binding)

    %{
      "trust" => trust,
      "coverage" => coverage,
      "binding" => binding,
      "head_sha" => head,
      "reason" => Keyword.get(opts, :reason),
      "source_epoch" => Keyword.get(opts, :epoch),
      "source_ids" => Enum.uniq(sources),
      "data" => data
    }
  end
end
