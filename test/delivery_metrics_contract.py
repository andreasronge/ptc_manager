"""Offline cgroup telemetry contract: no agents, network or privileged writes."""
import runpy
import json
import io
import os
import threading
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

wrapper = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'deploy/ptc-operation'))
metrics = wrapper['resource_metrics']

class ResourceMetrics(unittest.TestCase):
    def test_cleanup_uses_no_follow_directory_descriptors(self):
        remove = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'priv/execution_artifact_cleanup.py'))['remove']
        with tempfile.TemporaryDirectory() as directory:
            root, outside = Path(directory, 'root'), Path(directory, 'outside')
            good = root / 'repository-1/job-1/agent-run-1'
            victim = outside / 'agent-run-1'
            good.mkdir(parents=True)
            victim.mkdir(parents=True)
            (good / 'manifest.json').write_text('{}')
            (victim / 'manifest.json').write_text('{}')
            (root / 'repository-1/escape').symlink_to(outside)
            with self.assertRaises(OSError):
                remove(str(root), 'repository-1/escape/agent-run-1')
            self.assertTrue((victim / 'manifest.json').exists())
            remove(str(root), 'repository-1/job-1/agent-run-1')
            self.assertFalse(good.exists())
            self.assertTrue(victim.exists())

    def test_short_progress_is_forwarded_before_stream_closes(self):
        for artifact_type in ('OperationArtifact', 'PassthroughArtifact'):
            with self.subTest(artifact_type=artifact_type), tempfile.TemporaryDirectory() as directory:
                forwarded = threading.Event()
                class LiveOutput(io.BytesIO):
                    def flush(self):
                        forwarded.set()
                live = LiveOutput()
                read_fd, write_fd = os.pipe()
                source = os.fdopen(read_fd, 'rb')
                artifact = wrapper[artifact_type].__new__(wrapper[artifact_type])
                artifact.directory, artifact.limit, artifact.records = directory, 1000000, {}
                args = ('stdout', source, live) if artifact_type == 'OperationArtifact' else (source, live)
                thread = threading.Thread(target=artifact._pump, args=args, daemon=True)
                thread.start()
                try:
                    os.write(write_fd, b'progress\n')
                    observed_live = forwarded.wait(1)
                finally:
                    os.close(write_fd)
                    thread.join(2)
                self.assertFalse(thread.is_alive())
                self.assertTrue(observed_live, 'short output was buffered until EOF')
                self.assertEqual(live.getvalue(), b'progress\n')

    def test_operation_manifest_declares_aggregate_stream_coverage(self):
        for states, expected in [(('complete', 'complete'), 'complete'),
                                 (('complete', 'partial'), 'partial'),
                                 (('partial', 'error'), 'error')]:
            with tempfile.TemporaryDirectory() as directory:
                artifact = wrapper['OperationArtifact'].__new__(wrapper['OperationArtifact'])
                artifact.directory = directory
                artifact.records = {name: {'coverage': state, 'path': name + '.log'}
                                    for name, state in zip(('stdout', 'stderr'), states)}
                artifact.seal(23)
                manifest = json.loads(Path(directory, 'manifest.json').read_text())
                self.assertEqual(manifest['coverage'], expected)
                self.assertEqual(manifest['exit_status'], 23)

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
