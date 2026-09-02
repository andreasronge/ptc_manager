defmodule PtcManager.Automations.ScheduleTest do
  use ExUnit.Case, async: true

  alias PtcManager.Automations.Schedule

  test "presets round-trip through cron expressions" do
    assert {:ok, "0 3 * * *"} = Schedule.build_cron("daily", time: "03:00")
    assert {:ok, "30 7 * * 1-5"} = Schedule.build_cron("weekdays", time: "7:30")
    assert {:ok, "15 9 * * 3"} = Schedule.build_cron("weekly", time: "09:15", weekday: 3)
    assert {:ok, "0 * * * *"} = Schedule.build_cron("hourly", [])

    assert {:ok, "*/15 * * * *"} =
             Schedule.build_cron("custom", cron_expression: " */15 * * * * ")

    assert {:error, :invalid_time} = Schedule.build_cron("daily", time: "25:00")
    assert {:error, :invalid_weekday} = Schedule.build_cron("weekly", time: "09:00", weekday: 9)
    assert {:error, :invalid_cron} = Schedule.build_cron("custom", cron_expression: "@reboot")

    assert %{preset: "daily", time: "03:00"} = Schedule.detect_preset("0 3 * * *")
    assert %{preset: "weekdays", time: "07:30"} = Schedule.detect_preset("30 7 * * 1-5")
    assert %{preset: "weekly", time: "09:15", weekday: 3} = Schedule.detect_preset("15 9 * * 3")
    assert %{preset: "hourly"} = Schedule.detect_preset("0 * * * *")
    assert %{preset: "custom"} = Schedule.detect_preset("*/15 * * * *")
    assert %{preset: "custom"} = Schedule.detect_preset("0 3 1 * *")
  end

  test "describes schedules in plain language" do
    assert Schedule.describe("0 3 * * *") == "Every day at 03:00"
    assert Schedule.describe("30 7 * * 1-5") == "Weekdays at 07:30"
    assert Schedule.describe("15 9 * * 0") == "Every Sunday at 09:15"
    assert Schedule.describe("0 * * * *") == "Every hour"
    assert Schedule.describe("*/15 * * * *") == "Cron */15 * * * *"
  end

  test "validates time zones against the Tz database" do
    assert Schedule.valid_time_zone?("Europe/Stockholm")
    assert Schedule.valid_time_zone?("Etc/UTC")
    refute Schedule.valid_time_zone?("Mars/Olympus")
    refute Schedule.valid_time_zone?("")
    refute Schedule.valid_time_zone?(nil)
  end

  test "next occurrences keep the wall-clock time across a daylight-saving change" do
    assert {:ok, autumn} =
             Schedule.next_occurrences(
               "0 3 * * *",
               "Europe/Stockholm",
               ~U[2026-10-23 12:00:00Z],
               3
             )

    assert Enum.map(autumn, &DateTime.to_iso8601(&1.local)) ==
             [
               "2026-10-24T03:00:00+02:00",
               "2026-10-25T03:00:00+01:00",
               "2026-10-26T03:00:00+01:00"
             ]

    assert Enum.map(autumn, &DateTime.to_iso8601(&1.utc)) ==
             ["2026-10-24T01:00:00Z", "2026-10-25T02:00:00Z", "2026-10-26T02:00:00Z"]

    assert {:ok, spring} =
             Schedule.next_occurrences(
               "0 3 * * *",
               "Europe/Stockholm",
               ~U[2026-03-27 12:00:00Z],
               2
             )

    assert Enum.map(spring, &DateTime.to_iso8601(&1.utc)) ==
             ["2026-03-28T02:00:00Z", "2026-03-29T01:00:00Z"]

    assert {:ok, ~U[2026-10-25 02:00:00Z]} =
             Schedule.next_run_at("0 3 * * *", "Europe/Stockholm", ~U[2026-10-24 12:00:00Z])

    assert {:error, :invalid_schedule} =
             Schedule.next_run_at("0 3 * * *", "Mars/Olympus", ~U[2026-10-24 12:00:00Z])

    assert {:error, :invalid_schedule} =
             Schedule.next_run_at("@reboot", "Etc/UTC", ~U[2026-10-24 12:00:00Z])
  end

  test "the editor form opens on the stored preset and stores what it shows" do
    trigger = %{cron_expression: "15 9 * * 3", time_zone: "Asia/Tokyo"}

    assert %{
             "preset" => "weekly",
             "time" => "09:15",
             "weekday" => "3",
             "time_zone" => "other",
             "other_time_zone" => "Asia/Tokyo"
           } =
             Schedule.params(trigger)

    changeset = Schedule.changeset(Schedule.params(trigger))
    assert changeset.valid?

    assert {:ok,
            %{
              cron_expression: "15 9 * * 3",
              time_zone: "Asia/Tokyo",
              label: "Every Wednesday at 09:15"
            }} =
             Schedule.trigger_attrs(changeset)

    assert [_first, _second, _third] = Schedule.preview(changeset, ~U[2026-09-02 12:00:00Z])

    invalid =
      Schedule.changeset(%{
        "preset" => "daily",
        "time" => "9",
        "time_zone" => "other",
        "other_time_zone" => ""
      })

    assert {"must be a time such as 03:00", _opts} = invalid.errors[:time]
    assert {"can't be blank", _opts} = invalid.errors[:other_time_zone]
    assert Schedule.preview(invalid) == []
  end
end
