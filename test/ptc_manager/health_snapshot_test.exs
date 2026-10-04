defmodule PtcManager.HealthSnapshotTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../deploy/ptc-manager-health-snapshot", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "ptc-health-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    db = Path.join(root, "db")
    File.write!(db, "fixture")
    executable(root, "sqlite3", "echo '[]'")
    executable(root, "chgrp", "exit 0")
    %{root: root, db: db, out: Path.join(root, "snapshot.json")}
  end

  test "a journal failure after preflight preserves the previous snapshot", ctx do
    executable(ctx.root, "journalctl", "case \"$*\" in *'-n 1 '*) exit 0;; *) exit 1;; esac")
    File.write!(ctx.out, "previous")
    assert {_output, status} = run(ctx)
    assert status != 0
    assert File.read!(ctx.out) == "previous"
  end

  test "private and agent-controlled strings are not exported", ctx do
    executable(
      ctx.root,
      "journalctl",
      "echo '{\"MESSAGE\":\"[error] private-secret from an agent-controlled exception\"}'"
    )

    executable(
      ctx.root,
      "sqlite3",
      "case \"$*\" in *status_text*|*target_label*|*'state, label'*) echo '[{\"text\":\"private-secret\"}]';; *) echo '[]';; esac"
    )

    assert {_output, 0} = run(ctx)
    snapshot = File.read!(ctx.out)
    assert is_map(Jason.decode!(snapshot))
    refute snapshot =~ "private-secret"
    assert Jason.decode!(snapshot)["freshness_budget_seconds"] == 3600
  end

  test "counts database failures beyond a journal tail full of session noise", ctx do
    executable(
      ctx.root,
      "journalctl",
      "case \"$*\" in *'-g '*) echo '{\"MESSAGE\":\"SQLite transaction was slow: database is locked\"}';; *'-n 1 '*) exit 0;; *) i=0; while [ \"$i\" -lt 10000 ]; do echo '{\"MESSAGE\":\"sudo[123]: pam_unix session\"}'; i=$((i + 1)); done;; esac"
    )

    assert {_output, 0} = run(ctx)
    volume = Jason.decode!(File.read!(ctx.out))["service_log_volume"]
    assert volume["at_limit"]
    refute volume["diagnostic_at_limit"]
    assert volume["session_noise_lines"] == 10_000
    assert volume["error_lines"] == 1
  end

  test "a quiet journal window produces a fresh snapshot with zero diagnostics", ctx do
    executable(
      ctx.root,
      "journalctl",
      "case \"$*\" in *'-g '*) exit 1;; *) echo '{\"MESSAGE\":\"ordinary activity\"}';; esac"
    )

    assert {_output, 0} = run(ctx)
    volume = Jason.decode!(File.read!(ctx.out))["service_log_volume"]
    assert volume["error_lines"] == 0
    refute volume["diagnostic_at_limit"]
  end

  test "counts multiline exceptions by journal entry and retains BEAM headers", ctx do
    executable(
      ctx.root,
      "journalctl",
      "case \"$*\" in *'-g '*) printf '%s\\n' '{\"MESSAGE\":\"** (RuntimeError) failure\\nsecond line\"}' '{\"MESSAGE\":\"[warning] multiline\\nsecond line\"}';; *) printf '%s\\n' '{\"MESSAGE\":\"ordinary activity\\nsecond line\"}';; esac"
    )

    assert {_output, 0} = run(ctx)
    volume = Jason.decode!(File.read!(ctx.out))["service_log_volume"]
    assert volume["error_lines"] == 2
    assert volume["total_lines"] == 1
    refute volume["at_limit"]
  end

  test "an agent-created output symlink is replaced rather than followed", ctx do
    executable(
      ctx.root,
      "journalctl",
      "echo '{\"MESSAGE\":\"[warning] fixture\"}'"
    )

    outside = Path.join(ctx.root, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, ctx.out)
    assert {_output, 0} = run(ctx)
    assert {:ok, %{type: :regular}} = File.lstat(ctx.out)
    assert File.ls!(outside) == []
  end

  defp executable(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp run(ctx) do
    System.cmd("sh", [@script],
      env: [
        {"PATH", ctx.root <> ":" <> System.get_env("PATH")},
        {"PTC_HEALTH_DB", ctx.db},
        {"PTC_HEALTH_OUT", ctx.out}
      ],
      stderr_to_stdout: true
    )
  end
end
