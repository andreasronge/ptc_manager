defmodule PtcManager.TestSuiteScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/ci/test-suite", __DIR__)

  test "partitions receive separate disposable temp directories" do
    root =
      Path.join(
        System.tmp_dir!(),
        "suite-isolation-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)
    mix = Path.join(bin, "mix")

    File.write!(
      mix,
      "#!/bin/sh\nset -eu\ncase \"$TMPDIR\" in *//*) exit 2;; esac\nmkdir \"$TMPDIR/shared-fixture\"\necho fixture-created\n"
    )

    File.chmod!(mix, 0o755)

    {output, status} =
      System.cmd("sh", [@script],
        env: [
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"TMPDIR", root <> "/"},
          {"PTC_TEST_PARTITIONS", "3"},
          {"PTC_TEST_PARTITION_ONLY", nil},
          {"PTC_TEST_BUDGET_SECONDS", "10"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert length(Regex.scan(~r/fixture-created/, output)) == 3
    assert File.ls!(root) == ["bin"]
  end
end
