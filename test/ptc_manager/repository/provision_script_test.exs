defmodule PtcManager.Repository.ProvisionScriptTest do
  use ExUnit.Case, async: true

  @moduletag :nightly
  @script Path.expand("../../../deploy/ptc-manager-provision-repository", __DIR__)

  # The script runs as the deployment user and reaches /srv only through sudo,
  # so a sudo stub that maps /srv into a temporary root lets it run unchanged.
  setup do
    root =
      Path.join(System.tmp_dir!(), "ptc-provision-#{System.unique_integer([:positive])}")

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(root, "srv/ptc_runner/.git"))
    File.mkdir_p!(Path.join(root, "units"))
    on_exit(fn -> File.rm_rf!(root) end)

    stub!(bin, "sudo", """
    while :; do
      case "$1" in
        -n|-H) shift ;;
        -u) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    count=$#
    for arg do
      case "$arg" in
        /srv*) arg="$FAKE_ROOT$arg" ;;
      esac
      set -- "$@" "$arg"
    done
    shift "$count"
    echo "$*" >>"$FAKE_ROOT/sudo.log"
    exec "$@"
    """)

    stub!(bin, "flock", "exit 0")
    stub!(bin, "systemctl", "exit 0")
    stub!(bin, "chown", "exit 0")
    stub!(bin, "sqlite3", "cat \"$FAKE_ROOT/configured\"")

    stub!(bin, "install", """
    directory=false
    while [ $# -gt 0 ]; do
      case "$1" in
        -d) directory=true; shift ;;
        -o|-g|-m) shift 2 ;;
        *) break ;;
      esac
    done
    if $directory; then mkdir -p "$@"; else cp "$1" "$2"; fi
    """)

    # Only a repository the worker's credentials can read clones.
    stub!(bin, "git", """
    [ "$1" = clone ] || exit 2
    case "$3" in
      */private-fails) echo "fatal: could not read Username" >&2; exit 128 ;;
    esac
    mkdir -p "$4/.git"
    """)

    stub!(bin, "dropin-check", "exit 0")
    File.write!(Path.join(root, "db"), "")
    File.write!(Path.join(root, "query.sql"), "select 1;")

    env = [
      {"PATH", "#{bin}:#{System.get_env("PATH")}"},
      {"FAKE_ROOT", root},
      {"PTC_PROVISION_DATABASE_PATH", Path.join(root, "db")},
      {"PTC_PROVISION_UNIT_ROOT", Path.join(root, "units")},
      {"PTC_PROVISION_REPOSITORIES_QUERY", Path.join(root, "query.sql")},
      {"PTC_PROVISION_DROPIN_CHECK", Path.join(bin, "dropin-check")},
      {"PTC_PROVISION_LOCK", Path.join(root, "lock")}
    ]

    {:ok, root: root, env: env}
  end

  test "clones under /srv/<owner> as the worker and keeps going past a failed clone",
       %{root: root, env: env} do
    File.write!(Path.join(root, "configured"), """
    andreasronge|ptc_runner|/srv/ptc_runner
    tyraorg|private-fails|/srv/tyraorg/private-fails
    tyraorg|api|/srv/tyraorg/api
    """)

    {output, status} = System.cmd("sh", [@script], env: env, stderr_to_stdout: true)

    assert status == 3
    assert output =~ "could not clone tyraorg/private-fails"
    assert output =~ "checkouts still missing: tyraorg/private-fails"

    assert File.dir?(Path.join(root, "srv/tyraorg/api/.git"))
    refute File.exists?(Path.join(root, "srv/tyraorg/private-fails"))

    log = File.read!(Path.join(root, "sudo.log"))

    assert log =~
             ~r/env GIT_TERMINAL_PROMPT=0 git clone --quiet https:\/\/github.com\/tyraorg\/api /

    # The drop-ins still grant every configured checkout, the failed one too, so
    # a later clone needs no second run of this script before a restart.
    worker =
      File.read!(
        Path.join(root, "units/ptc_manager-herdr.service.d/zz-ptc-manager-repositories.conf")
      )

    assert worker =~ "ReadWritePaths=-/srv/ptc_runner\n"
    assert worker =~ "ReadWritePaths=-/srv/tyraorg/api\n"
    assert worker =~ "ReadWritePaths=-/srv/tyraorg/private-fails\n"
  end

  test "a clone whose permissions cannot be set counts as failed and is removed",
       %{root: root, env: env} do
    File.write!(Path.join(root, "configured"), "tyraorg|api|/srv/tyraorg/api\n")
    # Only the recursive permission change on the checkout fails.
    stub!(Path.join(root, "bin"), "chmod", ~s|[ "$1" = -R ] && exit 1; exec /bin/chmod "$@"|)

    assert {output, 3} = System.cmd("sh", [@script], env: env, stderr_to_stdout: true)
    assert output =~ "could not clone tyraorg/api"
    refute File.exists?(Path.join(root, "srv/tyraorg/api"))
  end

  test "succeeds when every checkout exists or clones", %{root: root, env: env} do
    File.write!(Path.join(root, "configured"), """
    andreasronge|ptc_runner|/srv/ptc_runner
    tyraorg|api|/srv/tyraorg/api
    """)

    assert {output, 0} = System.cmd("sh", [@script], env: env, stderr_to_stdout: true)
    assert output =~ "Repository access prepared."
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end
end
