defmodule PtcManager.Machine.HelperManifest do
  @moduledoc """
  SHA-256 digests of the host helpers a profile runs from its service root,
  taken from `deploy/` when this release is compiled. Readiness compares the
  installed copies against them, so an outdated helper is visible before it
  runs a job.
  """

  @deploy Path.expand("../../../deploy", __DIR__)
  @helpers ~w(ptc-operation ptc-manager-worker-review ptc-manager-worker-agent-login macos-deploy-host)

  for helper <- @helpers, do: @external_resource(Path.join(@deploy, helper))

  @digests Map.new(@helpers, fn helper ->
             content = File.read!(Path.join(@deploy, helper))
             {helper, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)}
           end)

  @doc "The packaged digest of one helper."
  def digest(helper) when is_map_key(@digests, helper), do: Map.fetch!(@digests, helper)

  def digests, do: @digests

  def sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
