defmodule PtcManager.Repository.Provisioning do
  @moduledoc """
  Asks the host to prepare every configured repository's checkout.

  Onboarding derives a checkout path but cannot create it: `/srv` is read-only
  inside the coordinator's mount namespace even for root. A separate oneshot
  unit clones what is missing and grants every configured checkout to both
  services, so adding a repository no longer needs a release build.

  It restarts nothing. A grant only enters a namespace when the service starts,
  and restarting the worker ends every retained agent session, so the restart
  stays a maintainer's decision. `PtcManager.Repository.ServiceAccess` reports
  what is still outstanding.
  """

  alias PtcManager.SystemdUnit

  @unit "ptc-manager-provision-repository.service"

  @doc "Starts the host provisioning unit; the result appears in repository health."
  def start do
    command = Application.get_env(:ptc_manager, :provision_systemctl_command)

    args =
      Application.get_env(
        :ptc_manager,
        :provision_systemctl_args,
        ["-n", "/bin/systemctl", "start", "--no-block", @unit]
      )

    case SystemdUnit.start(command, args, :repository_provisioning_failed) do
      :not_configured -> {:error, :repository_provisioning_not_configured}
      result -> result
    end
  end
end
