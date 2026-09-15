"""Offline contract checks for the installed reviewer bridge; no provider calls."""
import hashlib
import json
import io
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
    def test_claude_catalog_initializes_without_a_model_turn(self):
        def fake_run(args, prompt=None, cwd=None, **kwargs):
            request = json.loads(prompt)
            self.assertEqual(request['type'], 'control_request')
            self.assertEqual(request['request']['subtype'], 'initialize')
            self.assertIn('--strict-mcp-config', args)
            self.assertEqual(kwargs['timeout'], 30)
            self.assertTrue(os.path.isdir(cwd))
            return json.dumps({'type': 'control_response', 'response': {
                'subtype': 'success', 'request_id': request['request_id'],
                'response': {'models': [{'value': 'opus[1m]', 'displayName': 'Opus'}]}}})
        with patch.dict(context, run=fake_run):
            self.assertEqual(context['catalog']('claude')['models'],
                             [{'id': 'opus[1m]', 'name': 'Opus'}])

    def test_claude_catalog_rejects_empty_malformed_and_unmatched_responses(self):
        for output in ('', '{}', 'not json', json.dumps({'type': 'control_response',
                       'response': {'subtype': 'success', 'request_id': 'wrong',
                                    'response': {'models': []}}})):
            with patch.dict(context, run=lambda *a, **k: output):
                with self.assertRaises(RuntimeError):
                    context['catalog']('claude')

    def test_claude_catalog_rejects_invalid_matching_payloads(self):
        for models in ([], None, [None], [{'value': 'bad;command', 'displayName': 'Bad'}],
                       [{'value': 'sonnet', 'displayName': 123}]):
            def fake_run(args, prompt, *a, **k):
                return json.dumps({'type': 'control_response', 'response': {
                    'subtype': 'success', 'request_id': json.loads(prompt)['request_id'],
                    'response': {'models': models}}})
            with patch.dict(context, run=fake_run):
                with self.assertRaises(RuntimeError):
                    context['catalog']('claude')

    def test_claude_review_accepts_catalog_context_alias(self):
        request = self.request('claude')
        request['settings']['reviewer_model'] = 'opus[1m]'
        def fake_run(args, *a, **k):
            self.assertEqual(args[args.index('--model') + 1], 'opus[1m]')
            return json.dumps({'session_id': '0199a213-81c0-7800-8aa1-bbab2a035a53', 'structured_output': {'summary': 'clear', 'findings': []}})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)['result']['summary'], 'clear')

    def request(self, kind='codex', effort=None):
        return {'settings': {'reviewer_kind': kind, 'reviewer_model': 'chosen-model',
                             'reviewer_effort': effort},
                'schema': {'type': 'object'}, 'repository_path': '/exact/readonly/snapshot', 'contract_version': 2, 'evidence': {'diff': 'untrusted diff'}}

    def test_missing_session_restarts_once_with_handoff_but_other_errors_do_not(self):
        request = self.request()
        request['session_id'] = '0199a213-81c0-7800-8aa1-bbab2a035a53'
        request['fallback_handoff'] = 'Previous review found a race; the implementer added locking.'
        expected = {'summary': 'clear', 'findings': []}
        calls = []
        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            calls.append(args)
            if 'resume' in args:
                raise RuntimeError('agent_command_failed exit=1: Session not found')
            self.assertIn(request['fallback_handoff'], prompt)
            self.assertLessEqual(timeout, 900)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0299a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            result = review(request)
        self.assertEqual(len(calls), 2)
        self.assertIn('started fresh', result['session_note'])
        with patch.dict(context, run=lambda *args, **kwargs: (_ for _ in ()).throw(RuntimeError('review_timeout'))):
            with self.assertRaisesRegex(RuntimeError, 'review_timeout'):
                review(request)

    def test_claude_and_cursor_resume_the_selected_session(self):
        session = '0199a213-81c0-7800-8aa1-bbab2a035a53'
        for kind in ('claude', 'cursor'):
            request = self.request(kind)
            request['session_id'] = session
            def fake_run(args, prompt, cwd, timeout=None, **kwargs):
                self.assertEqual(args[args.index('--resume') + 1], session)
                self.assertNotIn('--no-session-persistence', args)
                self.assertEqual(cwd, request['repository_path'])
                result = {'summary': 'clear', 'findings': []}
                return json.dumps({'session_id': session, 'structured_output': result, 'result': json.dumps(result)})
            with patch.dict(context, run=fake_run):
                self.assertEqual(review(request)['session_id'], session)

    def test_operation_wrapper_sends_plain_handoff_and_rejects_oversize_before_admission(self):
        main = runpy.run_path(str(ROOT / 'deploy/ptc-operation'))['main']
        with tempfile.TemporaryDirectory() as directory:
            context_file = Path(directory, 'context.json')
            context_file.write_text('{}')
            note = Path(directory, 'note.txt')
            note.write_text('Kept the locking strategy.\nTests passed.')
            calls = []
            def broker(context, fields):
                calls.append(fields)
                return {'state': 'passed'}
            with patch.dict(os.environ, PTC_MANAGED_OPERATION_CONTEXT=str(context_file)), \
                 patch.object(sys, 'argv', ['ptc-operation', 'review', '--handoff-file', str(note)]), \
                 patch.dict(main.__globals__, broker_request_with_retry=broker):
                self.assertEqual(main(), 0)
                self.assertEqual(calls[0]['handoff'], note.read_text())
                note.write_text('x' * 20_001)
                self.assertEqual(main(), 75)
                self.assertEqual(len(calls), 1)

    def test_operation_wrapper_names_the_missing_review_inside_a_repair(self):
        main = runpy.run_path(str(ROOT / 'deploy/ptc-operation'))['main']
        with tempfile.TemporaryDirectory() as directory:
            context_file = Path(directory, 'context.json')
            context_file.write_text('{}')
            def broker(context, fields):
                raise RuntimeError(':review_unavailable_in_action')
            captured = io.StringIO()
            with patch.dict(os.environ, PTC_MANAGED_OPERATION_CONTEXT=str(context_file)), \
                 patch.object(sys, 'argv', ['ptc-operation', 'review']), \
                 patch.dict(main.__globals__, broker_request_with_retry=broker), \
                 patch.object(sys, 'stderr', captured):
                self.assertEqual(main(), 76)
            self.assertIn("CI is the gate", captured.getvalue())
            self.assertNotIn('check the console', captured.getvalue())

    def test_codex_resumes_only_the_supplied_reviewer_session(self):
        request = self.request()
        session = '0199a213-81c0-7800-8aa1-bbab2a035a53'
        request['session_id'] = session
        expected = {'summary': 'The race is fixed.', 'findings': []}
        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            self.assertIn('resume', args)
            self.assertIn(session, args)
            self.assertNotIn('--last', args)
            self.assertNotIn('--ephemeral', args)
            self.assertIn('read-only', args)
            self.assertIn(request['repository_path'], args)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': session})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request), {'result': expected, 'session_id': session, 'usage': None})

    def test_scoped_diff_and_severity_rule_reach_the_reviewer(self):
        request = self.request()
        request['evidence'] = dict(request['evidence'], review_base_sha='a' * 40)
        expected = {'summary': 'clear', 'findings': []}
        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            self.assertIn('only the commits added since ' + 'a' * 40, prompt)
            self.assertIn('A review reporting no high or medium finding passes', prompt)
            self.assertIn('complete change remains in the', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)['result'], expected)

        request['evidence']['review_base_sha'] = 'nonsense'
        with patch.dict(context, run=fake_run):
            with self.assertRaisesRegex(RuntimeError, 'invalid_review_commit'):
                review(request)

    def test_a_regenerated_patch_never_claims_a_narrower_scope(self):
        request = self.request()
        full_patch = 'diff --git a/schema b/schema\n+' + 'x' * 600_000 + '\n'
        request['evidence'] = {'diff_on_disk': True, 'head_sha': 'a' * 40, 'base_sha': 'b' * 40,
                               'review_base_sha': 'c' * 40,
                               'diff_digest': hashlib.sha256(full_patch.encode()).hexdigest()}
        expected = {'summary': 'clear', 'findings': []}
        def fake_run(args, prompt=None, cwd=None, **kwargs):
            if args[0] == '/usr/bin/git':
                return full_patch
            self.assertNotIn('only the commits added since', prompt)
            self.assertIn('The complete diff is available locally at', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)['result'], expected)

    def test_a_whole_branch_review_claims_no_scope(self):
        request = self.request()
        expected = {'summary': 'clear', 'findings': []}
        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            self.assertNotIn('only the commits added since', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)['result'], expected)

    def test_reviewer_uses_exact_repository_and_can_read_linked_requirements(self):
        request = self.request()
        request['repository_path'] = '/exact/readonly/snapshot'
        expected = {'summary': 'clear', 'findings': []}
        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            self.assertEqual(cwd, request['repository_path'])
            self.assertIn('web_search="disabled"', args)
            self.assertIn('exact commit', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)["result"], expected)

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
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)["result"], expected)
            calls.clear()
            evidence['diff_digest'] = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'review_diff_digest_changed'):
                review(request)
            self.assertEqual(len(calls), 1)

    def test_each_provider_uses_selected_model_and_structured_result(self):
        expected = {'summary': 'clear', 'findings': []}
        for kind in ('codex', 'claude', 'cursor'):
            commands = []
            def fake_run(args, prompt, cwd, timeout=None, **kwargs):
                self.assertTrue(899 < timeout <= 900)
                commands.append(args)
                self.assertIn('untrusted diff', prompt)
                if kind == 'codex':
                    Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
                    return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
                return json.dumps({'structured_output': expected, 'session_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'} if kind == 'claude'
                                  else {'result': json.dumps(expected), 'session_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})
            with patch.dict(context, run=fake_run):
                self.assertEqual(review(self.request(kind))["result"], expected)
            self.assertEqual(commands[0][commands[0].index('--model') + 1], 'chosen-model')

    def test_sol_reviewer_uses_extra_high_effort(self):
        request = self.request('codex', 'xhigh')
        request['settings']['reviewer_model'] = 'gpt-5.6-sol'
        expected = {'summary': 'clear', 'findings': []}

        def fake_run(args, prompt, cwd, timeout=None, **kwargs):
            self.assertEqual(args[args.index('--model') + 1], 'gpt-5.6-sol')
            self.assertEqual(args[args.index('-c') + 1], 'model_reasoning_effort="xhigh"')
            self.assertIn('independent code reviewer', prompt)
            Path(args[args.index('-o') + 1]).write_text(json.dumps(expected))
            return json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'})

        with patch.dict(context, run=fake_run):
            self.assertEqual(review(request)["result"], expected)

    def test_custom_timeout_and_invalid_values(self):
        for kind in ('codex', 'claude', 'cursor'):
            request = self.request(kind)
            request['settings']['review_timeout_ms'] = 1_500_000
            def fake_run(args, prompt, cwd, timeout=None, **kwargs):
                self.assertTrue(1499 < timeout <= 1500)
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

    def test_codex_review_ignores_large_progress_and_stderr_but_keeps_final_result(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, 'codex')
            binary.write_text("""#!/usr/bin/env python3
import json, pathlib, sys
print(json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'}), flush=True)
for _ in range(3):
    print(json.dumps({'type': 'item.completed', 'output': 'x' * 1_100_000}), flush=True)
sys.stderr.write('verbose diagnostic' * 100_000)
pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_text(json.dumps({'summary': 'clear', 'findings': []}))
""")
            binary.chmod(0o755)
            request = self.request()
            request['repository_path'] = directory
            with patch.dict(context['BINARIES'], codex=str(binary)):
                result = review(request)
            self.assertEqual(result['result'], {'summary': 'clear', 'findings': []})
            self.assertEqual(result['session_id'], '0199a213-81c0-7800-8aa1-bbab2a035a53')

    def test_session_stream_handles_split_lines_and_rejects_missing_or_duplicate_identity(self):
        event = json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'}).encode()
        events = helper['CodexSessionEvents']()
        events.feed(b'x' * 5000)
        self.assertLessEqual(len(events.pending), 4096)
        events.feed(b'\n' + event[:7])
        events.feed(event[7:] + b'\n' + b'x' * 5000)
        self.assertEqual(json.loads(events.result())['thread_id'], '0199a213-81c0-7800-8aa1-bbab2a035a53')
        events.feed(b'\n')
        with self.assertRaisesRegex(RuntimeError, 'multiple_reviewer_sessions'):
            events.feed(event + b'\n')
        with self.assertRaisesRegex(RuntimeError, 'missing_reviewer_session'):
            helper['CodexSessionEvents']().result()

    def test_token_usage_is_per_invocation_and_cached_input_is_not_added_again(self):
        for _ in range(2):
            events = helper['CodexSessionEvents']()
            events.feed(json.dumps({'type': 'thread.started', 'thread_id': '0199a213-81c0-7800-8aa1-bbab2a035a53'}).encode() + b'\n')
            for usage in [{'input_tokens': 100, 'cached_input_tokens': 60, 'output_tokens': 10}, {'input_tokens': 50, 'cached_input_tokens': 30, 'output_tokens': 5}]:
                events.feed(json.dumps({'type': 'turn.completed', 'usage': usage}).encode()+b'\n')
            self.assertEqual(json.loads(events.result())['usage'], {'input_tokens': 150, 'cached_input_tokens': 90, 'output_tokens': 15})

    def test_streamed_progress_still_enforces_exit_status_timeout_and_result_file_limit(self):
        with self.assertRaisesRegex(RuntimeError, 'exit=23.*useful failure'):
            helper['run']([sys.executable, '-c', 'import sys; sys.stderr.write("x" * 1_100_000 + "useful failure"); sys.exit(23)'], session_events=True)
        with self.assertRaisesRegex(RuntimeError, 'review_timeout'):
            helper['run']([sys.executable, '-c', 'import time; time.sleep(5)'], timeout=0.05, session_events=True)
        with tempfile.TemporaryDirectory() as directory:
            result = Path(directory, 'result.json')
            result.write_text('x' * 150_001)
            with self.assertRaisesRegex(RuntimeError, 'invalid_result_file'):
                helper['read_json_file'](str(result), 150_000)

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
