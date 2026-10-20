defmodule PtcManager.Cluster.MoveTest do
  use PtcManager.DataCase, async: false

  import PtcManager.ClusterCase

  alias PtcManager.{AgentEnvironmentVariables, Automations}
  alias PtcManager.Automations.{Definition, DefinitionVersion, Trigger}
  alias PtcManager.Cluster.{Move, RepositorySettings}
  alias PtcManager.Operations
  alias PtcManager.Operations.{AuditEvent, Repository}
  alias PtcManager.TestPeerClient

  test "every repository setting either moves or is deliberately left behind" do
    covered = RepositorySettings.transferred_fields() ++ RepositorySettings.excluded_fields()

    assert Enum.sort(covered) == Enum.sort(Repository.cast_fields()),
           "a field of Repository.changeset/2 is neither transferred nor excluded by RepositorySettings"

    assert RepositorySettings.transferred_fields() -- RepositorySettings.excluded_fields() ==
             RepositorySettings.transferred_fields()
  end

  test "export carries settings, current automation versions, triggers, and variable names only" do
    repository =
      repository_fixture(%{github_owner: "Acme", github_name: "Api", required_pre_pr_reviews: 1})

    {:ok, _variable} =
      AgentEnvironmentVariables.put(
        repository.id,
        %{"name" => "API_TOKEN", "value" => "s3cr3t-value"},
        "maintainer"
      )

    document = RepositorySettings.export(Repo.get!(Repository, repository.id))

    assert document["repository"] == "acme/api"
    assert document["settings"]["required_pre_pr_reviews"] == 1
    refute Map.has_key?(document["settings"], "local_path")
    refute Map.has_key?(document["settings"], "enabled")
    assert document["agent_environment_variable_names"] == ["API_TOKEN"]
    refute Jason.encode!(document) =~ "s3cr3t-value"
    assert document["automations"] != []
    assert Enum.all?(document["automations"], &is_map(&1["version"]))
    assert document["digest"] == RepositorySettings.digest(document)
  end

  test "import updates seeded automations as new versions and pauses everything" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    document = RepositorySettings.export(Repo.get!(Repository, repository.id))

    [first | _rest] = document["automations"]
    edited_prompt = "Edited on the source machine."

    document =
      document
      |> put_in(["settings", "required_pre_pr_reviews"], 3)
      |> Map.put("automations", [
        first
        |> put_in(["version", "prompt"], edited_prompt)
        |> Map.put("triggers", [
          %{
            "trigger_type" => "schedule",
            "surface" => "automations",
            "label" => "Nightly",
            "configuration" => %{},
            "cron_expression" => "0 3 * * *",
            "time_zone" => "Europe/Stockholm"
          }
        ])
      ])
      |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))
      # Over the wire every key is a string.
      |> Jason.encode!()
      |> Jason.decode!()

    definition = Repo.get_by!(Definition, repository_id: repository.id, key: first["key"])

    versions_before =
      Repo.aggregate(
        from(v in DefinitionVersion, where: v.automation_definition_id == ^definition.id),
        :count
      )

    assert :ok =
             Repo.transaction(fn ->
               RepositorySettings.import(document, Repo.get!(Repository, repository.id), %{
                 actor: "maintainer",
                 source: "beta",
                 checks: []
               })
             end)
             |> elem(1)

    assert Repo.get!(Repository, repository.id).required_pre_pr_reviews == 3

    definition =
      Repo.get!(Definition, definition.id) |> Repo.preload([:current_version, :triggers])

    refute definition.enabled
    assert definition.current_version.prompt == edited_prompt

    assert Repo.aggregate(
             from(v in DefinitionVersion, where: v.automation_definition_id == ^definition.id),
             :count
           ) ==
             versions_before + 1

    assert [%Trigger{label: "Nightly", enabled: false, time_zone: "Europe/Stockholm"}] =
             definition.triggers

    assert Repo.get_by!(AuditEvent, action: "repository.settings_imported").details["source"] ==
             "beta"

    # A definition with the same key is updated, never duplicated.
    assert Repo.aggregate(
             from(d in Definition,
               where: d.repository_id == ^repository.id and d.key == ^first["key"]
             ),
             :count
           ) == 1
  end

  test "a malformed automation changes nothing" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    document = RepositorySettings.export(Repo.get!(Repository, repository.id))
    [first | _rest] = document["automations"]

    document =
      document
      |> Map.put("automations", [Map.put(first, "triggers", [%{"trigger_type" => "nonsense"}])])
      |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))

    assert {:error, {:invalid_automation, _key}} =
             Repo.transaction(fn ->
               case RepositorySettings.import(document, Repo.get!(Repository, repository.id), %{
                      actor: "maintainer",
                      source: "beta",
                      checks: []
                    }) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    refute Repo.exists?(
             from event in AuditEvent, where: event.action == "repository.settings_imported"
           )
  end

  test "malformed nested peer data is refused before it is shown or imported" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    document = RepositorySettings.export(Repo.get!(Repository, repository.id))
    [first | _rest] = document["automations"]

    for {change, reason} <- [
          {%{"agent_environment_variable_names" => [%{}]}, :invalid_variable_names},
          {%{"agent_environment_variable_names" => ["A", "A"]}, :invalid_variable_names},
          {%{"automations" => [first, first]}, :invalid_automations},
          {%{"automations" => [Map.put(first, "triggers", "daily")]}, :invalid_automations},
          {%{"automations" => [Map.put(first, "version", "v1")]}, :invalid_automations},
          {%{"automations" => ["x"]}, :invalid_automations}
        ] do
      malformed =
        document
        |> Map.merge(change)
        |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))

      assert {:error, ^reason} = RepositorySettings.validate(malformed, repository)
    end
  end

  test "a claim pauses automations the source did not send too" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    document = RepositorySettings.export(Repo.get!(Repository, repository.id))

    seeded =
      Repo.get_by!(Definition,
        repository_id: repository.id,
        key: hd(document["automations"])["key"]
      )

    version = Repo.preload(seeded, :current_version).current_version

    {:ok, target_only} =
      Automations.create_definition(
        repository,
        %{
          key: "target_only",
          name: "Target only",
          description: "Only on the target",
          enabled: true
        },
        Map.take(version, DefinitionVersion.content_fields()),
        "maintainer"
      )

    {:ok, trigger} =
      Automations.create_trigger(target_only, %{
        trigger_type: "manual",
        surface: "automations",
        label: "Run now",
        enabled: true,
        configuration: %{}
      })

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               RepositorySettings.import(document, Repo.get!(Repository, repository.id), %{
                 actor: "maintainer",
                 source: "beta",
                 checks: []
               })
             end)

    refute Repo.get!(Definition, target_only.id).enabled
    refute Repo.get!(Trigger, trigger.id).enabled
  end

  test "a document that was altered or names another repository is refused" do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    document = RepositorySettings.export(Repo.get!(Repository, repository.id))

    tampered = put_in(document, ["settings", "default_branch"], "evil")
    assert {:error, :settings_digest_mismatch} = RepositorySettings.validate(tampered, repository)

    other = repository_fixture(%{github_owner: "acme", github_name: "other"})

    assert {:error, :settings_for_another_repository} =
             RepositorySettings.validate(document, other)
  end

  describe "claiming from another member" do
    setup do
      checkout = Path.join(System.tmp_dir!(), "ptc-move-#{System.unique_integer([:positive])}")
      File.mkdir_p!(checkout)
      on_exit(fn -> File.rm_rf!(checkout) end)
      %{checkout: checkout}
    end

    defp source_document(repository, overrides) do
      repository
      |> RepositorySettings.export()
      |> Map.update!("settings", &Map.merge(&1, overrides))
      |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))
    end

    defp beta(document, claim \\ "none") do
      fn
        "/api/peer/v1/status", _headers ->
          {200,
           TestPeerClient.status("beta", %{
             "repositories" => [%{"repository" => "acme/api", "claim" => claim}]
           })}

        "/api/peer/v1/repositories/acme/api/settings", _headers ->
          {200, document}
      end
    end

    test "copies the source's settings in the claim and lists the secrets to re-enter", %{
      checkout: checkout
    } do
      repository =
        repository_fixture(%{github_owner: "acme", github_name: "api", local_path: checkout})

      document = source_document(repository, %{"auto_fix_daily_limit" => 9})

      document =
        document
        |> Map.put("agent_environment_variable_names", ["API_TOKEN"])
        |> then(&Map.put(&1, "digest", RepositorySettings.digest(&1)))

      join_cluster!(%{
        "beta" => beta(document),
        "gamma" => fn _p, _h -> {200, TestPeerClient.status("gamma")} end
      })

      repository = repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

      assert Move.ready?(repository)
      assert {:ok, %{diff: diff}} = Move.preview(repository, "beta")
      assert [%{field: :auto_fix_daily_limit, incoming: 9}] = diff.settings
      assert diff.variables_to_enter == ["API_TOKEN"]

      assert {:ok, claimed, checks} =
               Move.claim(repository.id, "beta", document["digest"], "maintainer")

      assert claimed.enabled
      assert Repo.get!(Repository, repository.id).auto_fix_daily_limit == 9
      assert Enum.all?(checks, &(&1["result"] == "clear"))

      assert Enum.all?(Automations.list_definitions(claimed), &(not &1.enabled))
    end

    test "is refused while the source still claims the repository", %{checkout: checkout} do
      repository =
        repository_fixture(%{github_owner: "acme", github_name: "api", local_path: checkout})

      document = source_document(repository, %{})

      join_cluster!(%{
        "beta" => beta(document, "live_work"),
        "gamma" => fn _p, _h -> {200, TestPeerClient.status("gamma")} end
      })

      repository = repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

      assert {:error, :claim_refused, checks} =
               Move.claim(repository.id, "beta", document["digest"], "maintainer")

      assert %{"result" => "claimed"} = Enum.find(checks, &(&1["machine_id"] == "beta"))
      refute Repo.get!(Repository, repository.id).enabled
    end

    test "asks the maintainer to look again when the settings changed", %{checkout: checkout} do
      repository =
        repository_fixture(%{github_owner: "acme", github_name: "api", local_path: checkout})

      document = source_document(repository, %{"auto_fix_daily_limit" => 9})

      join_cluster!(%{
        "beta" => beta(document),
        "gamma" => fn _p, _h -> {200, TestPeerClient.status("gamma")} end
      })

      repository = repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

      assert {:error, :settings_changed, []} =
               Move.claim(repository.id, "beta", "stale-digest", "maintainer")

      refute Repo.get!(Repository, repository.id).enabled
    end

    test "is refused on a machine that is not ready" do
      repository =
        repository_fixture(%{
          github_owner: "acme",
          github_name: "api",
          local_path: "/nonexistent/acme-api"
        })

      join_cluster!(%{})
      repository = repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()

      refute Move.ready?(repository)

      assert {:error, :target_not_ready, []} =
               Move.claim(repository.id, "beta", "digest", "maintainer")
    end
  end

  test "the settings endpoint serves only a repository this member gave up", %{} do
    repository = repository_fixture(%{github_owner: "acme", github_name: "api"})
    join_cluster!(%{})

    conn = settings_request()
    assert conn.status == 409
    assert %{"error" => "claimed", "claim" => "enabled"} = Jason.decode!(conn.resp_body)

    repository |> Repository.changeset(%{enabled: false}) |> Repo.update!()
    conn = settings_request()
    assert conn.status == 200
    assert %{"repository" => "acme/api", "digest" => _digest} = Jason.decode!(conn.resp_body)

    Operations.remove_repository(repository.id)
    assert settings_request().status == 404
  end

  defp settings_request do
    path = "/api/peer/v1/repositories/acme/api/settings"
    headers = PtcManager.Cluster.Signature.request_headers(secret(), "GET", path, "beta")

    headers
    |> Enum.reduce(Phoenix.ConnTest.build_conn(), fn {name, value}, conn ->
      Plug.Conn.put_req_header(conn, name, value)
    end)
    |> Phoenix.ConnTest.dispatch(PtcManagerWeb.Endpoint, :get, path)
  end
end
