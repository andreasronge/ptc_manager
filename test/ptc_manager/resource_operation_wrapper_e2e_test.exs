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

  test "wrapper uses the generic socket protocol and preserves child output" do
    root = Path.join(System.tmp_dir!(), "ptc-operation-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
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
    server = Task.async(fn -> fake_broker(listener, parent, 4) end)

    File.write!(
      context_path,
      Jason.encode!(%{
        "context_id" => "e2e-context",
        "token" => "fake-token",
        "socket_path" => socket_path,
        "lock_directory" => root
      })
    )

    wrapper = Path.expand("deploy/ptc-operation")

    assert {output, 0} =
             System.cmd(
               wrapper,
               [
                 "run",
                 "--label",
                 "test",
                 "--",
                 "/bin/sh",
                 "-c",
                 "printf 'managed:%s\\n' \"$PTC_OPERATION_ACTIVE\""
               ],
               env: [
                 {"PTC_MANAGED_OPERATION_CONTEXT", context_path},
                 {"PTC_OPERATION_POLL_SECONDS", "0.01"},
                 {"PTC_OPERATION_HEARTBEAT_SECONDS", "60"}
               ],
               stderr_to_stdout: true
             )

    assert output =~ "Waiting for PtcManager operation slot: test"
    assert output =~ "managed:77"
    assert_receive {:wrapper_request, %{"operation" => "request", "label" => "test"}}
    assert_receive {:wrapper_request, %{"operation" => "finish", "exit_status" => 0}}
    Task.await(server, 2_000)
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

  defp fake_broker(listener, parent, remaining) when remaining > 0 do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    request = Jason.decode!(line)
    send(parent, {:wrapper_request, request})

    response =
      case request["operation"] do
        "request" ->
          %{"status" => "queued", "operation_id" => 77}

        "acquire" ->
          %{
            "status" => "starting",
            "operation_id" => 77,
            "attempt_token" => "lease",
            "slot_number" => 1
          }

        "running" ->
          %{"status" => "running", "operation_id" => 77}

        "finish" ->
          %{"status" => "completed", "operation_id" => 77}
      end

    :ok = :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
    :gen_tcp.close(socket)
    fake_broker(listener, parent, remaining - 1)
  end

  defp fake_broker(listener, _parent, 0), do: :gen_tcp.close(listener)
end
