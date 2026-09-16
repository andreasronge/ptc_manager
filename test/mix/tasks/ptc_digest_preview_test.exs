defmodule Mix.Tasks.Ptc.Digest.PreviewTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "preview preserves general prose at the shortened rung like the manifest" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)

    output =
      capture_io("A useful description without headings.", fn ->
        Mix.Tasks.Ptc.Digest.Preview.run(["-"])
      end)

    [_before, shortened] = String.split(output, "[shortened]")
    assert shortened =~ "A useful description without headings."
  end
end
