defmodule PtcManager.BootstrapCacheTest do
  use ExUnit.Case, async: true

  @project_root Path.expand("../..", __DIR__)
  @cache_script Path.join(@project_root, "scripts/ptc/bootstrap-cache")
  @bootstrap_script Path.join(@project_root, "scripts/ptc/bootstrap")

  test "the repository bootstrap reports a cold run and then consumes its warm cache" do
    fixture = cache_fixture(bootstrap: true)
    on_exit(fn -> File.rm_rf!(fixture.root) end)

    cold = run_bootstrap(fixture)
    assert cold =~ "cache_state=miss"
    assert cold =~ "dependencies_ms="
    assert cold =~ "asset_tools_ms="
    assert cold =~ "cache_publish_ms="

    File.rm_rf!(Path.join(fixture.repository, "deps"))
    File.rm_rf!(Path.join(fixture.repository, "_build"))
    File.write!(fixture.log, "")

    warm = run_bootstrap(fixture)
    assert warm =~ "cache_state=hit"
    assert File.read!(fixture.log) =~ "deps-warm"
    assert File.read!(fixture.log) =~ "assets-warm"
  end

  test "restores isolated dependency and tool copies after a cold publish" do
    fixture = cache_fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)

    assert run_cache(fixture, "restore") =~ "cache_state=miss"

    seed_build(fixture.repository, "first")
    assert run_cache(fixture, "publish") =~ "cache_publish_ms="

    File.rm_rf!(Path.join(fixture.repository, "deps"))
    File.rm_rf!(Path.join(fixture.repository, "_build"))

    assert run_cache(fixture, "restore") =~ "cache_state=hit"
    assert File.read!(Path.join(fixture.repository, "deps/example/source.txt")) == "first"

    assert File.read!(Path.join(fixture.repository, "_build/test/lib/example/compiled.txt")) ==
             "first"

    assert File.exists?(Path.join(fixture.repository, "_build/esbuild-test"))

    refute File.exists?(Path.join(fixture.repository, "_build/test/lib/ptc_manager/compiled.txt"))

    File.write!(Path.join(fixture.repository, "deps/example/source.txt"), "worktree change")

    second = cache_fixture(cache_root: fixture.cache_root)
    on_exit(fn -> File.rm_rf!(second.root) end)
    assert run_cache(second, "restore") =~ "cache_state=hit"
    assert File.read!(Path.join(second.repository, "deps/example/source.txt")) == "first"
  end

  test "invalidates the cache when mix.lock changes" do
    fixture = cache_fixture()
    on_exit(fn -> File.rm_rf!(fixture.root) end)

    seed_build(fixture.repository, "cached")
    run_cache(fixture, "publish")
    File.rm_rf!(Path.join(fixture.repository, "deps"))
    File.rm_rf!(Path.join(fixture.repository, "_build"))
    File.write!(Path.join(fixture.repository, "mix.lock"), "%{changed: true}\n")

    assert run_cache(fixture, "restore") =~ "cache_state=miss"
    refute File.exists?(Path.join(fixture.repository, "deps/example/source.txt"))
  end

  test "concurrent cold publishers leave one complete reusable cache" do
    first = cache_fixture()
    second = cache_fixture(cache_root: first.cache_root)
    verifier = cache_fixture(cache_root: first.cache_root)
    on_exit(fn -> Enum.each([first, second, verifier], &File.rm_rf!(&1.root)) end)

    seed_build(first.repository, "first")
    seed_build(second.repository, "second")

    results =
      [first, second]
      |> Task.async_stream(&run_cache(&1, "publish"), ordered: false, timeout: 15_000)
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, output} when is_binary(output), &1))
    assert run_cache(verifier, "restore") =~ "cache_state=hit"

    assert File.read!(Path.join(verifier.repository, "deps/example/source.txt")) in [
             "first",
             "second"
           ]
  end

  defp cache_fixture(options \\ []) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "ptc-bootstrap-cache-#{unique}")
    repository = Path.join(root, "repository")
    cache_root = Keyword.get(options, :cache_root, Path.join(root, "cache"))

    File.mkdir_p!(Path.join(repository, "scripts/ptc"))
    File.mkdir_p!(Path.join(repository, "config"))
    File.cp!(@cache_script, Path.join(repository, "scripts/ptc/bootstrap-cache"))

    if Keyword.get(options, :bootstrap, false) do
      File.cp!(@bootstrap_script, Path.join(repository, "scripts/ptc/bootstrap"))
    else
      File.write!(Path.join(repository, "scripts/ptc/bootstrap"), "#!/bin/sh\n")
    end

    File.write!(Path.join(repository, "mix.lock"), "%{}\n")
    File.write!(Path.join(repository, "mix.exs"), "defmodule CacheFixture do\nend\n")
    File.write!(Path.join(repository, "config/config.exs"), "import Config\n")

    fixture = %{root: root, repository: repository, cache_root: cache_root}

    if Keyword.get(options, :bootstrap, false),
      do: install_fake_mix(fixture),
      else: fixture
  end

  defp seed_build(repository, marker) do
    File.mkdir_p!(Path.join(repository, "deps/example"))
    File.write!(Path.join(repository, "deps/example/source.txt"), marker)
    File.mkdir_p!(Path.join(repository, "_build/test/lib/example"))
    File.write!(Path.join(repository, "_build/test/lib/example/compiled.txt"), marker)
    File.mkdir_p!(Path.join(repository, "_build/test/lib/ptc_manager"))
    File.write!(Path.join(repository, "_build/test/lib/ptc_manager/compiled.txt"), marker)
    File.mkdir_p!(Path.join(repository, "_build"))
    File.write!(Path.join(repository, "_build/esbuild-test"), "binary")
  end

  defp run_cache(fixture, command) do
    {output, 0} =
      System.cmd("/bin/sh", ["scripts/ptc/bootstrap-cache", command],
        cd: fixture.repository,
        env: [
          {"HOME", fixture.root},
          {"PTC_WORKSPACE_CACHE_ROOT", fixture.cache_root},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    output
  end

  defp run_bootstrap(fixture) do
    {output, 0} =
      System.cmd("/bin/sh", ["scripts/ptc/bootstrap"],
        cd: fixture.repository,
        env: [
          {"HOME", fixture.root},
          {"PATH", fixture.bin <> ":" <> System.fetch_env!("PATH")},
          {"PTC_WORKSPACE_CACHE_ROOT", fixture.cache_root},
          {"BOOTSTRAP_TEST_LOG", fixture.log},
          {"MIX_ENV", "test"}
        ],
        stderr_to_stdout: true
      )

    output
  end

  defp install_fake_mix(fixture) do
    bin = Path.join(fixture.root, "bin")
    log = Path.join(fixture.root, "mix.log")
    File.mkdir_p!(bin)
    File.write!(log, "")

    mix = Path.join(bin, "mix")

    File.write!(
      mix,
      """
      #!/bin/sh
      set -eu
      case "$*" in
        "deps.get")
          [ ! -f deps/example/source.txt ] || printf 'deps-warm\\n' >> "$BOOTSTRAP_TEST_LOG"
          mkdir -p deps/example _build/test/lib/example
          printf 'dependency' > deps/example/source.txt
          printf 'compiled' > _build/test/lib/example/compiled.txt
          ;;
        "assets.setup")
          [ ! -f _build/esbuild-test ] || printf 'assets-warm\\n' >> "$BOOTSTRAP_TEST_LOG"
          mkdir -p _build
          printf 'binary' > _build/esbuild-test
          ;;
        *) exit 2 ;;
      esac
      """
    )

    File.chmod!(mix, 0o755)
    Map.merge(fixture, %{bin: bin, log: log})
  end
end
