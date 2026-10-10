"""Reject the wrong build before exposing a SignOs release in the app source."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import publish_signos


class SignOsReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ipa = self.root / 'signed.ipa'
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            archive.writestr('Payload/SignOs.app/Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'com.signos.app', 'CFBundleShortVersionString': '1.0.1',
                'CFBundleVersion': '2', 'CFBundleDisplayName': 'SignOs',
            }))
        self.receipt = dict(signed=True, bundleId='com.signos.app', version='1.0.1',
                            buildNumber='2', size=self.ipa.stat().st_size,
                            sha256=hashlib.sha256(self.ipa.read_bytes()).hexdigest(),
                            notes='Release notes', publishedAt='2026-10-10T09:21:49Z')
        self.receipt_path = self.root / 'release.json'
        self.args = SimpleNamespace(ipa=str(self.ipa), release_json=str(self.receipt_path))

    def save_receipt(self):
        self.receipt_path.write_text(json.dumps(self.receipt))

    def test_rejects_different_ipa_bytes(self):
        self.save_receipt()
        self.ipa.write_bytes(self.ipa.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            publish_signos.prepare(self.args)

    def test_rejects_wrong_identity_or_build(self):
        for field, value in [('signed', False), ('bundleId', 'other.app'), ('buildNumber', '3')]:
            with self.subTest(field=field):
                original = self.receipt[field]
                self.receipt[field] = value
                self.save_receipt()
                with self.assertRaises(ValueError):
                    publish_signos.prepare(self.args)
                self.receipt[field] = original

    def test_plan_does_not_create_source(self):
        self.save_receipt()
        config = self.root / 'config.json'
        destination = self.root / 'not-created'
        config.write_text(json.dumps({'root': str(destination), 'baseUrl': 'https://source.example'}))
        result = subprocess.run([sys.executable, publish_signos.__file__, '--ipa', str(self.ipa),
                                 '--release-json', str(self.receipt_path), '--config', str(config),
                                 '--plan'], check=True, capture_output=True, text=True)
        self.assertTrue(json.loads(result.stdout)['plan'])
        self.assertFalse(destination.exists())

    def test_staging_preserves_other_apps_and_receipt_metadata(self):
        self.save_receipt()
        args, _ = publish_signos.prepare(self.args)
        root = self.root / 'source'
        root.mkdir()
        other_app = {'bundleIdentifier': 'other.app', 'versions': [{'version': '5'}]}
        (root / 'source.json').write_text(json.dumps({'apps': [other_app], 'description': 'Test'}))
        config = dict(root=str(root), baseUrl='https://source.example', name='Test', identifier='test')
        with contextlib.redirect_stdout(io.StringIO()):
            publish_signos.app_source.publish(args, config)
        apps = json.loads((root / 'source.json').read_text())['apps']
        self.assertEqual(apps[0], other_app)
        self.assertEqual(apps[1]['sha256'], self.receipt['sha256'])
        self.assertEqual(apps[1]['buildVersion'], '2')
        self.assertEqual(apps[1]['versions'][0]['localizedDescription'], self.receipt['notes'])


if __name__ == '__main__':
    unittest.main()
