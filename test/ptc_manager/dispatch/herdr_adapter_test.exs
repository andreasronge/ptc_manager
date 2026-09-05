defmodule PtcManager.Dispatch.HerdrAdapterTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Dispatch.HerdrAdapter
  alias PtcManager.TestGitWorkspace
  alias PtcManager.TestScenario

  defmodule HerdrCommandStub do
    @moduledoc false
    defstruct [:worktree_create_result]

    def run(
          %__MODULE__{worktree_create_result: result},
          ["worktree", "create" | _options],
          _timeout
        ),
        do: result

    def run(%__MODULE__{}, args, _timeout), do: {:error, {:unexpected_test_herdr_command, args}}
  end

  defmodule WorktreeRemoveStub do
    @moduledoc false
    defstruct [:result]

    def run(%__MODULE__{result: result}, ["worktree", "remove" | _options], _timeout), do: result

    def run(%__MODULE__{}, args, _timeout), do: {:error, {:unexpected_test_herdr_command, args}}
  end

  setup do
    workspace = TestGitWorkspace.configure_dispatch!("ptc-manager-herdr-adapter")
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    %{scenario: scenario, workspace: workspace}
  end

  describe "discarding a retained worktree" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "ptc-manager-forgotten-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(path)
      on_exit(fn -> File.rm_rf!(path) end)

      %{allocation: %{herdr_workspace: "w3V", path: path}}
    end

    test "a workspace Herdr has forgotten is separated from a removal that failed", %{
      allocation: allocation
    } do
      forgotten =
        {:error,
         {:herdr_exit, 1,
          ~s({"error":{"code":"workspace_not_found","message":"workspace w3V not found"},) <>
            ~s("id":"cli:worktree:remove"})}}

      assert {:error, :worktree_workspace_forgotten} =
               HerdrAdapter.remove_worktree(allocation,
                 command: %WorktreeRemoveStub{result: forgotten}
               )

      assert {:error, :worktree_workspace_forgotten} =
               HerdrAdapter.discard_worktree(allocation,
                 command: %WorktreeRemoveStub{result: forgotten}
               )
    end

    test "a genuine removal failure still surfaces the Herdr error", %{allocation: allocation} do
      busy = {:error, {:herdr_exit, 1, "workspace busy"}}

      assert {:error, {:herdr_exit, 1, "workspace busy"}} =
               HerdrAdapter.discard_worktree(allocation,
                 command: %WorktreeRemoveStub{result: busy}
               )
    end
  end

  describe "worktree creation" do
    setup %{scenario: scenario, workspace: workspace} do
      leased =
        TestScenario.leased_implementation!(scenario,
          number: 27,
          local_path: workspace.repository
        )

      %{leased: leased}
    end

    test "a completed Herdr worktree failure with nothing at the reserved path ends safely", %{
      leased: leased
    } do
      git_error =
        "Preparing worktree (new branch '#{leased.branch_name}')\n" <>
          "fatal: cannot lock ref 'refs/heads/#{leased.branch_name}': " <>
          "unable to create directory for .git/refs/heads/#{leased.branch_name}"

      command = %HerdrCommandStub{
        worktree_create_result:
          {:error, {:herdr_exit, 1, TestGitWorkspace.herdr_worktree_create_error(git_error)}}
      }

      assert {:error, {:safe, {:worktree_create_failed, ^git_error}}} = dispatch(leased, command)
      refute File.exists?(leased.worktree_allocation.path)
    end

    test "an unacknowledged Herdr worktree command stays uncertain", %{leased: leased} do
      command = %HerdrCommandStub{worktree_create_result: {:error, :herdr_timeout}}

      assert {:error, {:uncertain, {:worktree_create_unconfirmed, :herdr_timeout, :enoent}}} =
               dispatch(leased, command)
    end

    test "a Herdr failure without the worktree error contract stays uncertain", %{
      leased: leased
    } do
      command = %HerdrCommandStub{
        worktree_create_result: {:error, {:herdr_exit, 1, "herdr: connection refused"}}
      }

      assert {:error,
              {:uncertain,
               {:worktree_create_unconfirmed, {:herdr_exit, 1, "herdr: connection refused"},
                :enoent}}} = dispatch(leased, command)
    end
  end

  describe "agent start" do
    test "the implementation agent is the kind its lease recorded, with that profile's arguments",
         %{scenario: scenario, workspace: workspace} do
      put_agent_profiles(%{
        "codex" => %{"enabled" => true, "args" => ["--dangerously-bypass-approvals-and-sandbox"]},
        "cursor" => %{"enabled" => true, "args" => ["--force", "--trust"]}
      })

      repository_fixture(%{local_path: workspace.repository})

      {:ok, _} =
        PtcManager.ExecutionProfiles.save(
          "small",
          %{"kind" => "cursor", "model" => "cursor-grok-4.6-high"},
          "maintainer"
        )

      leased =
        TestScenario.leased_implementation!(scenario,
          number: 28,
          local_path: workspace.repository
        )

      assert leased.worktree_allocation.agent_kind == "cursor"

      command_pid = start_supervised!({TestGitWorkspace.HerdrCommand, {workspace, scenario}})
      command = TestGitWorkspace.HerdrCommand.gateway(command_pid)

      assert {:ok, %{agent_kind: "cursor"}} = dispatch(leased, command)

      assert [
               [
                 "agent",
                 "start",
                 "impl_j" <> _,
                 "--kind",
                 "cursor",
                 "--pane",
                 _pane,
                 "--timeout",
                 _timeout,
                 "--",
                 "--force",
                 "--trust",
                 "--model",
                 "cursor-grok-4.6-high"
               ]
             ] = TestGitWorkspace.HerdrCommand.agent_starts(command)
    end

    test "a Codex worktree agent trusts the checkout and the worktree instead of one workspace",
         %{workspace: workspace} do
      put_agent_profiles(%{
        "codex" => %{
          "enabled" => true,
          "args" => [
            "--dangerously-bypass-approvals-and-sandbox",
            "-c",
            ~s(projects={{{workspace_path_toml}}={trust_level="trusted"}})
          ]
        },
        "cursor" => %{"enabled" => true, "args" => ["--force", "--trust", "{{workspace_path}}"]}
      })

      worktree_path = Path.join(workspace.worktree_root, "job-1")
      trusted = [workspace.repository, worktree_path]

      # Replacing the profile's own -c projects= override must not take the
      # model with it: the trust rewrite drops matched pairs, not the tail.
      assert HerdrAdapter.agent_arguments("codex", worktree_path, trusted) ==
               [
                 "--dangerously-bypass-approvals-and-sandbox",
                 "--model",
                 "gpt-5.6-sol",
                 "-c",
                 ~s(projects={"#{workspace.repository}"={trust_level="trusted"},) <>
                   ~s("#{worktree_path}"={trust_level="trusted"}})
               ]

      assert HerdrAdapter.agent_arguments("cursor", worktree_path, trusted) ==
               ["--force", "--trust", worktree_path, "--model", "cursor-grok-4.6-high"]
    end
  end

  defp dispatch(leased, command) do
    {source_sha, 0} =
      System.cmd("git", ["-C", leased.repository.local_path, "rev-parse", "HEAD"],
        stderr_to_stdout: true
      )

    HerdrAdapter.dispatch(
      %{
        job: leased,
        issue: leased.issue,
        repository: leased.repository,
        source: %{sha: String.trim(source_sha), ref: "refs/remotes/origin/main"}
      },
      command: command
    )
  end
end
