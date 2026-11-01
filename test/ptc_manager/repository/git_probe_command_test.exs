defmodule PtcManager.Repository.GitProbeCommandTest do
  use ExUnit.Case, async: true

  alias PtcManager.Repository.GitProbe

  @moduletag :tmp_dir

  # The stderr reader must return at EOF on every supported coreutils. uutils
  # tail (Ubuntu 26.04) never did when the FIFO was its standard input, so every
  # Git call ran into the probe's timeout.
  test "a command that writes to stderr finishes and keeps only its stdout", %{tmp_dir: dir} do
    binary = Path.join(dir, "fake-git")
    File.write!(binary, "#!/bin/sh\nprintf 'diagnostic warning' >&2\nprintf 'main'\n")
    File.chmod!(binary, 0o755)

    {command, args} = GitProbe.command(binary, [])
    task = Task.async(fn -> System.cmd(command, args) end)

    assert {:ok, {"main", 0}} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end

  test "a failing command reports the last 2000 bytes of its stderr", %{tmp_dir: dir} do
    binary = Path.join(dir, "fake-git")
    noise = String.duplicate("x", 6_000)
    File.write!(binary, "#!/bin/sh\nprintf '#{noise}final diagnostic' >&2\nexit 3\n")
    File.chmod!(binary, 0o755)

    {command, args} = GitProbe.command(binary, [])
    task = Task.async(fn -> System.cmd(command, args) end)

    assert {:ok, {output, 3}} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert byte_size(output) == 2_000
    assert String.ends_with?(output, "final diagnostic")
  end
end
