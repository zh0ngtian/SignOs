"""Home publishing must reject corrupt packages and retain the working manifest."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('home_source', Path(__file__).parents[1] / 'scripts/home_source.py')
home = importlib.util.module_from_spec(spec)
spec.loader.exec_module(home)


class HomeSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = self.root / 'cloud'
        (source / 'files').mkdir(parents=True)
        package = b'original signed IPA'
        (source / 'files/app.ipa').write_bytes(package)
        release = {'downloadURL': 'https://cloud.example/files/app.ipa',
                   'size': len(package), 'sha256': hashlib.sha256(package).hexdigest()}
        self.document = {'sourceURL': 'https://cloud.example/source.json',
                         'apps': [{**release, 'versions': [release]}]}
        self.raw = json.dumps(self.document).encode()
        (source / 'source.json').write_bytes(self.raw)
        self.config = {'sourceRoot': str(source), 'root': str(self.root / 'home/public'),
                       'sourceBaseUrl': 'https://cloud.example', 'baseUrl': 'https://home.example:15006'}

    def test_plan_rewrites_history_without_mutating_or_creating_files(self):
        raw, encoded, files = home.prepare(self.config)
        self.assertEqual(raw, self.raw)
        self.assertNotIn(b'cloud.example', encoded)
        self.assertIn(b'https://home.example:15006/files/app.ipa', encoded)
        self.assertEqual(len(files), 1)
        home.mirror(self.config, plan=True)
        self.assertFalse(Path(self.config['root']).exists())

    def test_corrupt_or_pending_source_is_rejected(self):
        source = Path(self.config['sourceRoot'])
        (source / 'files/app.ipa').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            home.prepare(self.config)
        (source / '.publish-base.sha256').touch()
        with self.assertRaisesRegex(ValueError, 'pending'):
            home.prepare(self.config)

    def test_file_url_cannot_escape_root(self):
        self.document['iconURL'] = 'https://cloud.example/files/../../secret.png'
        (Path(self.config['sourceRoot']) / 'source.json').write_text(json.dumps(self.document))
        with self.assertRaisesRegex(ValueError, 'Invalid file URL'):
            home.prepare(self.config)

    def test_download_failure_keeps_previous_manifest(self):
        root = Path(self.config['root'])
        root.mkdir(parents=True)
        (root / 'source.json').write_bytes(b'previous manifest')
        with patch.object(home, 'urlopen', return_value=io.BytesIO(self.raw)), \
             patch.object(home, 'verify_file', side_effect=ValueError('HTTPS failed')):
            with self.assertRaisesRegex(ValueError, 'HTTPS failed'):
                home.mirror(self.config)
        self.assertEqual((root / 'source.json').read_bytes(), b'previous manifest')

    def test_manifest_failure_rolls_back(self):
        root = Path(self.config['root'])
        root.mkdir(parents=True)
        (root / 'source.json').write_bytes(b'previous manifest')
        with patch.object(home, 'urlopen', side_effect=[io.BytesIO(self.raw), io.BytesIO(b'wrong manifest')]), \
             patch.object(home, 'verify_file'):
            with self.assertRaisesRegex(ValueError, 'manifest mismatch'):
                home.mirror(self.config)
        self.assertEqual((root / 'source.json').read_bytes(), b'previous manifest')


if __name__ == '__main__':
    unittest.main()
