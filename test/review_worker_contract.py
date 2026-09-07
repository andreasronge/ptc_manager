"""Offline contract checks for the installed reviewer bridge; no provider calls."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
helper = runpy.run_path(str(ROOT / 'deploy/ptc-manager-worker-review'))
review = helper['review']
context = review.__globals__


class ReviewerContract(unittest.TestCase):
    def request(self, kind='codex', effort=None):
        return {'settings': {'reviewer_kind': kind, 'reviewer_model': 'chosen-model',
                             'reviewer_effort': effort},
                'schema': {'type': 'object'}, 'repository_path': '/exact/readonly/snapshot', 'contract_version': 2, 'evidence': {'diff': 'untrusted diff'}}

    def test_reviewer_uses_exact_repository_and_disables_search(self):
        request = self.request()
        request['repository_path'] = '/exact/readonly/snapshot'
        expected = {'summary': 'clear', 'findings': []}
        def fake_run(args, prompt, cwd, timeout=None):
            self.assertEqual(cwd, request['repository_path'])
            self.assertIn('web_search="disabled"', args)
            self.assertIn('exact commit', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return ''
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request), expected)

    def test_large_patch_is_complete_and_digest_mismatch_never_launches_reviewer(self):
        request = self.request()
        full_patch = 'diff --git a/schema b/schema\n+' + 'x' * 600_000 + '\n'
        evidence = {'diff_on_disk': True, 'head_sha': 'a' * 40, 'base_sha': 'b' * 40,
                    'diff_digest': hashlib.sha256(full_patch.encode()).hexdigest()}
        request['evidence'] = evidence
        expected = {'summary': 'clear', 'findings': []}
        calls = []
        def fake_run(args, prompt=None, cwd=None, **kwargs):
            calls.append(args)
            if args[0] == '/usr/bin/git':
                return full_patch
            patch_path = prompt.split('The complete diff is available locally at ')[1]
            self.assertEqual(Path(patch_path).read_text(), full_patch)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return ''
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request), expected)
            calls.clear()
            evidence['diff_digest'] = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'review_diff_digest_changed'):
                review(request)
            self.assertEqual(len(calls), 1)

    def test_each_provider_uses_selected_model_and_structured_result(self):
        expected = {'summary': 'clear', 'findings': []}
        for kind in ('codex', 'claude', 'cursor'):
            commands = []
            def fake_run(args, prompt, cwd, timeout=None):
                self.assertEqual(timeout, 900)
                commands.append(args)
                self.assertIn('untrusted diff', prompt)
                if kind == 'codex':
                    Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
                    return 'terminal text is ignored'
                return json.dumps({'structured_output': expected} if kind == 'claude'
                                  else {'result': json.dumps(expected)})
            with patch.dict(context, run=fake_run):
                self.assertEqual(review(self.request(kind)), expected)
            self.assertEqual(commands[0][commands[0].index('--model') + 1], 'chosen-model')

    def test_sol_reviewer_uses_extra_high_effort(self):
        request = self.request('codex', 'xhigh')
        request['settings']['reviewer_model'] = 'gpt-5.6-sol'
        expected = {'summary': 'clear', 'findings': []}

        def fake_run(args, prompt, cwd, timeout=None):
            self.assertEqual(args[args.index('--model') + 1], 'gpt-5.6-sol')
            self.assertEqual(args[args.index('-c') + 1], 'model_reasoning_effort="xhigh"')
            self.assertIn('independent code reviewer', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return ''

        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request), expected)

    def test_custom_timeout_and_invalid_values(self):
        for kind in ('codex', 'claude', 'cursor'):
            request = self.request(kind)
            request['settings']['review_timeout_ms'] = 1_500_000
            def fake_run(args, prompt, cwd, timeout=None):
                self.assertEqual(timeout, 1500)
                raise RuntimeError('observed timeout')
            with patch.dict(context, run=fake_run):
                with self.assertRaisesRegex(RuntimeError, 'observed timeout'):
                    review(request)
        for value in (0, 3_600_001, True, '900000', None):
            request = self.request()
            request['settings']['review_timeout_ms'] = value
            with patch.dict(context, run=lambda *a, **kw: self.fail('agent launched')):
                with self.assertRaisesRegex(RuntimeError, 'invalid_review_timeout'):
                    review(request)

    def test_invalid_model_or_effort_never_launches_an_agent(self):
        with patch.dict(context, run=lambda *_: self.fail('agent launched')):
            request = self.request()
            request['settings']['reviewer_model'] = 'model; rm -rf /'
            with self.assertRaises(RuntimeError):
                review(request)
            with self.assertRaises(RuntimeError):
                review(self.request('cursor', 'high'))

    def test_output_link_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory, 'request.json')
            source.write_text('{}')
            victim = Path(directory, 'victim')
            victim.write_text('preserve')
            output = Path(directory, 'output.json')
            output.symlink_to(victim)
            main = helper['main']
            with patch.dict(main.__globals__, review=lambda _: {'summary': 'x', 'findings': []}), \
                 patch.object(sys, 'argv', ['helper', 'review', str(source), str(output)]):
                with self.assertRaises(FileExistsError):
                    main()
            self.assertEqual(victim.read_text(), 'preserve')

    def test_reads_reject_links_fifos_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory, 'data.json')
            source.write_text('{"findings": []}')
            link = Path(directory, 'link')
            link.symlink_to(source)
            fifo = Path(directory, 'fifo')
            os.mkfifo(fifo)
            with self.assertRaises(OSError):
                helper['read_json_file'](str(link), 100)
            for path, limit in ((fifo, 100), (source, 1)):
                with self.assertRaises(RuntimeError):
                    helper['read_json_file'](str(path), limit)

    def test_review_wrapper_without_context_preserves_work_and_reports_failure(self):
        environment = dict(os.environ)
        environment.pop('PTC_MANAGED_OPERATION_CONTEXT', None)
        result = subprocess.run([sys.executable, str(ROOT / 'deploy/ptc-operation'), 'review'],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 75)
        self.assertIn('preserve your work', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_existing_cli_state_can_grow_past_four_megabytes(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory, 'state.sqlite-wal')
            with state.open('wb') as output:
                output.truncate(4_000_000)
            command = [sys.executable, '-c',
                       'import sys; f = open(sys.argv[1], "ab"); f.write(b"x"); f.flush(); print("ok")',
                       str(state)]
            self.assertEqual(helper['run'](command).strip(), 'ok')

    def test_nonzero_exit_retains_bounded_stderr_and_status(self):
        command = [sys.executable, '-c',
                   'import sys; sys.stderr.write("review startup failed"); sys.exit(23)']
        with self.assertRaisesRegex(RuntimeError, 'exit=23.*review startup failed'):
            helper['run'](command)

    def test_stdout_and_stderr_are_bounded(self):
        for stream in ('stdout', 'stderr'):
            with self.assertRaisesRegex(RuntimeError, 'agent_output_too_large'):
                helper['run']([sys.executable, '-c',
                               f'import sys; sys.{stream}.write("x" * 1_000_001)'])

    def test_prompt_is_delivered_and_stderr_is_not_result_data(self):
        command = [sys.executable, '-c',
                   'import sys; sys.stderr.write("diagnostic"); print(sys.stdin.read())']
        self.assertEqual(helper['run'](command, prompt='bounded input').strip(), 'bounded input')

    def test_process_timeout_is_bounded(self):
        with self.assertRaisesRegex(RuntimeError, 'review_timeout'):
            helper['run']([sys.executable, '-c', 'import time; time.sleep(5)'], timeout=0.05)


if __name__ == '__main__':
    unittest.main()
