"""Publishing regressions: migrate history and never expose an incomplete release."""
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


class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
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


if __name__ == '__main__':
    unittest.main()
