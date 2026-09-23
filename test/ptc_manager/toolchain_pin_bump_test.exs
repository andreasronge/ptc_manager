defmodule PtcManager.Toolchain.PinBumpTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.MaintainerActions.ActionAdapter
  alias PtcManager.MaintainerActions
  alias PtcManager.Toolchain.{Check, PinBump}

  @base_sha String.duplicate("a", 40)
  @head_sha String.duplicate("b", 40)

  defmodule Source do
    def latest(_repository), do: {:ok, String.duplicate("a", 40)}

    def content(_repository, sha, "deploy/toolchain-versions") do
      {:ok, Application.fetch_env!(:ptc_manager, :test_toolchain_manifests) |> Map.fetch!(sha)}
    end
  end

  defmodule PrClient do
    def get_json(url) do
      if String.contains?(url, "/files?"),
        do: {:ok, [%{"filename" => "deploy/toolchain-versions", "status" => "modified"}]},
        else: {:ok, Application.fetch_env!(:ptc_manager, :test_toolchain_pr)}
    end
  end

  setup do
    previous_source = Application.get_env(:ptc_manager, :deployment_revision_source)
    previous_pr = Application.get_env(:ptc_manager, :toolchain_pr_client)
    previous_repository = Application.get_env(:ptc_manager, :toolchain_repository)
    repository = repository_fixture()
    Application.put_env(:ptc_manager, :deployment_revision_source, Source)
    Application.put_env(:ptc_manager, :toolchain_pr_client, PrClient)

    Application.put_env(
      :ptc_manager,
      :toolchain_repository,
      repository.github_owner <> "/" <> repository.github_name
    )

    manifest = File.read!("deploy/toolchain-versions")
    Application.put_env(:ptc_manager, :test_toolchain_manifests, %{@base_sha => manifest})

    on_exit(fn ->
      restore(:deployment_revision_source, previous_source)
      restore(:toolchain_pr_client, previous_pr)
      restore(:toolchain_repository, previous_repository)
      Application.delete_env(:ptc_manager, :test_toolchain_manifests)
      Application.delete_env(:ptc_manager, :test_toolchain_pr)
    end)

    {:ok, repository: repository, manifest: manifest}
  end

  test "freezes one eligible update and verifies the exact draft PR", %{repository: repository} do
    current = PtcManager.Toolchain.pinned()["codex"]
    checked("codex", "0.999.0")
    assert {:ok, snapshot} = PinBump.prepare(repository, "codex")
    assert snapshot["current"] == current
    assert snapshot["version"] == "0.999.0"
    assert snapshot["source_sha"] == @base_sha
    assert String.contains?(snapshot["expected_manifest"], "codex=0.999.0\n")

    action = %{repository: repository, target_snapshot: snapshot}
    put_manifest(@head_sha, snapshot["expected_manifest"])
    Application.put_env(:ptc_manager, :test_toolchain_pr, pr(repository))
    assert :ok = PinBump.preflight(action)

    assert {:ok, %{pull_request: 42, head_sha: @head_sha}} =
             PinBump.verify(action, %{"pr_number" => 42})

    assert :ok =
             ActionAdapter.validate_result(
               %{
                 "outcome" => "completed",
                 "program" => "codex",
                 "version" => "0.999.0",
                 "digest" => nil,
                 "protocol" => nil,
                 "pr_number" => 42
               },
               "toolchain_pin_bump",
               snapshot
             )
  end

  test "reports major updates without approving a pin bump", %{repository: repository} do
    checked("pnpm", "12.0.0")
    assert {:error, :toolchain_update_not_eligible} = PinBump.prepare(repository, "pnpm")
  end

  test "freezes Herdr's version, protocol, and digest together", %{repository: repository} do
    digest = String.duplicate("c", 64)

    %Check{}
    |> Check.changeset(%{
      program: "herdr",
      version: "0.9.1",
      protocol: 23,
      digest: digest,
      status: "ok",
      checked_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, snapshot} = PinBump.prepare(repository, "herdr")
    assert snapshot["protocol"] == 23
    assert snapshot["digest"] == digest
    assert snapshot["expected_manifest"] =~ "herdr=0.9.1\n"
    assert snapshot["expected_manifest"] =~ "herdr_protocol=23\n"
    assert snapshot["expected_manifest"] =~ "herdr_sha256=#{digest}\n"

    assert {:error, :toolchain_result_mismatch} =
             ActionAdapter.validate_result(
               %{
                 "outcome" => "completed",
                 "program" => "herdr",
                 "version" => "0.9.1",
                 "digest" => String.duplicate("e", 64),
                 "protocol" => 23,
                 "pr_number" => 42
               },
               "toolchain_pin_bump",
               snapshot
             )
  end

  test "freezes Cursor's downloaded archive digest with its dated version", %{
    repository: repository,
    manifest: manifest
  } do
    source_manifest =
      Regex.replace(~r/^cursor_agent=[^\n]+$/m, manifest, "cursor_agent=2026.09.02-c22c1a3")

    put_manifest(@base_sha, source_manifest)
    digest = String.duplicate("d", 64)

    %Check{}
    |> Check.changeset(%{
      program: "cursor_agent",
      version: "2026.09.18-9a7762b",
      digest: digest,
      status: "ok",
      checked_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, snapshot} = PinBump.prepare(repository, "cursor_agent")
    assert snapshot["current"] == "2026.09.02-c22c1a3"
    assert snapshot["expected_manifest"] =~ "cursor_agent=2026.09.18-9a7762b\n"
    assert snapshot["expected_manifest"] =~ "cursor_agent_sha256=#{digest}\n"
  end

  test "queues the approved version as a durable maintainer action", %{repository: repository} do
    checked("codex", "0.999.0")

    assert {:ok, action} =
             MaintainerActions.enqueue_toolchain_bump(repository.id, "codex", "andreas")

    assert action.action_key == "toolchain_pin_bump"
    assert action.target_snapshot["version"] == "0.999.0"
    assert action.target_snapshot["source_sha"] == @base_sha
    assert action.prompt =~ "Approved manifest change: codex="
  end

  test "rejects a PR that changes any other manifest line", %{repository: repository} do
    checked("codex", "0.999.0")
    {:ok, snapshot} = PinBump.prepare(repository, "codex")
    altered = String.replace(snapshot["expected_manifest"], "pnpm=10.34.5", "pnpm=12.0.0")
    put_manifest(@head_sha, altered)
    Application.put_env(:ptc_manager, :test_toolchain_pr, pr(repository))

    assert {:terminal_error, :toolchain_pull_request_mismatch} =
             PinBump.verify(%{repository: repository, target_snapshot: snapshot}, %{
               "pr_number" => 42
             })
  end

  defp checked(program, version) do
    %Check{}
    |> Check.changeset(%{
      program: program,
      version: version,
      status: "ok",
      checked_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp put_manifest(sha, contents) do
    manifests = Application.fetch_env!(:ptc_manager, :test_toolchain_manifests)

    Application.put_env(
      :ptc_manager,
      :test_toolchain_manifests,
      Map.put(manifests, sha, contents)
    )
  end

  defp pr(repository) do
    full_name = repository.github_owner <> "/" <> repository.github_name

    %{
      "state" => "open",
      "draft" => true,
      "changed_files" => 1,
      "base" => %{
        "sha" => @base_sha,
        "ref" => repository.default_branch,
        "repo" => %{"full_name" => full_name}
      },
      "head" => %{"sha" => @head_sha, "repo" => %{"full_name" => full_name}}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:ptc_manager, key)
  defp restore(key, value), do: Application.put_env(:ptc_manager, key, value)
end
