defmodule PtcManager.ReviewResumeCliTest do
  use ExUnit.Case, async: false

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
      agent_runs: [%{fencing_token: 1, agent_name: "retained", herdr_pane: "w1:p1"}],
      worktree_allocation: %{path: path}
    }

    assert {:error, :retained_workspace_not_ready} =
             PtcManager.Dispatch.HerdrAdapter.resume_review_job(job)

    assert File.exists?(marker), "Herdr rejected the continuation split before it could be used"
  end
end
