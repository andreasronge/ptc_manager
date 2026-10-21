defmodule PtcManager.ResourceOperationWrapperE2ETest do
  use ExUnit.Case, async: false

  @moduletag resource_e2e: true

  test "wrapper executes directly when no PtcManager context exists" do
    wrapper = Path.expand("deploy/ptc-operation")
    assert System.get_env("PTC_MANAGED_OPERATION_CONTEXT") == nil
    assert System.get_env("PTC_OPERATION_ACTIVE") == nil

    assert {"direct\n", 0} =
             System.cmd(wrapper, ["run", "--label", "test", "--", "/bin/echo", "direct"])
  end

  test "operation cgroup applies the verify soft limit and retains the hard limit" do
    wrapper = Path.expand("deploy/ptc-operation")

    python = """
    import importlib.machinery
    import importlib.util
    import io
    import json
    import sys
    from unittest.mock import patch

    loader = importlib.machinery.SourceFileLoader('ptc_operation', sys.argv[1])
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    context = {
        'cgroups': True,
        'operation_memory_high_bytes': 2147483648,
        'verify_operation_memory_high_bytes': 2577399808,
        'verify_agent_memory_high_bytes': 2952790016,
        'operation_memory_max_bytes': 2684354560,
    }
    writes = []
    with patch.object(module.platform, 'system', return_value='Linux'), \
         patch.object(module.os.path, 'exists', return_value=True), \
         patch('builtins.open', side_effect=lambda *args, **kwargs: io.StringIO('0::/ptc-agent-test/processes\\n')), \
         patch.object(module.os, 'mkdir'), \
         patch.object(module, 'read_text', return_value='2684354560'), \
         patch.object(module, 'write_text', side_effect=lambda path, value: writes.append((path, value))):
        module.create_operation_cgroup(context, 77, 'lease', 'verify')
        module.create_operation_cgroup(context, 78, 'lease', 'test')
        del context['verify_operation_memory_high_bytes']
        del context['verify_agent_memory_high_bytes']
        module.create_operation_cgroup(context, 79, 'lease', 'verify')
    print(json.dumps([value for path, value in writes if '/operation-' in path and path.endswith('/memory.high')]))
    print(json.dumps([value for path, value in writes if path.endswith('/ptc-agent-test/memory.high')]))
    print(json.dumps([value for path, value in writes if path.endswith('/memory.max')]))
    """

    assert {output, 0} = System.cmd("python3", ["-c", python, wrapper])
    assert [high, agent_high, max] = String.split(String.trim(output), "\n")
    assert Jason.decode!(high) == [2_577_399_808, 2_147_483_648, 2_577_399_808]
    assert Jason.decode!(agent_high) == [2_952_790_016, 2_952_790_016]
    assert Jason.decode!(max) == [2_684_354_560, 2_684_354_560, 2_684_354_560]
  end

  @tag :nightly
  test "wrapper uses the generic socket protocol and preserves multi-megabyte child output" do
    {output, status, root} =
      run_wrapped([
        "/usr/bin/python3",
        "-c",
        "import os, subprocess, sys; os.write(1, ('managed:' + os.environ['PTC_OPERATION_ACTIVE'] + '\\n').encode()); " <>
          "[(os.write(1, b'x' * 10000), os.write(2, b'y' * 10000)) for _ in range(220)]; " <>
          "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); sys.exit(23)"
      ])

    assert status == 23, output

    assert output =~ "Waiting for PtcManager operation slot: test"
    assert output =~ "managed:77"
    assert_receive {:wrapper_request, %{"operation" => "request", "label" => "test"}}
    assert_receive {:wrapper_request, %{"operation" => "finish", "exit_status" => 23}}

    [artifact] =
      Path.wildcard(Path.join(root, "artifacts/repository-12/job-34/operation-77-*/"))

    assert File.read!(Path.join(artifact, "stdout.log")) ==
             "managed:77\n" <> String.duplicate("x", 2_200_000)

    assert File.read!(Path.join(artifact, "stderr.log")) == String.duplicate("y", 2_200_000)
    assert byte_size(output) >= 4_400_000

    manifest = Path.join(artifact, "manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["streams"]["stdout"]["coverage"] == "complete"
    assert manifest["streams"]["stderr"]["coverage"] == "complete"
    assert manifest["ordering"] == "streams_are_independent"
    File.rm_rf!(root)
  end

  test "an explicitly managed command fails closed when its broker is unavailable" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ptc-operation-fail-closed-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    context_path = Path.join(root, "context.json")
    marker_path = Path.join(root, "must-not-run")

    File.write!(
      context_path,
      Jason.encode!(%{
        "context_id" => "fail-closed",
        "token" => "fake-token",
        "socket_path" => Path.join(root, "missing.sock"),
        "lock_directory" => root
      })
    )

    wrapper = Path.expand("deploy/ptc-operation")

    assert {output, 75} =
             System.cmd(
               wrapper,
               ["run", "--label", "test", "--", "/usr/bin/touch", marker_path],
               env: [{"PTC_MANAGED_OPERATION_CONTEXT", context_path}],
               stderr_to_stdout: true
             )

    assert output =~ "coordinator unavailable"
    refute File.exists?(marker_path)
    File.rm_rf!(root)
  end

  @tag :nightly
  test "a command that leaves no process behind finishes cleanly" do
    # macOS answers EPERM, not ESRCH, when the group holds only the exited leader.
    {output, status, root} = run_wrapped(["/usr/bin/python3", "-c", "pass"])

    assert status == 0, output
    refute output =~ "coordinator unavailable"
    assert_receive {:wrapper_request, %{"operation" => "finish", "exit_status" => 0}}
    File.rm_rf!(root)
  end

  @remaining %{"check_remaining_processes" => true}

  test "a launch the coordinator does not acknowledge starts no command" do
    for response <- [
          %{"status" => "cancelling", "operation_id" => 77},
          %{"status" => "lost", "operation_id" => 77},
          %{"status" => "running", "operation_id" => 78},
          %{"status" => "error", "error" => ":stale_operation_lease"},
          %{}
        ] do
      marker =
        Path.join(System.tmp_dir!(), "ptc-unacknowledged-#{System.unique_integer([:positive])}")

      {output, status, root} =
        run_wrapped(["/usr/bin/touch", marker], respond: %{"running" => response})

      assert status == 75, output
      assert output =~ "did not acknowledge the launch"
      refute File.exists?(marker)
      File.rm_rf!(root)
    end
  end

  test "a heartbeat refused as stale stops the command without finishing" do
    {output, status, root} =
      run_wrapped(["/usr/bin/python3", "-c", "import time; time.sleep(30)"],
        heartbeat_seconds: "0.05",
        respond: %{"heartbeat" => %{"status" => "error", "error" => ":stale_operation_lease"}}
      )

    assert status == 75, output
    assert output =~ "released this operation"
    assert_receive {:wrapper_request, %{"operation" => "heartbeat"}}
    refute_received {:wrapper_request, %{"operation" => "finish"}}
    File.rm_rf!(root)
  end

  test "a signal that arrives before the command starts reaches its group" do
    # The fake broker signals the wrapper while answering `running`, so the
    # signal lands before the command exists.
    {output, status, root} =
      run_wrapped(["/usr/bin/python3", "-c", "import time; time.sleep(30)"],
        respond: %{
          "running" => fn request ->
            System.cmd("kill", ["-TERM", Integer.to_string(request["wrapper_pid"])])
            %{"status" => "running", "operation_id" => 77}
          end
        }
      )

    assert status == 143, output
    assert_receive {:wrapper_request, %{"operation" => "finish", "exit_status" => 143}}
    File.rm_rf!(root)
  end

  test "a wrapper killed mid-run sends no finish and leaves the operation leased" do
    {output, _status, root} =
      run_wrapped(["/usr/bin/python3", "-c", "import time; time.sleep(30)"],
        respond: %{
          "running" => fn request ->
            pid = Integer.to_string(request["wrapper_pid"])
            Task.start(fn -> Process.sleep(300) && System.cmd("kill", ["-KILL", pid]) end)
            %{"status" => "running", "operation_id" => 77}
          end
        }
      )

    refute output =~ "Traceback"
    refute_received {:wrapper_request, %{"operation" => "finish"}}
    File.rm_rf!(root)
  end

  test "an escaped descendant that keeps the attempt marker is reported" do
    {output, status, root} =
      run_wrapped(
        [
          "/usr/bin/python3",
          "-c",
          "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], " <>
            "start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(p.pid)"
        ],
        context: @remaining
      )

    escaped = escaped_pid(output) |> String.to_integer()
    on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(escaped)]) end)

    assert status == 0, output
    assert output =~ "still running"

    assert_receive {:wrapper_request,
                    %{"operation" => "finish", "processes_remaining" => true} = finish}

    assert [%{"pid" => ^escaped, "command" => command}] = finish["remaining_processes"]
    assert command =~ "time.sleep(30)"
    refute command =~ "PTC_OPERATION_ATTEMPT"
    File.rm_rf!(root)
  end

  @tag :nightly
  test "an escaped descendant that holds the command's output is reported" do
    # No marker to find (macOS also hides it for Apple platform binaries such
    # as sleep), so only the inherited output identifies this process.
    {output, status, root} =
      run_wrapped(
        [
          "/usr/bin/python3",
          "-c",
          "import subprocess; p = subprocess.Popen(['/bin/sleep', '30'], env={}, start_new_session=True); " <>
            "print(p.pid, flush=True)"
        ],
        context: @remaining,
        timeout: "15"
      )

    escaped = escaped_pid(output)
    on_exit(fn -> System.cmd("kill", ["-KILL", escaped]) end)

    assert status == 0, output

    assert_receive {:wrapper_request,
                    %{"operation" => "finish", "processes_remaining" => true} = finish}

    assert finish["remaining_detail"] =~ "still holds its output"
    File.rm_rf!(root)
  end

  test "an escaped descendant that clears its environment and output is not detected" do
    # The documented residual risk: nothing identifies this process as ours.
    {output, status, root} =
      run_wrapped(
        [
          "/usr/bin/python3",
          "-c",
          "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], " <>
            "env={}, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); print(p.pid)"
        ],
        context: @remaining
      )

    escaped = escaped_pid(output)
    on_exit(fn -> System.cmd("kill", ["-KILL", escaped]) end)

    assert status == 0, output
    assert_receive {:wrapper_request, %{"operation" => "finish"} = finish}
    refute Map.has_key?(finish, "processes_remaining")
    File.rm_rf!(root)
  end

  test "zombie-only, mixed and delayed-exit groups finish normally" do
    for program <- [
          "pass",
          # A descendant in the group that leaves its own child unreaped.
          "import subprocess, sys; subprocess.Popen([sys.executable, '-c', " <>
            "'import subprocess, sys, time; subprocess.Popen([sys.executable, \"-c\", \"pass\"]); time.sleep(30)'])",
          # A descendant in the group that ignores SIGTERM and takes a moment to die.
          "import subprocess, sys; subprocess.Popen([sys.executable, '-c', " <>
            "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'], " <>
            "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)"
        ] do
      {output, status, root} =
        run_wrapped(["/usr/bin/python3", "-c", program], context: @remaining)

      assert status == 0, output
      refute output =~ "failed:"
      assert_receive {:wrapper_request, %{"operation" => "finish", "exit_status" => 0} = finish}
      refute Map.has_key?(finish, "processes_remaining")
      File.rm_rf!(root)
    end
  end

  defp escaped_pid(output), do: Regex.run(~r/^(\d+)$/m, output, capture: :all_but_first) |> hd()

  defp run_wrapped(command, opts \\ []) do
    root =
      Path.join(System.tmp_dir!(), "ptc-operation-e2e-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.mkdir!(Path.join(root, "artifacts"))
    socket_path = Path.join(root, "broker.sock")
    context_path = Path.join(root, "context.json")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ifaddr: {:local, socket_path},
        reuseaddr: true
      ])

    parent = self()
    # Each run gets its own attempt token, so its marker is its own.
    token = Base.url_encode64(:crypto.strong_rand_bytes(9))
    respond = Keyword.get(opts, :respond, %{})
    server = Task.async(fn -> fake_broker(listener, parent, respond, token) end)

    File.write!(
      context_path,
      Jason.encode!(
        Map.merge(
          %{
            "context_id" => "e2e-context",
            "token" => "fake-token",
            "socket_path" => socket_path,
            "lock_directory" => root,
            "artifact_root" => Path.join(root, "artifacts"),
            "artifact_max_bytes" => 8_000_000,
            "repository_id" => 12,
            "owner_type" => "job",
            "owner_id" => 34
          },
          Keyword.get(opts, :context, %{})
        )
      )
    )

    {output, status} =
      System.cmd(
        System.find_executable("timeout") || flunk("needs coreutils timeout on PATH"),
        [
          Keyword.get(opts, :timeout, "5"),
          Path.expand("deploy/ptc-operation"),
          "run",
          "--label",
          "test",
          "--" | command
        ],
        env: [
          {"PTC_MANAGED_OPERATION_CONTEXT", context_path},
          {"PTC_OPERATION_POLL_SECONDS", "0.01"},
          {"PTC_OPERATION_HEARTBEAT_SECONDS", Keyword.get(opts, :heartbeat_seconds, "60")}
        ],
        stderr_to_stdout: true
      )

    :gen_tcp.close(listener)
    Task.await(server, 2_000)
    {output, status, root}
  end

  defp fake_broker(listener, parent, respond, token) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
        request = Jason.decode!(line)
        send(parent, {:wrapper_request, request})

        response =
          case Map.get(respond, request["operation"], default_response(request, token)) do
            reply when is_function(reply, 1) -> reply.(request)
            reply -> reply
          end

        :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
        :gen_tcp.close(socket)
        fake_broker(listener, parent, respond, token)

      {:error, _closed} ->
        :ok
    end
  end

  defp default_response(%{"operation" => "request"}, _token),
    do: %{"status" => "queued", "operation_id" => 77}

  defp default_response(%{"operation" => "acquire"}, token),
    do: %{
      "status" => "starting",
      "operation_id" => 77,
      "attempt_token" => token,
      "slot_number" => 1
    }

  defp default_response(%{"operation" => operation}, _token)
       when operation in ["running", "heartbeat"],
       do: %{"status" => "running", "operation_id" => 77}

  defp default_response(%{"operation" => "finish"} = request, _token) do
    if request["processes_remaining"],
      do: %{"status" => "recovery_pending", "operation_id" => 77},
      else: %{"status" => "completed", "operation_id" => 77}
  end
end
