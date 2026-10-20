defmodule PtcManager.Cluster do
  @moduledoc """
  Membership of a cluster of PtcManager instances, one per machine.

  `PTC_CLUSTER_MEMBERS` maps every member's machine id to its base URL (this
  machine included) and `PTC_CLUSTER_SECRET` signs every peer request and
  response; both are identical on every member. Members never share a
  database, never use Distributed Erlang, and never send each other commands:
  the only protocol is signed, read-only `GET`s of each other's status
  (`PtcManager.Cluster.Peer`). Without `PTC_CLUSTER_MEMBERS` none of this runs
  and the console behaves as a single machine.

  The membership revision is the SHA-256 of the canonical member map, so two
  members agree on membership exactly when their revisions match.
  """

  alias PtcManager.Machine

  @protocol_version 1
  @min_secret_bytes 32

  def protocol_version, do: @protocol_version

  @doc "Whether this console is a cluster member."
  def enabled?, do: Machine.clustered?()

  @doc "machine id => base URL for every member, this machine included."
  def members, do: Application.get_env(:ptc_manager, :cluster_members) || %{}

  @doc "Every other member, sorted by id."
  def peers, do: members() |> Map.delete(Machine.id()) |> Enum.sort()

  def member?(id), do: Map.has_key?(members(), id)

  def base_url(id \\ Machine.id()), do: Map.get(members(), id)

  def secret, do: Application.get_env(:ptc_manager, :cluster_secret)

  @doc "SHA-256 of the canonical member map, lowercase hex."
  def membership_revision(members \\ members()) do
    canonical =
      members |> Enum.sort() |> Enum.map(fn {id, url} -> [id, url] end) |> Jason.encode!()

    :crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower)
  end

  @doc """
  Validates the cluster configuration at boot and raises when it is unusable:
  an invalid map, a short secret, this machine missing from the map, or a base
  URL that is not a Tailscale HTTPS name or address. Plain loopback HTTP is
  accepted only with the test-only flag outside production.
  """
  def validate! do
    if enabled?() do
      members = members()

      unless is_binary(secret()) and byte_size(secret()) >= @min_secret_bytes,
        do:
          raise(ArgumentError, "PTC_CLUSTER_SECRET must hold at least #{@min_secret_bytes} bytes")

      unless Application.get_env(:ptc_manager, :machine_id_configured, false),
        do: raise(ArgumentError, "PTC_MACHINE_ID is required when PTC_CLUSTER_MEMBERS is set")

      unless member?(Machine.id()),
        do:
          raise(
            ArgumentError,
            "this machine (#{Machine.id()}) is not in PTC_CLUSTER_MEMBERS, so it cannot join the cluster"
          )

      Enum.each(members, fn {id, url} ->
        unless Machine.valid_id?(id),
          do: raise(ArgumentError, "PTC_CLUSTER_MEMBERS has an invalid machine id #{inspect(id)}")

        unless valid_base_url?(url),
          do:
            raise(
              ArgumentError,
              "PTC_CLUSTER_MEMBERS: #{id} must use an https://*.ts.net name or a Tailscale address"
            )
      end)
    end

    :ok
  end

  @doc "Whether a base URL is a Tailscale HTTPS origin (or test loopback when allowed)."
  def valid_base_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and path in [nil, "", "/"] ->
        String.ends_with?(host, ".ts.net") or tailscale_address?(host)

      %URI{scheme: "http", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when host in ["127.0.0.1", "localhost"] and path in [nil, "", "/"] ->
        insecure_loopback?()

      _invalid ->
        false
    end
  end

  def valid_base_url?(_url), do: false

  def insecure_loopback?,
    do: Application.get_env(:ptc_manager, :cluster_allow_insecure_loopback, false)

  # 100.64.0.0/10 and fd7a:115c:a1e0::/48 are Tailscale's address ranges.
  defp tailscale_address?(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[]"))) do
      {:ok, {100, second, _, _}} -> second in 64..127
      {:ok, {0xFD7A, 0x115C, 0xA1E0, _, _, _, _, _}} -> true
      _other -> false
    end
  end

  @doc "A URL on a member's console, for deep links to records it owns."
  def console_url(member_id, path) do
    case base_url(member_id) do
      nil -> nil
      base -> String.trim_trailing(base, "/") <> path
    end
  end

  @doc "The base URL of this console, for links in the status document."
  def self_url(path), do: console_url(Machine.id(), path)

  @doc """
  Records a changed membership revision as `cluster.membership_changed`, once
  per change, at boot.
  """
  def record_membership do
    if enabled?() do
      import Ecto.Query
      revision = membership_revision()

      previous =
        PtcManager.Repo.one(
          from event in PtcManager.Operations.AuditEvent,
            where: event.action == "cluster.membership_changed",
            order_by: [desc: event.id],
            limit: 1,
            select: event.details
        )

      unless match?(%{"revision" => ^revision}, previous) do
        %PtcManager.Operations.AuditEvent{}
        |> PtcManager.Operations.AuditEvent.changeset(%{
          actor: "system",
          action: "cluster.membership_changed",
          target_type: "machine",
          target_id: 0,
          details: %{
            "machine_id" => Machine.id(),
            "revision" => revision,
            "previous_revision" => previous && previous["revision"],
            "members" => members()
          }
        })
        |> PtcManager.Repo.insert!()
      end
    end

    :ok
  end
end
