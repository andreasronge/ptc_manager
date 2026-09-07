"""Offline cgroup telemetry contract: no agents, network or privileged writes."""
import runpy
from pathlib import Path
import unittest
from unittest.mock import patch

wrapper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'deploy/ptc-operation'))
metrics = wrapper['resource_metrics']

class ResourceMetrics(unittest.TestCase):
    def test_descendant_cpu_memory_and_io_counters_and_ancestor_limits(self):
        root='/sys/fs/cgroup/agent/operation'
        files={root+'/cpu.stat':'usage_usec 180000000\nuser_usec 170000000\nsystem_usec 10000000\nthrottled_usec 5000',root+'/memory.events':'high 2\noom_kill 1',root+'/io.stat':'8:0 rbytes=100 wbytes=20\n8:1 rbytes=50 wbytes=10',root+'/cpu.max':'max 100000',root+'/memory.max':'8589934592','/sys/fs/cgroup/agent/cpu.max':'200000 100000','/sys/fs/cgroup/agent/memory.max':'4294967296'}
        with patch.dict(metrics.__globals__,read_text=lambda p:files.get(p)), patch('os.sched_getaffinity',return_value={0,1,2,3},create=True):
            result=metrics(root)
        self.assertEqual(result['cpu_usage_usec'],180000000)
        self.assertEqual(result['io_read_bytes'],150)
        self.assertEqual(result['oom_kills'],1)
        self.assertEqual(result['allowed_cpus'],4)
        self.assertEqual(result['cpu_quota_millicores'],2000)
        self.assertEqual(result['memory_limit_bytes'],4294967296)

    def test_missing_or_unreadable_metrics_do_not_fail_the_command(self):
        self.assertIsNone(metrics(None))
        with patch.dict(metrics.__globals__,read_text=lambda _:None), patch('os.sched_getaffinity',side_effect=OSError(),create=True):
            self.assertIsNone(metrics('/sys/fs/cgroup/agent/operation'))

if __name__=='__main__': unittest.main()
