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

  setup do
    workspace = TestGitWorkspace.configure_dispatch!("ptc-manager-herdr-adapter")
    scenario = start_supervised!(TestScenario) |> TestScenario.gateway()

    leased =
      TestScenario.leased_implementation!(scenario,
        number: 27,
        local_path: workspace.repository
      )

    %{leased: leased, workspace: workspace}
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

  test "a Herdr failure without the worktree error contract stays uncertain", %{leased: leased} do
    command = %HerdrCommandStub{
      worktree_create_result: {:error, {:herdr_exit, 1, "herdr: connection refused"}}
    }

    assert {:error,
            {:uncertain,
             {:worktree_create_unconfirmed, {:herdr_exit, 1, "herdr: connection refused"},
              :enoent}}} = dispatch(leased, command)
  end

  test "a Codex implementation agent trusts the checkout and its worktree", %{
    leased: leased,
    workspace: workspace
  } do
    worktree_path = leased.worktree_allocation.path
    configured = Application.get_env(:ptc_manager, :implementation_agent_args)

    assert HerdrAdapter.agent_arguments("codex", [workspace.repository, worktree_path]) ==
             configured ++
               [
                 "-c",
                 ~s(projects={"#{workspace.repository}"={trust_level="trusted"},) <>
                   ~s("#{worktree_path}"={trust_level="trusted"}})
               ]

    assert HerdrAdapter.agent_arguments("codex", []) == configured
    assert HerdrAdapter.agent_arguments("claude", [workspace.repository]) == configured
  end

  defp dispatch(leased, command) do
    HerdrAdapter.dispatch(
      %{job: leased, issue: leased.issue, repository: leased.repository},
      command: command
    )
  end
end
