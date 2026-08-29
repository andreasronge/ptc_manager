defmodule PtcManager.Repository.ResultProbe do
  @moduledoc "Verifies the committed result of a fenced implementation branch."

  alias PtcManager.Operations.{Job, Repository}

  @callback verify(Repository.t(), Job.t()) ::
              {:ok,
               %{
                 base_sha: String.t(),
                 head_sha: String.t(),
                 diff_digest: String.t(),
                 commit_count: pos_integer()
               }}
              | {:error, term()}
end
