defmodule PtcManager.Machine.ToolInventoryTest do
  use ExUnit.Case, async: true

  alias PtcManager.Machine.{ToolInventory, ToolProbes}

  # Captured from the Ubuntu 24.04 worker, where the job user is not in the
  # docker group, and from a macOS maintainer machine.
  @linux_probes [
    {"docker", 0, "Docker version 27.5.1, build 9f9e405\n", ""},
    {"docker-daemon", 1, "\n",
     "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.47/version\": dial unix /var/run/docker.sock: connect: permission denied\n"},
    {"docker-compose", 0, "2.33.1\n", ""},
    {"deno", 0,
     "deno 2.5.6 (stable, release, x86_64-unknown-linux-gnu)\nv8 14.0.365.4-rusty\ntypescript 5.9.2\n",
     ""},
    {"elixir", 0,
     "Erlang/OTP 27 [erts-15.2.7] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [jit:ns]\n\nElixir 1.18.4 (compiled with Erlang/OTP 27)\n",
     ""},
    {"node", 0, "v22.23.2\n", ""},
    {"git", 0, "git version 2.43.0\n", ""},
    {"gh", 0,
     "gh version 2.45.0 (2024-03-04 Ubuntu 2.45.0-1ubuntu0.3)\nhttps://github.com/cli/cli/releases/tag/v2.45.0\n",
     ""},
    {"psql", 0, "psql (PostgreSQL) 16.10 (Ubuntu 16.10-0ubuntu0.24.04.1)\n", ""},
    {"redis-server", 0,
     "Redis server v=7.0.15 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=62c7a5d52c72f4cd\n",
     ""}
  ]

  @macos_probes [
    {"docker", 0, "Docker version 27.4.0, build bde2b89\n", ""},
    {"docker-daemon", 0, "27.4.0\n", ""},
    {"docker-compose", 0, "2.31.0-desktop.2\n", ""},
    {"deno", 0,
     "deno 2.9.7 (stable, release, aarch64-apple-darwin)\nv8 15.0.245.2-rusty\ntypescript 6.0.3\n",
     ""},
    {"elixir", 0,
     "Erlang/OTP 29 [erts-17.0.3] [source] [64-bit] [smp:10:10] [ds:10:10:10] [async-threads:1] [jit] [dtrace]\n\nElixir 1.20.2 (compiled with Erlang/OTP 29)\n",
     ""},
    {"node", 0, "v22.23.2\n", ""},
    {"git", 0, "git version 2.50.1 (Apple Git-155)\n", ""},
    {"gh", 0,
     "gh version 2.102.0 (2026-09-30)\nhttps://github.com/cli/cli/releases/tag/v2.102.0\n", ""},
    {"psql", 0, "psql (PostgreSQL) 14.15 (Homebrew)\n", ""}
  ]

  defp document(probes, extra \\ []) do
    %{
      "schema_version" => 1,
      "captured_at" => "2026-10-20T12:00:00Z",
      "os" => "linux",
      "arch" => "x86_64",
      "cpu_count" => 8,
      "memory_bytes" => 16_000_000_000,
      "disk_free_bytes" => 100_000_000_000,
      "probes" =>
        Enum.map(probes, fn {name, status, stdout, stderr} ->
          %{
            "name" => name,
            "exit_status" => status,
            "timed_out" => false,
            "stdout" => stdout,
            "stderr" => stderr,
            "error" => nil
          }
        end) ++ extra
    }
  end

  test "parses captured Linux output, with docker present but its daemon unreachable" do
    missing = %{
      "name" => "cerbos",
      "exit_status" => nil,
      "timed_out" => false,
      "error" => "not_found"
    }

    assert {:ok, parsed} = ToolInventory.parse(document(@linux_probes, [missing]), "pane")

    assert parsed.context == "pane"
    assert parsed.captured_at == ~U[2026-10-20 12:00:00Z]
    assert parsed.cpu_count == 8

    versions = Map.new(parsed.tools, fn {name, tool} -> {name, {tool.status, tool.version}} end)

    assert versions == %{
             "docker" => {"ok", "27.5.1"},
             "docker-daemon" => {"failed", nil},
             "docker-compose" => {"ok", "2.33.1"},
             "deno" => {"ok", "2.5.6"},
             "elixir" => {"ok", "1.18.4"},
             "node" => {"ok", "22.23.2"},
             "git" => {"ok", "2.43.0"},
             "gh" => {"ok", "2.45.0"},
             "psql" => {"ok", "16.10.0"},
             "redis-server" => {"ok", "7.0.15"},
             "cerbos" => {"missing", nil}
           }

    assert parsed.tools["docker-daemon"].detail =~ "exit 1: permission denied"
  end

  test "parses captured macOS output" do
    assert {:ok, parsed} = ToolInventory.parse(document(@macos_probes), "setup")

    assert parsed.tools["docker-compose"].version == "2.31.0"
    assert parsed.tools["elixir"].version == "1.20.2"
    assert parsed.tools["gh"].version == "2.102.0"
    assert parsed.tools["psql"].version == "14.15.0"
    assert parsed.tools["redis-server"].status == "not_probed"
  end

  test "timeouts and spawn failures are their own statuses" do
    probes = [
      %{
        "name" => "docker",
        "exit_status" => -9,
        "timed_out" => true,
        "stdout" => "",
        "stderr" => ""
      },
      %{"name" => "git", "error" => "permission_denied"}
    ]

    assert {:ok, parsed} = ToolInventory.parse(document([], probes), "pane")
    assert parsed.tools["docker"].status == "timed_out"
    assert parsed.tools["git"] == %{status: "error", version: nil, detail: "permission_denied"}
  end

  test "fields of the wrong type are refused or ignored, never raised on" do
    assert {:error, :invalid_captured_at} =
             ToolInventory.parse(%{document([]) | "captured_at" => %{}}, "pane")

    odd = [
      %{"name" => "docker", "exit_status" => 0, "stdout" => %{"a" => 1}, "stderr" => [1]},
      %{"name" => "git", "exit_status" => "0"},
      "not a probe"
    ]

    assert {:ok, parsed} = ToolInventory.parse(document([], odd), "pane")
    assert parsed.tools["docker"] == %{status: "ok", version: nil, detail: nil}
    assert parsed.tools["git"].status == "error"
  end

  test "probes outside the catalog are ignored and invalid documents are refused" do
    unknown = %{"name" => "rm", "exit_status" => 0, "stdout" => "1.0.0"}
    assert {:ok, parsed} = ToolInventory.parse(document([], [unknown]), "pane")
    refute Map.has_key?(parsed.tools, "rm")

    assert {:error, :invalid_snapshot} = ToolInventory.parse(%{"probes" => "x"}, "pane")
    assert {:error, :invalid_snapshot} = ToolInventory.parse(document([]), "elsewhere")

    assert {:error, :invalid_captured_at} =
             ToolInventory.parse(%{document([]) | "captured_at" => "yesterday"}, "pane")
  end

  test "normalizes versions to semver" do
    assert ToolInventory.normalize_version("v1.2") == "1.2.0"
    assert ToolInventory.normalize_version("1.2.3") == "1.2.3"
    assert ToolInventory.normalize_version("v22.23.2") == "22.23.2"
    assert ToolInventory.normalize_version("1.2-beta") == "1.2.0-beta"
    assert ToolInventory.normalize_version("2.31.0-desktop.2") == "2.31.0-desktop.2"
    assert ToolInventory.normalize_version("latest") == nil
    assert Version.match?(ToolInventory.normalize_version("v2.24"), ">= 2.24.0")
  end

  test "a context older than the maximum age is stale" do
    {:ok, parsed} = ToolInventory.parse(document(@linux_probes), "pane")

    refute ToolInventory.stale?(parsed, ~U[2026-10-20 12:29:00Z], 1_800_000)
    assert ToolInventory.stale?(parsed, ~U[2026-10-20 12:31:00Z], 1_800_000)
    assert ToolInventory.stale?(nil, ~U[2026-10-20 12:00:00Z], 1_800_000)
  end

  test "the summary is JSON-shaped for this console and for peers" do
    {:ok, parsed} = ToolInventory.parse(document(@linux_probes), "pane")
    summary = ToolInventory.summary(%{"pane" => parsed}, ~U[2026-10-20 12:01:00Z])

    assert summary["setup"] == nil
    assert summary["pane"]["captured_at"] == "2026-10-20T12:00:00Z"
    assert summary["pane"]["stale"] == false

    assert summary["pane"]["tools"]["docker"] == %{
             "status" => "ok",
             "version" => "27.5.1",
             "detail" => nil
           }

    assert summary |> Jason.encode!() |> Jason.decode!() == summary
  end

  describe "the probe catalog" do
    test "extra probes are validated" do
      assert {:ok, [%{name: "terraform"}]} =
               ToolProbes.validate_extra([
                 %{
                   "name" => "terraform",
                   "argv" => ["terraform", "version"],
                   "version_regex" => "v(\\d+\\.\\d+\\.\\d+)"
                 }
               ])

      assert {:error, _} = ToolProbes.validate_extra(%{"name" => "x"})

      assert {:error, _} =
               ToolProbes.validate_extra([
                 %{"name" => "docker", "argv" => ["docker"], "version_regex" => "(.*)"}
               ])

      assert {:error, _} =
               ToolProbes.validate_extra([
                 %{"name" => "Bad Name", "argv" => ["x"], "version_regex" => "(.*)"}
               ])

      assert {:error, _} =
               ToolProbes.validate_extra([
                 %{"name" => "x", "argv" => [], "version_regex" => "(.*)"}
               ])

      assert {:error, _} =
               ToolProbes.validate_extra([
                 %{"name" => "x", "argv" => ["x"], "version_regex" => "("}
               ])

      too_many =
        for index <- 1..14,
            do: %{"name" => "tool-#{index}", "argv" => ["t"], "version_regex" => "(\\d+)"}

      assert {:error, message} = ToolProbes.validate_extra(too_many)
      assert message =~ "at most 24"
    end

    test "the script reads names and argv only" do
      document = ToolProbes.catalog_document()
      assert length(document.probes) == length(ToolProbes.catalog())
      assert Enum.all?(document.probes, &(Map.keys(&1) |> Enum.sort() == [:argv, :name]))
    end
  end
end
