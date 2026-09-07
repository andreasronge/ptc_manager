defmodule PtcManager.ReviewResumeCliTest do
  use ExUnit.Case, async: false

  @tag :nightly
  @tag :tmp_dir
  test "closed retained worktree is reopened from the parent repository", %{tmp_dir: root} do
    path = Path.join(root, "retained")
    File.mkdir_p!(path)
    binary = Path.join(root, "herdr")
    marker = Path.join(root, "opened-from-parent")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json, pathlib, sys
    args = sys.argv[3:]
    if args == ['agent', 'list']:
        print(json.dumps({'result': {'agents': []}}))
    elif args[:2] == ['worktree', 'open']:
        if args[args.index('--cwd') + 1] == #{Jason.encode!(root)} and args[args.index('--path') + 1] == #{Jason.encode!(path)}:
            pathlib.Path(#{Jason.encode!(marker)}).write_text('accepted')
        print(json.dumps({'error': {'code': 'test_open_failed'}}))
        sys.exit(1)
    else:
        sys.exit(2)
    """)

    File.chmod!(binary, 0o755)

    old =
      Map.new([:herdr_binary, :herdr_run_as_user], &{&1, Application.fetch_env(:ptc_manager, &1)})

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:ptc_manager, key, value)
          :error -> Application.delete_env(:ptc_manager, key)
        end
      end
    end)

    Application.put_env(:ptc_manager, :herdr_binary, binary)
    Application.put_env(:ptc_manager, :herdr_run_as_user, nil)

    job = %{
      fencing_token: 1,
      repository: %{local_path: root},
      agent_runs: [%{fencing_token: 1, agent_name: "retained", herdr_pane: "old:p1"}],
      worktree_allocation: %{path: path}
    }

    result = PtcManager.Dispatch.HerdrAdapter.resume_review_job(job)
    assert File.exists?(marker), "Herdr cannot reopen from a linked worktree source"
    assert {:error, {:continuation_not_started, {:herdr_exit, 1, _}}} = result
  end

  @tag :nightly
  @tag :tmp_dir
  test "retained continuation supplies the direction required by the Herdr CLI", %{tmp_dir: path} do
    binary = Path.join(path, "herdr")
    marker = Path.join(path, "accepted-split")

    File.write!(binary, """
    #!/usr/bin/env python3
    import json, pathlib, sys
    args = sys.argv[3:]
    if args == ['agent', 'list']:
        print(json.dumps({'result': {'agents': [{'name': 'retained', 'pane_id': 'w1:p1',
              'workspace_id': 'w1', 'cwd': #{Jason.encode!(path)}, 'agent_status': 'idle'}]}}))
    elif args[:2] == ['pane', 'split']:
        if '--direction' not in args or args[args.index('--direction') + 1] not in ['right', 'down']:
            sys.exit(2)
        pathlib.Path(#{Jason.encode!(marker)}).write_text('accepted')
        print(json.dumps({'result': {'pane': {'pane_id': 'w1:p2'}}}))
    else:
        # Stop before starting an agent: an unsuccessful close must preserve the old owner.
        sys.exit(1)
    """)

    File.chmod!(binary, 0o755)
    keys = [:herdr_binary, :herdr_run_as_user]
    old = Map.new(keys, &{&1, Application.fetch_env(:ptc_manager, &1)})

    on_exit(fn ->
      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:ptc_manager, key, value)
          :error -> Application.delete_env(:ptc_manager, key)
        end
      end
    end)

    Application.put_env(:ptc_manager, :herdr_binary, binary)
    Application.put_env(:ptc_manager, :herdr_run_as_user, nil)

    job = %{
      fencing_token: 1,
      repository: %{local_path: path},
      agent_runs: [%{fencing_token: 1, agent_name: "retained", herdr_pane: "w1:p1"}],
      worktree_allocation: %{path: path}
    }

    assert {:error, :continuation_pane_failed} =
             PtcManager.Dispatch.HerdrAdapter.resume_review_job(job)

    assert File.exists?(marker), "Herdr rejected the continuation split before it could be used"
  end
end
