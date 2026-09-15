defmodule PtcManager.Automations.PromptRewrite do
  @moduledoc """
  Rewrites the built-in prompt versions already in use when a default in
  `PtcManager.Automations.Defaults` changes.

  A changed default reaches only new repositories, so a migration calls this
  for each built-in key. Only versions PtcManager wrote (`system:built-in`)
  that still contain the old sentence are touched; an edited prompt is the
  maintainer's and is left exactly as it is. The stored prompt carries a
  per-repository prefix, so the sentence is replaced inside it.

  Parameters are numbered positionally (`?1`, `?2`, `?3`): SQLite numbers a
  `$name` placeholder by its first appearance in the statement, which once
  bound `from` and `to` the wrong way round and rewrote nothing.
  """

  @doc "Replaces `from` with `to` in every built-in version of the automation `key`; returns the rows changed."
  def rewrite_built_in(repo, key, from, to)
      when is_binary(key) and is_binary(from) and is_binary(to) do
    %{num_rows: rows} =
      repo.query!(
        """
        UPDATE automation_definition_versions
        SET prompt = replace(prompt, ?1, ?2)
        WHERE created_by = 'system:built-in'
          AND instr(prompt, ?1) > 0
          AND automation_definition_id IN (
            SELECT id FROM automation_definitions WHERE key = ?3
          )
        """,
        [from, to, key]
      )

    rows
  end
end
