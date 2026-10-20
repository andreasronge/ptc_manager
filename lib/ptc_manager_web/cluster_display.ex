defmodule PtcManagerWeb.ClusterDisplay do
  @moduledoc "Words and links for cluster state shown on several pages."

  alias PtcManager.Cluster

  @doc "Why a claim was refused, naming each member that refused it."
  def claim_refusal(reason, checks) do
    refusals =
      checks
      |> Enum.reject(&(&1["result"] == "clear"))
      |> Enum.map_join("; ", fn check ->
        "#{check["machine_id"]} #{check_words(check["result"])}"
      end)

    case {reason, refusals} do
      {:claim_refused, ""} -> "Another member refused the claim."
      {:claim_refused, refusals} -> "Not enabled here: #{refusals}."
      {:claim_in_progress, _} -> "A claim for this repository is already in progress here."
      {:already_enabled, _} -> "The repository is already enabled here."
      {:claim_intent_expired, _} -> "The members took too long to answer; try again."
      {other, ""} -> "The claim did not complete: #{inspect(other)}."
      {other, refusals} -> "The claim did not complete (#{inspect(other)}): #{refusals}."
    end
  end

  def check_words("claimed"), do: "claims it"
  def check_words("pending"), do: "is claiming it right now"
  def check_words("unreachable"), do: "could not be reached"
  def check_words("incompatible"), do: "runs another protocol version"
  def check_words("revision_mismatch"), do: "has another member map"
  def check_words("not_member"), do: "does not count this machine as a member"
  def check_words(other), do: to_string(other)

  def health_class("healthy"), do: "bg-teal-400"
  def health_class("incompatible"), do: "bg-amber-400"
  def health_class("refused"), do: "bg-rose-400"
  def health_class("unreachable"), do: "bg-rose-400"
  def health_class(_unknown), do: "bg-slate-500"

  @doc """
  Where the machine switcher sends a page on another member. Record ids are
  local to each machine, so only a repository page (by owner and name) and
  list pages keep their target; every other record page lands on the target's
  Cluster page.
  """
  def switch_url(member_id, current_path, repository \\ nil) do
    path =
      cond do
        repository ->
          "/repositories/#{repository.github_owner}/#{repository.github_name}"

        current_path in [
          "/",
          "/board",
          "/operations",
          "/automations",
          "/configuration",
          "/cluster",
          "/deployments",
          "/updates"
        ] or
            String.starts_with?(current_path, "/operations/") ->
          current_path

        true ->
          "/cluster"
      end

    Cluster.console_url(member_id, path)
  end
end
