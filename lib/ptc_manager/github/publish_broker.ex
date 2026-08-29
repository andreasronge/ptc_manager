defmodule PtcManager.GitHub.PublishBroker do
  @moduledoc "Credential-bearing boundary for one job-derived branch push and draft PR."

  @callback publish(struct()) ::
              {:ok, %{pr_number: pos_integer(), pr_url: String.t(), head_sha: String.t()}}
              | {:retry, term()}
              | {:blocked, term()}

  @callback status(struct()) ::
              {:ok,
               %{
                 state: String.t(),
                 pr_url: String.t(),
                 head_sha: String.t(),
                 base_ref: String.t(),
                 base_repository: String.t()
               }}
              | {:retry, term()}
              | {:blocked, term()}
end
