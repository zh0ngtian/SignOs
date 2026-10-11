import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import cloud_source
import migrate_cloud_source


class CloudArchiveRegression(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / 'generated-original-name.ipa'
        self.ipa.write_bytes(b'immutable archived IPA bytes')
        self.digest = hashlib.sha256(self.ipa.read_bytes()).hexdigest()
        self.asset = {'id': 123, 'name': 'App.ipa', 'size': self.ipa.stat().st_size,
                      'digest': 'sha256:' + self.digest, 'browser_download_url': 'https://github.com/example/repo/releases/download/v1/App.ipa'}

    def test_uploaded_filename_matches_rule_and_bytes_are_preserved(self):
        uploaded = False

        def gh(*args, **kwargs):
            nonlocal uploaded
            if args[:2] == ('release', 'upload'):
                staged = Path(args[3])
                self.assertEqual(staged.name, 'App.ipa')
                self.assertEqual(staged.read_bytes(), self.ipa.read_bytes())
                uploaded = True
                return ''
            return {'assets': [self.asset] if uploaded else []}

        with patch.object(cloud_source, 'gh', side_effect=gh):
            self.assertEqual(cloud_source.archive_asset(self.ipa, 'v1', 'App.ipa', self.digest), self.asset['browser_download_url'])

    def test_identical_wrongly_named_asset_is_renamed_without_reupload(self):
        original = {**self.asset, 'name': self.ipa.name}
        with patch.object(cloud_source, 'gh', side_effect=[{'assets': [original]}, self.asset]) as gh:
            cloud_source.archive_asset(self.ipa, 'v1', 'App.ipa', self.digest)
        self.assertEqual(gh.call_args_list[1].args[1:3], ('--method', 'PATCH'))
        self.assertIn('name=App.ipa', gh.call_args_list[1].args)

    def test_conflicting_existing_asset_is_never_overwritten(self):
        with patch.object(cloud_source, 'gh', return_value={'assets': [{**self.asset, 'digest': 'sha256:' + '0' * 64}]}) as gh:
            with self.assertRaises(ValueError):
                cloud_source.archive_asset(self.ipa, 'v1', 'App.ipa', self.digest)
        self.assertEqual(gh.call_count, 1)

    def test_sync_discards_stale_release_selection(self):
        client = cloud_source.Client({'url': 'https://source.example', 'token': 'test'})
        target = self.asset['browser_download_url']
        with patch.object(client, 'call') as call, patch.object(client, 'entry', side_effect=[
            {'status': 'ready', 'current': {'downloadURL': 'https://source.example/old.ipa'}},
            {'status': 'succeeded', 'current': {'downloadURL': target}},
        ]):
            self.assertEqual(client.sync_to('id', target)['current']['downloadURL'], target)
        self.assertEqual(call.call_count, 2)

    def test_latest_only_plan_does_not_read_historical_packages(self):
        root = Path(self.directory.name)
        (root / 'icon.png').write_bytes(b'icon')
        (root / 'source.json').write_text(json.dumps({'identifier': 'test', 'apps': [{
            'bundleIdentifier': 'com.example.app', 'iconURL': 'https://source.example/icon.png',
            'versions': [{'downloadURL': 'https://source.example/' + self.ipa.name,
                          'size': self.ipa.stat().st_size, 'sha256': self.digest},
                         {'downloadURL': 'https://source.example/missing-historical.ipa'}],
        }]}))
        output = io.StringIO()
        with patch.object(sys, 'argv', ['migrate_cloud_source.py', '--source-root', str(root), '--plan']), contextlib.redirect_stdout(output):
            migrate_cloud_source.main()
        plan = json.loads(output.getvalue())
        self.assertTrue(plan['latestOnly'])
        self.assertEqual(plan['apps'][0]['versions'], 1)


if __name__ == '__main__':
    unittest.main()
