"""Publishing regressions: migrate history and never expose an incomplete release."""
import hashlib
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('app_source', Path(__file__).parents[1] / 'scripts/app_source.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class FakeR2:
    def __init__(self):
        self.data = {}
        self.inventory = {}

    @contextlib.contextmanager
    def lock(self):
        yield

    def get(self, key):
        return self.data.get(key)

    def put(self, key, data):
        self.data[key] = data

    def list(self):
        return self.inventory


class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.remote = FakeR2()
        self.mock_control = patch.object(source, 'R2Control', return_value=self.remote)
        self.mock_control.start()
        self.addCleanup(self.mock_control.stop)
        self.config = {'root': str(self.root / 'cloud'), 'baseUrl': 'https://source.example', 'bucket': 'test'}

    def prepare(self):
        old = self.root / 'old'
        (old / 'files').mkdir(parents=True)
        ipa = old / 'files/app.ipa'
        ipa.write_bytes(b'unchanged IPA bytes')
        release = {'downloadURL': 'https://lan.example/files/app.ipa',
                   'size': ipa.stat().st_size, 'sha256': source.file_digest(ipa)}
        document = {'sourceURL': 'https://lan.example/source.json',
                    'iconURL': 'https://lan.example/files/icon.png',
                    'apps': [{**release, 'versions': [release]}]}
        (old / 'files/icon.png').write_bytes(b'icon bytes')
        (old / 'source.json').write_text(json.dumps(document))
        with contextlib.redirect_stdout(io.StringIO()):
            source.migrate(SimpleNamespace(from_root=str(old)), self.config)
        return old, Path(self.config['root'])

    def test_migration_preserves_original_and_rewrites_history(self):
        old, cloud = self.prepare()
        self.assertIn('https://lan.example', (old / 'source.json').read_text())
        self.assertNotIn('https://lan.example', (cloud / 'source.json').read_text())
        self.assertEqual((old / 'files/app.ipa').read_bytes(), (cloud / 'files/app.ipa').read_bytes())

    def test_failed_verification_does_not_publish_manifest(self):
        self.prepare()
        with patch.object(source.subprocess, 'run') as run, patch.object(source, 'urlopen', return_value=io.BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'verification failed'):
                source.sync(SimpleNamespace(transport='wrangler'), self.config)
            self.assertEqual(run.call_count, 1)
            self.assertIn('test/files/app.ipa', run.call_args.args[0])

    def test_corrupt_local_archive_is_rejected_before_upload(self):
        _, cloud = self.prepare()
        (cloud / 'files/app.ipa').write_bytes(b'changed')
        with patch.object(source.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'mismatch'):
                source.sync(SimpleNamespace(transport='wrangler'), self.config)
            run.assert_not_called()

    def test_budget_counts_orphans_and_blocks_before_upload(self):
        self.prepare()
        self.remote.inventory['files/retired.ipa'] = {'size': source.BUDGET_BYTES}
        with patch.object(source.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'budget exceeded'):
                source.sync(SimpleNamespace(transport='wrangler'), self.config)
            run.assert_not_called()
            self.assertEqual(self.remote.data, {})

    def test_stale_manifest_is_rejected_before_upload(self):
        self.prepare()
        self.remote.data['source.json'] = b'{"changed":true}'
        with patch.object(source.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Cloud manifest changed'):
                source.sync(SimpleNamespace(transport='wrangler'), self.config)
            run.assert_not_called()

    def test_keep_current_and_newest_nine(self):
        versions = [{'downloadURL': str(i), 'date': f'2026-09-{i+1:02d}T00:00:00Z'} for i in range(12)]
        manifest = {'apps': [{'downloadURL': '0', 'versions': versions}]}
        source.trim_versions(manifest)
        self.assertEqual([v['downloadURL'] for v in manifest['apps'][0]['versions']],
                         ['0', '11', '10', '9', '8', '7', '6', '5', '4', '3'])

    def test_failed_sync_can_retry_after_local_reformatting(self):
        _, cloud = self.prepare()
        original = (cloud / 'source.json').read_bytes()
        self.remote.data['source.json'] = original
        with patch.object(source, '_upload_locked', side_effect=ValueError('network failure')):
            with self.assertRaisesRegex(ValueError, 'network failure'):
                source.sync(SimpleNamespace(transport='wrangler'), self.config)
        self.assertEqual((cloud / '.publish-base.sha256').read_text(), hashlib.sha256(original).hexdigest())
        with patch.object(source, '_upload_locked') as upload:
            source.sync(SimpleNamespace(transport='wrangler'), self.config)
            upload.assert_called_once()
        self.assertFalse((cloud / '.publish-base.sha256').exists())


if __name__ == '__main__':
    unittest.main()
