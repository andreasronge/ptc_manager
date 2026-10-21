defmodule PtcManager.Machine.RequirementsTest do
  use ExUnit.Case, async: true

  alias PtcManager.Machine.{Requirements, ToolInventory}
  alias PtcManager.Operations.Repository

  @now ~U[2026-10-20 12:00:00Z]

  defp context(context, probes, captured_at \\ @now) do
    {:ok, parsed} =
      ToolInventory.parse(
        %{"captured_at" => DateTime.to_iso8601(captured_at), "probes" => probes},
        context
      )

    parsed
  end

  defp probe(name, exit_status, stdout \\ ""),
    do: %{"name" => name, "exit_status" => exit_status, "stdout" => stdout}

  defp inventory(pane, setup), do: %{contexts: %{"pane" => pane, "setup" => setup}}

  defp changeset(requirements),
    do:
      Repository.changeset(%Repository{}, %{
        github_owner: "o",
        github_name: "n",
        machine_requirements: requirements
      })

  test "no requirements are always satisfied, even with no inventory" do
    assert %{satisfied?: true, lines: []} =
             Requirements.evaluate(Requirements.empty(), inventory(nil, nil), @now)

    assert %{satisfied?: true} = Requirements.evaluate(nil, inventory(nil, nil), @now)
  end

  test "a line is satisfied only when every context satisfies it" do
    requirements = %{
      "tools" => [
        %{"name" => "docker-daemon"},
        %{"name" => "docker-compose", "version" => ">= 2.24.0"}
      ]
    }

    pane = context("pane", [probe("docker-daemon", 1), probe("docker-compose", 0, "2.33.1\n")])

    setup =
      context("setup", [
        probe("docker-daemon", 0, "27.5.1\n"),
        probe("docker-compose", 0, "2.20.0\n")
      ])

    evaluation = Requirements.evaluate(requirements, inventory(pane, setup), @now)
    refute evaluation.satisfied?

    [daemon, compose] = evaluation.lines
    assert [%{"context" => "pane", "reason" => "unreachable"}] = daemon["failures"]

    assert [%{"context" => "setup", "reason" => "version", "detail" => "2.20.0"}] =
             compose["failures"]

    assert Requirements.explain(evaluation) ==
             "docker-daemon not reachable (pane); docker-compose version does not match >= 2.24.0 (setup)"
  end

  test "missing, stale, and unprobed contexts each have their own reason" do
    requirements = %{"tools" => [%{"name" => "psql"}]}
    old = DateTime.add(@now, -3_600, :second)

    evaluation =
      Requirements.evaluate(
        requirements,
        inventory(
          context("pane", [], old),
          context("setup", [%{"name" => "psql", "error" => "not_found"}])
        ),
        @now
      )

    assert [
             %{
               "failures" => [
                 %{"context" => "pane", "reason" => "stale"},
                 %{"context" => "setup", "reason" => "missing"}
               ]
             }
           ] =
             evaluation.lines

    assert [%{"failures" => [%{"reason" => "no_inventory"}, %{"reason" => "no_inventory"}]}] =
             Requirements.evaluate(requirements, inventory(nil, nil), @now).lines

    assert [%{"failures" => [%{"reason" => "no_inventory", "context" => "pane"}]}] =
             Requirements.evaluate(
               requirements,
               inventory(
                 context("pane", []),
                 context("setup", [probe("psql", 0, "psql (PostgreSQL) 16.4\n")])
               ),
               @now
             ).lines
  end

  test "a present tool whose version cannot be read fails a version requirement" do
    requirements = %{"tools" => [%{"name" => "node", "version" => "~> 22.0"}]}
    pane = context("pane", [probe("node", 0, "weird\n")])
    setup = context("setup", [probe("node", 0, "v22.23.2\n")])

    assert [%{"failures" => [%{"context" => "pane", "reason" => "version", "detail" => nil}]}] =
             Requirements.evaluate(requirements, inventory(pane, setup), @now).lines
  end

  test "an unparsable version from another machine fails the line instead of raising" do
    requirements = %{"tools" => [%{"name" => "node", "version" => ">= 1.0.0"}]}

    summary = %{
      "captured_at" => DateTime.to_iso8601(@now),
      "tools" => %{"node" => %{"status" => "ok", "version" => "unknown"}}
    }

    contexts = ToolInventory.from_summary(%{"pane" => summary, "setup" => summary})

    assert [%{"failures" => [%{"reason" => "version", "detail" => "unknown"} | _]}] =
             Requirements.evaluate(requirements, %{contexts: contexts}, @now).lines
  end

  test "validation accepts known tools with valid requirements and refuses the rest" do
    assert changeset(%{
             "tools" => [
               %{"name" => "docker-daemon"},
               %{"name" => "node", "version" => ">= 22.0.0"}
             ]
           }).valid?

    refute changeset(%{"tools" => [%{"name" => "terraform"}]}).valid?
    refute changeset(%{"tools" => [%{"name" => "node", "version" => "newest"}]}).valid?
    refute changeset(%{"tools" => [%{"name" => "node"}, %{"name" => "node"}]}).valid?
    refute changeset(%{"tools" => [%{"name" => "node", "shell" => "x"}]}).valid?
    refute changeset(%{"tools" => "docker"}).valid?
    refute changeset(%{"tools" => List.duplicate(%{"name" => "git"}, 21)}).valid?
  end

  test "normalize drops blank versions and the revision is stable" do
    assert Requirements.normalize([
             %{"name" => " git ", "version" => " "},
             %{"name" => "node", "version" => ">= 22.0.0"}
           ]) ==
             %{"tools" => [%{"name" => "git"}, %{"name" => "node", "version" => ">= 22.0.0"}]}

    assert Requirements.revision(%{"tools" => [%{"name" => "git"}]}) ==
             Requirements.revision(%{"tools" => [%{"name" => "git"}]})

    refute Requirements.revision(%{"tools" => [%{"name" => "git"}]}) ==
             Requirements.revision(Requirements.empty())
  end
end
