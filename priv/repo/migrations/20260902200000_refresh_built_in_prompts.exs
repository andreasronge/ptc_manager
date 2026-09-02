defmodule PtcManager.Repo.Migrations.RefreshBuiltInPrompts do
  use Ecto.Migration

  @moduledoc """
  Rewrites two phrases inside the `system:built-in` prompt versions so existing
  repositories receive the same suggestion as new ones. Maintainer-authored
  versions are left untouched.
  """

  @implement_old "publish a pull request that closes the issue and includes a short retrospective. Do not merge it."
  @implement_new "publish a pull request that closes the issue. Its description needs a summary, what you verified beyond the repository hooks, and a `## Retrospective` section with two items that may each be `none`: untracked follow-up work with a reproduction, and one repository instruction that was missing, wrong, or that you had to guess at. Do not merge it."
  @nightly_old "supplied stable occurrence marker"
  @nightly_new "supplied invocation marker"

  def up do
    replace_built_in("implement_issue", @implement_old, @implement_new)
    replace_built_in("nightly_ci_investigation", @nightly_old, @nightly_new)
  end

  def down do
    replace_built_in("implement_issue", @implement_new, @implement_old)
    replace_built_in("nightly_ci_investigation", @nightly_new, @nightly_old)
  end

  defp replace_built_in(key, old, new) do
    for text <- [key, old, new], String.contains?(text, "'") do
      raise ArgumentError, "prompt phrases must not contain single quotes"
    end

    execute("""
    UPDATE automation_definition_versions
    SET prompt = replace(prompt, '#{old}', '#{new}')
    WHERE created_by = 'system:built-in'
      AND automation_definition_id IN (
        SELECT id FROM automation_definitions WHERE key = '#{key}'
      )
    """)
  end
end
