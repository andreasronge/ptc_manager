"""Offline safety checks for the macOS host worker."""
import io
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
worker = runpy.run_path(str(ROOT / 'deploy/macos-deploy-host'))


class MacOSDeploymentContract(unittest.TestCase):
    def test_rejects_other_checkout_command_revision_and_status_destination(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / 'source'
            source.mkdir()
            request = {'deployment_id': 1, 'requested_sha': 'a' * 40,
                       'source_path': str(source), 'repository': 'andreasronge/ptc_manager',
                       'command': 'scripts/ptc/deploy', 'timeout_seconds': 1200,
                       'status_path': str(root / 'data/deployments/deployment-1.status.json')}
            with patch.dict(os.environ, PTC_MACOS_SOURCE=str(source)):
                self.assertEqual(worker['validate'](request, root)[1], 'a' * 40)
                for key, value in [('source_path', '/tmp/other'), ('command', 'rm -rf /'),
                                   ('requested_sha', '--help'), ('timeout_seconds', -1),
                                   ('status_path', '/tmp/elsewhere'), ('deployment_id', True)]:
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        worker['validate'](dict(request, **{key: value}), root)

    def test_archive_cannot_write_outside_build_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            checkout = root / 'source'
            checkout.mkdir()
            for name, target in [('../escape', None), ('link', '/tmp/escape')]:
                archive = root / 'source.tar'
                with tarfile.open(archive, 'w') as bundle:
                    member = tarfile.TarInfo(name)
                    if target:
                        member.type = tarfile.SYMTYPE
                        member.linkname = target
                    else:
                        member.size = 1
                    bundle.addfile(member, None if target else io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    worker['extract_archive'](archive, checkout)

    def test_deployment_archives_committed_revision_and_backs_up_database(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            source = root / 'source'
            source.mkdir()
            for args in [['init', '-q'], ['config', 'user.name', 'Test'],
                         ['config', 'user.email', 'test@example.invalid']]:
                subprocess.run(['git', '-C', str(source)] + args, check=True)
            (source / 'content').write_text('committed')
            subprocess.run(['git', '-C', str(source), 'add', 'content'], check=True)
            subprocess.run(['git', '-C', str(source), 'commit', '-qm', 'initial'], check=True)
            sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
            (source / 'content').write_text('uncommitted')
            for name in ['data/deployments', 'data/backups', 'logs', 'run', 'releases/old']:
                (root / name).mkdir(parents=True)
            (root / 'app').symlink_to(root / 'releases/old')
            (root / 'run/manager.pid').write_text(str(os.getpid()))
            database = root / 'data/database.db'
            with sqlite3.connect(database) as connection:
                connection.execute('create table preserved (value text)')
                connection.execute("insert into preserved values ('backup')")
            request = {'deployment_id': 1, 'requested_sha': sha, 'source_path': str(source),
                       'repository': 'andreasronge/ptc_manager', 'command': 'scripts/ptc/deploy',
                       'timeout_seconds': 30,
                       'status_path': str(root / 'data/deployments/deployment-1.status.json')}
            context = worker['deploy'].__globals__
            real_execute = context['execute']
            def execute(args, cwd, log, deadline, env):
                if args[0] == './scripts/ptc/deploy':
                    self.assertEqual((cwd / 'content').read_text(), 'committed')
                    self.assertEqual(env['PTC_DEPLOY_PLATFORM'], 'macos')
                    self.assertNotIn('PTC_MANAGER_PASSWORD', env)
                    (cwd / '_build/prod/rel/ptc_manager/bin').mkdir(parents=True)
                elif args[-1] != 'stop':
                    real_execute(args, cwd, log, deadline, env)
            with patch.dict(os.environ, PTC_MACOS_SOURCE=str(source), DATABASE_PATH=str(database),
                            PTC_MANAGER_PASSWORD='secret'), patch.dict(context, execute=execute, wait_health=lambda *args: None):
                worker['deploy'](request, root)
            status = json.loads(Path(request['status_path']).read_text())
            self.assertEqual(status['state'], 'completed')
            self.assertEqual((root / 'app/RELEASE_SHA').read_text().strip(), sha)
            with sqlite3.connect(next((root / 'data/backups').glob('*.db'))) as backup:
                self.assertEqual(backup.execute('select value from preserved').fetchone(), ('backup',))

    def test_release_switch_preserves_previous_release(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old, new = root / 'old', root / 'new'
            old.mkdir(); new.mkdir()
            (old / 'RELEASE_SHA').write_text('a' * 40)
            (root / 'app').symlink_to(old)
            worker['activate'](root, new)
            self.assertEqual((root / 'app').resolve(), new.resolve())
            self.assertEqual((old / 'RELEASE_SHA').read_text(), 'a' * 40)


if __name__ == '__main__':
    unittest.main()
