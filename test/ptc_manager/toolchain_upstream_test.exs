defmodule PtcManager.Toolchain.UpstreamTest do
  use PtcManager.DataCase, async: false

  alias PtcManager.Toolchain.Upstream

  defmodule Fetcher do
    @digest String.duplicate("a", 64)

    def get("https://nodejs.org/dist/index.json"),
      do:
        {:ok, [%{"version" => "v26.0.0"}, %{"version" => "v22.99.0"}, %{"version" => "v22.23.3"}]}

    def get("https://herdr.dev/latest.json"),
      do:
        {:ok, %{"version" => "0.9.1", "protocol" => 23, "sha256" => %{"linux-x86_64" => @digest}}}

    def get("https://api.github.com/repos/jdx/mise/releases/latest"),
      do:
        {:ok,
         %{
           "tag_name" => "v2026.9.12",
           "assets" => [
             %{
               "name" => "SHASUMS256.txt",
               "browser_download_url" => "https://example.test/checksums"
             }
           ]
         }}

    def get("https://api.github.com/repos/erlang/otp/releases/latest"),
      do: {:ok, %{"tag_name" => "OTP-29.1.1"}}

    def get("https://api.github.com/repos/elixir-lang/elixir/releases/latest"),
      do: {:ok, %{"tag_name" => "v1.20.4"}}

    def get(url) do
      if String.contains?(url, "codex"),
        do: {:ok, %{"version" => "0.999.0"}},
        else: {:error, :unavailable}
    end

    def body("https://github.com/jdx/mise/releases/download/v2026.9.12/SHASUMS256.txt"),
      do: {:ok, @digest <> "  ./mise-v2026.9.12-linux-x64\n"}

    def body("https://cursor.com/install"),
      do:
        {:ok,
         "DOWNLOAD_URL=\"https://downloads.cursor.com/lab/2026.09.18-9a7762b/${OS}/${ARCH}/agent-cli-package.tar.gz\"\n"}

    def archive_digest(
          "https://downloads.cursor.com/lab/2026.09.18-9a7762b/linux/x64/agent-cli-package.tar.gz"
        ),
        do: {:ok, @digest}
  end

  test "checks Node only within its pinned major and captures Herdr and mise digests" do
    previous = Application.get_env(:ptc_manager, :toolchain_upstream_fetcher)
    Application.put_env(:ptc_manager, :toolchain_upstream_fetcher, Fetcher)
    on_exit(fn -> restore(previous) end)

    assert {:ok, "22.99.0"} = Upstream.check("node")
    assert {:ok, "0.9.1"} = Upstream.check("herdr")
    assert {:ok, "2026.9.12"} = Upstream.check("mise")
    assert {:ok, "2026.09.18-9a7762b"} = Upstream.check("cursor_agent")
    assert {:ok, "29.1.1"} = Upstream.check("erlang")
    assert {:ok, "1.20.4"} = Upstream.check("elixir")
    refute Upstream.updatable?("erlang")
    checks = Upstream.list()
    assert checks["herdr"].protocol == 23
    assert checks["herdr"].digest == String.duplicate("a", 64)
    assert checks["mise"].digest == String.duplicate("a", 64)
    assert checks["cursor_agent"].digest == String.duplicate("a", 64)
  end

  test "stores a checked version and the time it was checked" do
    previous = Application.get_env(:ptc_manager, :toolchain_upstream_fetcher)
    Application.put_env(:ptc_manager, :toolchain_upstream_fetcher, Fetcher)
    on_exit(fn -> restore(previous) end)

    assert {:ok, "0.999.0"} = Upstream.check("codex")
    check = Upstream.list()["codex"]
    assert check.status == "ok"
    assert check.version == "0.999.0"
    assert check.checked_at != nil

    assert {:error, :unavailable} = Upstream.check("claude_code")
    assert Upstream.list()["claude_code"].status == "failed"
  end

  test "hashes a downloaded Cursor archive without loading it into memory" do
    path =
      Path.join(System.tmp_dir!(), "ptc-cursor-fixture-#{System.unique_integer([:positive])}")

    File.write!(path, "archive bytes")
    on_exit(fn -> File.rm(path) end)

    expected = :crypto.hash(:sha256, "archive bytes") |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Upstream.archive_digest("file://" <> path)
  end

  defp restore(nil), do: Application.delete_env(:ptc_manager, :toolchain_upstream_fetcher)
  defp restore(value), do: Application.put_env(:ptc_manager, :toolchain_upstream_fetcher, value)
end
