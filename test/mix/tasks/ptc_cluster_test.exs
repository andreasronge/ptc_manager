defmodule Mix.Tasks.Ptc.ClusterTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ptc.Cluster, as: Task
  alias PtcManager.Cluster

  test "a member agrees only with the same membership and protocol" do
    status = %{"membership_revision" => "r1", "protocol_version" => Cluster.protocol_version()}

    assert Task.agrees?({:ok, status}, "r1")
    refute Task.agrees?({:ok, status}, "r2")
    refute Task.agrees?({:ok, %{status | "protocol_version" => 99}}, "r1")
    refute Task.agrees?({:error, :not_a_member}, "r1")
  end

  test "each line names what was found" do
    status = %{
      "membership_revision" => "r1",
      "protocol_version" => Cluster.protocol_version(),
      "deployed_sha" => String.duplicate("b", 40),
      "_clock_skew_s" => -2
    }

    assert Task.line("beta", {:ok, status}, "r1") =~ "beta: ok · same membership"
    assert Task.line("beta", {:ok, status}, "r1") =~ "clock skew -2s"
    assert Task.line("beta", {:ok, status}, "r2") =~ "OTHER membership r1"
    assert Task.line("beta", {:error, :not_a_member}, "r1") =~ "REFUSED"

    assert Task.line("beta", {:error, {:bad_response_signature, :clock_skew}}, "r1") =~
             "SIGNATURE FAILURE"
  end
end
