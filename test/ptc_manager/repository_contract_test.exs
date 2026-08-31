defmodule PtcManager.Repository.ContractTest do
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias PtcManager.Operations.{Job, WorktreeAllocation}
  alias PtcManager.Repository.Contract

  @valid """
  version: 1
  bootstrap:
    command: ./scripts/ptc/bootstrap
    timeout_minutes: 10
  verification:
    before_publish: ./scripts/ci/pre-publication
    timeout_minutes: 45
  """

  test "parses the complete versioned contract" do
    assert {:ok, contract} = Contract.parse(@valid)
    assert contract.version == 1
    assert contract.bootstrap_command == "./scripts/ptc/bootstrap"
    assert contract.bootstrap_timeout_minutes == 10
    assert contract.before_publish_command == "./scripts/ci/pre-publication"
    assert contract.verification_timeout_minutes == 45
  end

  test "recomputes the frozen job digest and rejects changed gate fields" do
    contract = PtcManager.RepositoryContractFixture.contract()

    job = %Job{
      pre_publication_bootstrap_command: contract.bootstrap_command,
      pre_publication_bootstrap_timeout_ms: contract.bootstrap_timeout_minutes * 60_000,
      pre_publication_command: contract.before_publish_command,
      pre_publication_timeout_ms: contract.verification_timeout_minutes * 60_000,
      pre_publication_config_digest: Contract.publication_digest(contract)
    }

    assert {:ok, job.pre_publication_config_digest} == Contract.frozen_publication_digest(job)
    assert Contract.frozen_publication_digest_matches?(job)
    refute Contract.frozen_publication_digest_matches?(%{job | pre_publication_command: "true"})
  end

  test "rejects duplicate keys instead of silently accepting one value" do
    duplicate_top = @valid <> "\nversion: 1\n"

    duplicate_nested =
      String.replace(
        @valid,
        "  timeout_minutes: 10",
        "  timeout_minutes: 10\n  timeout_minutes: 11"
      )

    assert {:error, :duplicate_repository_contract_key} = Contract.parse(duplicate_top)
    assert {:error, :duplicate_repository_contract_key} = Contract.parse(duplicate_nested)
  end

  test "rejects multiple YAML documents" do
    assert {:error, :repository_contract_must_have_one_document} =
             Contract.parse(@valid <> "\n---\n" <> @valid)
  end

  test "loads only the canonical contract from an absolute repository path" do
    root = Path.join(System.tmp_dir!(), "ptc-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, ".ptc-manager.yml"), @valid)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, %Contract{before_publish_command: "./scripts/ci/pre-publication"}} =
             Contract.load(root)

    assert {:error, :repository_path_must_be_absolute} = Contract.load("relative/repository")
  end

  test "fails closed for missing files, malformed YAML, and unsupported versions" do
    root = Path.join(System.tmp_dir!(), "ptc-contract-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:error, :repository_contract_missing} = Contract.load(root)
    assert {:error, :invalid_repository_contract_yaml} = Contract.parse("verification: [")

    assert {:error, {:unsupported_contract_version, 2}} =
             Contract.parse(String.replace(@valid, "version: 1", "version: 2"))
  end

  test "rejects missing, unknown, multiline, and unbounded values" do
    assert {:error, {:unexpected_contract_keys, :verification}} =
             Contract.parse(String.replace(@valid, "  timeout_minutes: 45\n", ""))

    assert {:error, {:unexpected_contract_keys, :verification}} =
             Contract.parse(
               String.replace(
                 @valid,
                 "  timeout_minutes: 45",
                 "  timeout_minutes: 45\n  optional_gate: true"
               )
             )

    assert {:error, {:invalid_contract_command, :before_publish}} =
             Contract.parse(
               String.replace(
                 @valid,
                 "before_publish: ./scripts/ci/pre-publication",
                 "before_publish: |\n    mix test\n    mix format"
               )
             )

    assert {:error, {:invalid_contract_timeout, :verification}} =
             Contract.parse(String.replace(@valid, "timeout_minutes: 45", "timeout_minutes: 0"))
  end

  test "the checked-in PtcManager contract and executable entrypoints agree" do
    repository = Path.expand("../..", __DIR__)

    assert {:ok, contract} = Contract.load(repository)

    for command <- [contract.bootstrap_command, contract.before_publish_command] do
      [relative_path] = String.split(command, " ", trim: true)
      path = Path.join(repository, relative_path)
      assert File.regular?(path)
      assert {:ok, %{mode: mode}} = File.stat(path)
      assert band(mode, 0o111) != 0
    end
  end

  test "freezes the contract from the exact commit instead of a dirty filesystem copy" do
    root = Path.join(System.tmp_dir!(), "ptc-contract-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(root, ".ptc-manager.yml"), @valid)
    git!(root, ["add", ".ptc-manager.yml"])
    git!(root, ["commit", "-m", "add contract"])
    sha = git!(root, ["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(root, ".ptc-manager.yml"), "version: 99\n")

    job = %Job{worktree_allocation: %WorktreeAllocation{path: root}}
    assert {:ok, contract} = Contract.for_result(job, %{head_sha: sha})
    assert contract.before_publish_command == "./scripts/ci/pre-publication"
  end

  test "contract extraction ignores repository-controlled replacement refs" do
    root =
      Path.join(System.tmp_dir!(), "ptc-contract-replace-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(root, ["init", "-b", "main"])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "PtcManager Test"])
    File.write!(Path.join(root, ".ptc-manager.yml"), @valid)
    git!(root, ["add", ".ptc-manager.yml"])
    git!(root, ["commit", "-m", "trusted contract"])
    trusted_sha = git!(root, ["rev-parse", "HEAD"]) |> String.trim()

    weakened = String.replace(@valid, "./scripts/ci/pre-publication", "true")
    File.write!(Path.join(root, ".ptc-manager.yml"), weakened)
    git!(root, ["commit", "-am", "weaken contract"])
    replacement_sha = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    git!(root, ["replace", trusted_sha, replacement_sha])

    job = %Job{worktree_allocation: %WorktreeAllocation{path: root}}
    assert {:ok, contract} = Contract.for_result(job, %{head_sha: trusted_sha})
    assert contract.before_publish_command == "./scripts/ci/pre-publication"
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    output
  end
end
