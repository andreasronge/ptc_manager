defmodule Mix.Tasks.Ptc.Cluster do
  use Mix.Task

  @shortdoc "Checks that every cluster member answers and agrees on membership"

  @moduledoc """
  Signs a status request to every member of the cluster and prints what each
  one reports.

      mix ptc.cluster check
      mix ptc.cluster check --as herdr-build-01

  It reads `PTC_CLUSTER_MEMBERS` and `PTC_CLUSTER_SECRET` from the environment,
  so it runs on any member or on a maintainer machine that has the member map
  and the secret. Requests are signed as `--as`, else `PTC_MACHINE_ID`, else the
  first member. For each member it prints the membership revision, protocol
  version, deployed SHA, clock skew, and any signature or transport failure,
  and it exits non-zero when any member fails to answer or disagrees.
  """

  alias PtcManager.Cluster
  alias PtcManager.Cluster.Peer

  @impl Mix.Task
  def run(["check" | args]) do
    {opts, _rest} = OptionParser.parse!(args, strict: [as: :string])
    Mix.Task.run("app.config")
    Enum.each([:crypto, :ssl, :inets, :jason], &Application.ensure_all_started/1)

    members = Cluster.members()
    if members == %{}, do: Mix.raise("PTC_CLUSTER_MEMBERS is not set")
    unless is_binary(Cluster.secret()), do: Mix.raise("PTC_CLUSTER_SECRET is not set")

    caller =
      opts[:as] ||
        (System.get_env("PTC_MACHINE_ID") not in [nil, ""] && System.get_env("PTC_MACHINE_ID")) ||
        members |> Map.keys() |> Enum.sort() |> hd()

    expected = Cluster.membership_revision()
    Mix.shell().info("Membership revision here: #{expected}")
    Mix.shell().info("Signing as: #{caller}\n")

    results =
      for {id, _url} <- Enum.sort(members) do
        result = Peer.fetch_status(id, as: caller)
        Mix.shell().info(line(id, result, expected))
        result
      end

    if Enum.all?(results, &agrees?(&1, expected)) do
      Mix.shell().info("\nEvery member answered and agrees.")
    else
      Mix.raise("At least one member did not answer or disagrees")
    end
  end

  def run(_args), do: Mix.raise("Usage: mix ptc.cluster check [--as MACHINE_ID]")

  @doc false
  def line(id, {:ok, status}, expected) do
    revision =
      if status["membership_revision"] == expected,
        do: "same membership",
        else: "OTHER membership #{status["membership_revision"]}"

    protocol =
      if status["protocol_version"] == Cluster.protocol_version(),
        do: "protocol #{status["protocol_version"]}",
        else: "OTHER protocol #{inspect(status["protocol_version"])}"

    "#{id}: ok · #{revision} · #{protocol} · sha #{String.slice(status["deployed_sha"] || "unknown", 0, 12)} · clock skew #{status["_clock_skew_s"]}s"
  end

  def line(id, {:error, :not_a_member}, _expected),
    do: "#{id}: REFUSED · the signing machine is not in its member map"

  def line(id, {:error, {:bad_response_signature, reason}}, _expected),
    do: "#{id}: SIGNATURE FAILURE · #{inspect(reason)}"

  def line(id, {:error, reason}, _expected), do: "#{id}: FAILED · #{inspect(reason)}"

  @doc false
  def agrees?({:ok, status}, expected),
    do:
      status["membership_revision"] == expected and
        status["protocol_version"] == Cluster.protocol_version()

  def agrees?(_result, _expected), do: false
end
