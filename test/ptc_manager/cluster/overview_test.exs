defmodule PtcManager.Cluster.OverviewTest do
  use ExUnit.Case, async: true

  alias PtcManager.Cluster.Overview

  @now ~U[2026-10-20 12:00:00Z]

  defp inventory(daemon_status) do
    tools = %{"docker-daemon" => %{"status" => daemon_status, "version" => nil, "detail" => nil}}
    context = %{"captured_at" => "2026-10-20T11:59:00Z", "stale" => false, "tools" => tools}
    %{"pane" => context, "setup" => context}
  end

  defp machine(id, status),
    do: %{id: id, health: "healthy", status: status, error: nil, last_success_at: @now}

  defp status(overrides) do
    Map.merge(
      %{
        "membership_revision" => "r1",
        "protocol_version" => 1,
        "deployed_sha" => String.duplicate("a", 40),
        "execution_profiles" => %{"standard" => "d1"},
        "repositories" => [],
        "jobs" => [],
        "collection_runs" => [],
        "inventory" => inventory("ok")
      },
      overrides
    )
  end

  test "each repository has its home, live work, and a requirement result on every member" do
    requirements = [%{"name" => "docker-daemon"}]

    alpha =
      machine(
        "alpha",
        status(%{
          "repositories" => [
            %{"repository" => "acme/api", "claim" => "enabled", "requirements" => requirements}
          ],
          "jobs" => [
            %{
              "id" => 7,
              "repository" => "acme/api",
              "issue_number" => 3,
              "state" => "working",
              "url" => "u"
            }
          ]
        })
      )

    beta =
      machine(
        "beta",
        status(%{
          "inventory" => inventory("failed"),
          "repositories" => [
            %{"repository" => "acme/api", "claim" => "none", "requirements" => []}
          ]
        })
      )

    %{repositories: [repository]} = Overview.build([alpha, beta], @now)

    assert repository.key == "acme/api"
    assert repository.homes == ["alpha"]
    assert repository.requirements == requirements
    assert repository.results["alpha"].satisfied?
    refute repository.results["beta"].satisfied?
    assert repository.results["beta"].reason =~ "docker-daemon not reachable"
    assert [%{"id" => 7, "machine_id" => "alpha"}] = repository.work
  end

  test "drift flags membership, protocol, and profiles, and lists differing revisions" do
    alpha = machine("alpha", status(%{}))

    beta =
      machine(
        "beta",
        status(%{
          "membership_revision" => "r2",
          "protocol_version" => 2,
          "deployed_sha" => String.duplicate("b", 40),
          "execution_profiles" => %{"standard" => "d2"}
        })
      )

    drift = Overview.build([alpha, beta], @now).drift

    assert Enum.map(drift, &{&1.kind, &1.flagged?}) == [
             {"membership revision", true},
             {"protocol version", true},
             {"deployed revision", false},
             {"execution profile standard", true}
           ]

    assert Overview.build([alpha, machine("gamma", nil)], @now).drift == []
  end
end
