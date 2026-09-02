defmodule PtcManager.CodexTrustTest do
  use ExUnit.Case, async: true

  alias PtcManager.CodexTrust

  test "trusts each distinct expanded path in one Codex configuration override" do
    assert ["-c", override] =
             CodexTrust.override_args([
               "/srv/ptc_manager",
               "/srv/ptc_manager-worktrees/../ptc_manager-worktrees/job-28",
               "/srv/ptc_manager"
             ])

    assert override ==
             ~s(projects={"/srv/ptc_manager"={trust_level="trusted"},) <>
               ~s("/srv/ptc_manager-worktrees/job-28"={trust_level="trusted"}})
  end

  test "escapes quotes and backslashes as a TOML basic string" do
    assert CodexTrust.toml_basic_string(~s(/tmp/odd "name"\\dir)) ==
             ~s("/tmp/odd \\"name\\"\\\\dir")
  end
end
