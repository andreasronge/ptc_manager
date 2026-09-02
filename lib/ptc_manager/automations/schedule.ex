defmodule PtcManager.Automations.Schedule do
  @moduledoc """
  Plain-language schedule presets over cron expressions.

  A schedule trigger stores a five-field cron expression and an IANA time zone.
  This module maps the common cases ("Every day at 03:00", "Weekdays at
  07:30") to and from that representation, previews the next occurrences in
  the schedule's own time zone, and backs the schedule editor form.
  """

  import Ecto.Changeset

  @presets [
    {"daily", "Every day"},
    {"weekdays", "Weekdays"},
    {"weekly", "Every week on …"},
    {"hourly", "Every hour"},
    {"custom", "Custom cron"}
  ]

  @weekdays [
    {1, "Monday"},
    {2, "Tuesday"},
    {3, "Wednesday"},
    {4, "Thursday"},
    {5, "Friday"},
    {6, "Saturday"},
    {0, "Sunday"}
  ]

  @time_zones [
    "Europe/Stockholm",
    "Etc/UTC",
    "Europe/London",
    "Europe/Berlin",
    "America/New_York",
    "America/Los_Angeles"
  ]

  @default_time_zone "Europe/Stockholm"
  @default_cron "0 6 * * *"
  @other "other"

  @types %{
    preset: :string,
    time: :string,
    weekday: :integer,
    time_zone: :string,
    other_time_zone: :string,
    cron_expression: :string
  }

  @preset_pattern ~r/\A(\d{1,2}) (\d{1,2}) \* \* (\*|1-5|[0-6])\z/

  def presets, do: @presets
  def weekdays, do: @weekdays
  def time_zones, do: @time_zones
  def default_time_zone, do: @default_time_zone
  def default_cron, do: @default_cron
  def other_time_zone_option, do: @other

  @doc "Attributes for a schedule trigger that has just been added and not yet edited."
  def new_trigger_attrs do
    %{
      trigger_type: "schedule",
      surface: "automations",
      label: describe(@default_cron),
      enabled: false,
      configuration: %{},
      cron_expression: @default_cron,
      time_zone: @default_time_zone
    }
  end

  @doc "Builds a cron expression for a preset. Custom expressions pass through validation."
  def build_cron("hourly", _opts), do: {:ok, "0 * * * *"}

  def build_cron(preset, opts) when preset in ["daily", "weekdays", "weekly"] do
    with {:ok, time} <- parse_time(opts[:time]),
         {:ok, days} <- preset_days(preset, opts[:weekday]) do
      {:ok, "#{time.minute} #{time.hour} * * #{days}"}
    end
  end

  def build_cron("custom", opts) do
    expression = String.trim(opts[:cron_expression] || "")
    if valid_cron?(expression), do: {:ok, expression}, else: {:error, :invalid_cron}
  end

  def build_cron(_preset, _opts), do: {:error, :unknown_preset}

  @doc "Recognises a stored expression as one of the presets, or reports it as custom."
  def detect_preset(expression) when is_binary(expression) do
    case Regex.run(@preset_pattern, String.trim(expression)) do
      [_all, minute, hour, "*"] -> preset("daily", hour, minute, nil)
      [_all, minute, hour, "1-5"] -> preset("weekdays", hour, minute, nil)
      [_all, minute, hour, day] -> preset("weekly", hour, minute, String.to_integer(day))
      nil -> if hourly?(expression), do: preset("hourly"), else: preset("custom")
    end
  end

  def detect_preset(_expression), do: preset("custom")

  @doc "The plain-language name of a schedule, for the index and trigger rows."
  def describe(expression) do
    case detect_preset(expression) do
      %{preset: "daily", time: time} -> "Every day at #{time}"
      %{preset: "weekdays", time: time} -> "Weekdays at #{time}"
      %{preset: "weekly", time: time, weekday: day} -> "Every #{weekday_name(day)} at #{time}"
      %{preset: "hourly"} -> "Every hour"
      %{preset: "custom"} -> "Cron #{String.trim(expression || "")}"
    end
  end

  def valid_cron?(expression) when is_binary(expression) do
    case Oban.Cron.Expression.parse(expression) do
      {:ok, %{reboot?: false}} -> true
      _invalid -> false
    end
  end

  def valid_cron?(_expression), do: false

  def valid_time_zone?(time_zone) when is_binary(time_zone) and time_zone != "" do
    match?({:ok, _now}, DateTime.now(time_zone, Tz.TimeZoneDatabase))
  end

  def valid_time_zone?(_time_zone), do: false

  @doc "The next run instant in UTC, or an error for an invalid expression or zone."
  def next_run_at(expression, time_zone, from) do
    case next_occurrences(expression, time_zone, from, 1) do
      {:ok, [%{utc: utc}]} -> {:ok, utc}
      _other -> {:error, :invalid_schedule}
    end
  end

  @doc """
  The next occurrences after `from`, each as the local wall-clock time in the
  schedule's zone and the same instant in UTC. Wall-clock times are re-resolved
  against the zone so daylight-saving changes land on the correct offset.
  """
  def next_occurrences(expression, time_zone, from \\ DateTime.utc_now(), count \\ 3)

  def next_occurrences(expression, time_zone, from, count)
      when is_binary(expression) and is_binary(time_zone) and count > 0 do
    with {:ok, %{reboot?: false} = cron} <- Oban.Cron.Expression.parse(expression),
         {:ok, local} <- DateTime.shift_zone(from, time_zone, Tz.TimeZoneDatabase) do
      collect_occurrences(cron, local, count, [])
    else
      _invalid -> {:error, :invalid_schedule}
    end
  rescue
    _error -> {:error, :invalid_schedule}
  end

  def next_occurrences(_expression, _time_zone, _from, _count), do: {:error, :invalid_schedule}

  # Editor form -------------------------------------------------------------

  @doc "Form parameters that open the editor on a stored trigger's preset."
  def params(trigger) do
    detected = detect_preset(trigger.cron_expression)
    time_zone = trigger.time_zone || @default_time_zone

    %{
      "preset" => detected.preset,
      "time" => detected.time || "06:00",
      "weekday" => to_string(detected.weekday || 1),
      "time_zone" => if(time_zone in @time_zones, do: time_zone, else: @other),
      "other_time_zone" => if(time_zone in @time_zones, do: "", else: time_zone),
      "cron_expression" => trigger.cron_expression
    }
  end

  def changeset(params) when is_map(params) do
    {%{}, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:preset, :time_zone])
    |> validate_inclusion(:preset, Enum.map(@presets, &elem(&1, 0)))
    |> put_cron_expression()
    |> validate_time_zone()
  end

  @doc "The trigger attributes a valid editor form stores."
  def trigger_attrs(%Ecto.Changeset{} = changeset) do
    with {:ok, values} <- apply_action(changeset, :save) do
      {:ok,
       %{
         cron_expression: values.cron_expression,
         time_zone: resolved_time_zone(values),
         label: describe(values.cron_expression),
         next_run_at: nil
       }}
    end
  end

  @doc "The next three occurrences for the editor's current values, or nothing while invalid."
  def preview(%Ecto.Changeset{} = changeset, from \\ DateTime.utc_now()) do
    expression = get_field(changeset, :cron_expression)
    time_zone = resolved_time_zone(changeset)

    with true <- changeset.errors == [],
         {:ok, occurrences} <- next_occurrences(expression, time_zone, from, 3) do
      occurrences
    else
      _invalid -> []
    end
  end

  def resolved_time_zone(%Ecto.Changeset{} = changeset) do
    resolved_time_zone(%{
      time_zone: get_field(changeset, :time_zone),
      other_time_zone: get_field(changeset, :other_time_zone)
    })
  end

  def resolved_time_zone(%{time_zone: @other, other_time_zone: other}),
    do: String.trim(other || "")

  def resolved_time_zone(%{time_zone: time_zone}), do: time_zone

  def weekday_name(number),
    do: List.keyfind(@weekdays, number, 0, {number, "day #{number}"}) |> elem(1)

  # Internals ---------------------------------------------------------------

  defp put_cron_expression(changeset) do
    preset = get_field(changeset, :preset)

    opts = [
      time: get_field(changeset, :time),
      weekday: get_field(changeset, :weekday),
      cron_expression: get_field(changeset, :cron_expression)
    ]

    case build_cron(preset, opts) do
      {:ok, expression} ->
        put_change(changeset, :cron_expression, expression)

      {:error, :invalid_time} ->
        add_error(changeset, :time, "must be a time such as 03:00")

      {:error, :invalid_weekday} ->
        add_error(changeset, :weekday, "must be a day of the week")

      {:error, :invalid_cron} ->
        add_error(changeset, :cron_expression, "must be a valid five-field cron expression")

      {:error, :unknown_preset} ->
        changeset
    end
  end

  defp validate_time_zone(changeset) do
    case resolved_time_zone(changeset) do
      "" ->
        add_error(changeset, :other_time_zone, "can't be blank")

      time_zone ->
        if valid_time_zone?(time_zone) do
          changeset
        else
          field =
            if get_field(changeset, :time_zone) == @other, do: :other_time_zone, else: :time_zone

          add_error(changeset, field, "is not a known IANA time zone")
        end
    end
  end

  defp collect_occurrences(_cron, _from, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_occurrences(cron, from, count, acc) do
    with %DateTime{} = candidate <- Oban.Cron.Expression.next_at(cron, from),
         {:ok, local} <- resolve_wall_clock(candidate, from.time_zone),
         {:ok, utc} <- DateTime.shift_zone(local, "Etc/UTC", Tz.TimeZoneDatabase) do
      collect_occurrences(cron, local, count - 1, [%{local: local, utc: utc} | acc])
    else
      _invalid -> {:error, :invalid_schedule}
    end
  end

  defp resolve_wall_clock(candidate, time_zone) do
    case DateTime.from_naive(DateTime.to_naive(candidate), time_zone, Tz.TimeZoneDatabase) do
      {:ok, local} -> {:ok, local}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _before, after_gap} -> {:ok, after_gap}
      error -> error
    end
  end

  defp parse_time(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{1,2}):(\d{2})\z/, String.trim(value)) do
      [_all, hour, minute] ->
        case Time.new(String.to_integer(hour), String.to_integer(minute), 0) do
          {:ok, time} -> {:ok, time}
          _invalid -> {:error, :invalid_time}
        end

      nil ->
        {:error, :invalid_time}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_time}

  defp preset_days("daily", _weekday), do: {:ok, "*"}
  defp preset_days("weekdays", _weekday), do: {:ok, "1-5"}
  defp preset_days("weekly", weekday) when weekday in 0..6, do: {:ok, to_string(weekday)}
  defp preset_days("weekly", _weekday), do: {:error, :invalid_weekday}

  defp hourly?(expression) do
    String.trim(expression) in ["0 * * * *", "@hourly"]
  end

  defp preset(name, hour, minute, weekday) do
    %{
      preset: name,
      time:
        :io_lib.format("~2..0B:~2..0B", [String.to_integer(hour), String.to_integer(minute)])
        |> to_string(),
      weekday: weekday
    }
  end

  defp preset(name), do: %{preset: name, time: nil, weekday: nil}
end
