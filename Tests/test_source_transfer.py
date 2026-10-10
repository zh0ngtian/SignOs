"""Incremental verification and bounded parallel upload regressions."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('transfer_source', Path(__file__).parents[1] / 'scripts/app_source.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)


class Response(io.BytesIO):
    def __init__(self, data, headers):
        super().__init__(data)
        self.headers = headers


class TransferTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'files').mkdir()
        (self.root / 'source.json').write_bytes(b'{"apps":[]}')
        self.config = dict(root=str(self.root), baseUrl='https://source.example', bucket='test', accountId='account')
        self.data = {'files/a.ipa': b'first archive', 'files/b.png': b'icon bytes'}
        self.objects = {}
        self.headers = {}
        self.requests = []
        self.uploads = []
        self.barrier = None
        self.fail_upload = None
        self.bad_download = None
        self.missing_head = None
        for key, data in self.data.items():
            (self.root / key).write_bytes(data)
            etag = hashlib.md5(data).hexdigest()
            self.objects[key] = dict(size=len(data), etag=etag)
            self.headers[key] = {'ETag': '"' + etag + '"', 'Content-Length': str(len(data)),
                                 'Last-Modified': 'Sun, 11 Oct 2026 00:00:00 GMT'}
        self.document = {'iconURL': self.config['baseUrl'] + '/files/b.png', 'apps': [{
            'downloadURL': self.config['baseUrl'] + '/files/a.ipa',
            'sha256': source.file_digest(self.root / 'files/a.ipa'),
            'size': len(self.data['files/a.ipa']),
        }]}
        (self.root / 'source.json').write_text(json.dumps(self.document))

    def open(self, request, timeout):
        key = request.full_url.removeprefix(self.config['baseUrl'] + '/')
        self.requests.append((request.get_method(), key))
        if key == 'source.json':
            return Response((self.root / key).read_bytes(), {})
        if key == self.missing_head and request.get_method() == 'HEAD':
            raise HTTPError(request.full_url, 404, 'Not Found', {}, None)
        data = b'bad bytes' if key == self.bad_download else self.data[key]
        return Response(data if request.get_method() == 'GET' else b'', self.headers[key])

    def run_upload(self, command, check):
        if command[0] == 'rclone':
            key = command[3].removeprefix(':s3:test/')
        else:
            key = command[4].removeprefix('test/')
        self.uploads.append((key, command))
        if key != 'source.json' and self.barrier:
            self.barrier.wait(timeout=3)
        if key == self.fail_upload:
            raise RuntimeError('upload failed')

    def sync(self, objects=None, previous=None, **options):
        args = SimpleNamespace(transport='s3', upload_workers=2, verify_all=False)
        for key, value in options.items():
            setattr(args, key, value)
        with patch.object(source, 'urlopen', side_effect=self.open), \
             patch.object(source.subprocess, 'run', side_effect=self.run_upload), \
             patch.dict(source.os.environ, AWS_ACCESS_KEY_ID='test', AWS_SECRET_ACCESS_KEY='test'), \
             contextlib.redirect_stdout(io.StringIO()):
            source._upload_locked(args, self.config, set(self.data), self.objects if objects is None else objects, previous)

    def test_published_history_uses_head_without_verification_receipts(self):
        self.bad_download = 'files/a.ipa'
        self.sync(previous=self.document)
        self.assertEqual(self.requests, [('HEAD', 'files/a.ipa'), ('HEAD', 'files/b.png'), ('GET', 'source.json')])
        self.assertFalse((self.root / '.verified-files.json').exists())

    def test_existing_remote_object_not_in_published_manifest_is_new(self):
        self.sync(previous={'iconURL': self.document['iconURL'], 'apps': []})
        self.assertIn(('GET', 'files/a.ipa'), self.requests)
        self.assertIn(('HEAD', 'files/b.png'), self.requests)

    def test_changed_manifest_digest_requires_full_download(self):
        previous = json.loads(json.dumps(self.document))
        previous['apps'][0]['sha256'] = '0' * 64
        self.sync(previous=previous)
        self.assertIn(('GET', 'files/a.ipa'), self.requests)

    def test_missing_history_or_wrong_size_blocks_manifest_publication(self):
        self.missing_head = 'files/a.ipa'
        with self.assertRaises(HTTPError):
            self.sync(previous=self.document)
        self.assertEqual(self.uploads, [])
        self.missing_head = None
        self.headers['files/a.ipa']['Content-Length'] = '1'
        with self.assertRaisesRegex(ValueError, 'size mismatch'):
            self.sync(previous=self.document)
        self.assertEqual(self.uploads, [])

    def test_history_force_all_or_repaired_missing_object_downloads_fully(self):
        self.sync(previous=self.document, verify_all=True)
        self.assertIn(('GET', 'files/a.ipa'), self.requests)
        self.requests.clear()
        del self.objects['files/a.ipa']
        self.sync(previous=self.document)
        self.assertIn(('GET', 'files/a.ipa'), self.requests)
        self.assertIn('files/a.ipa', [key for key, _ in self.uploads])

    def warm(self):
        self.sync()
        self.requests.clear()
        self.uploads.clear()

    def test_first_run_downloads_then_unchanged_history_only_uses_head(self):
        self.warm()
        self.assertTrue((self.root / '.verified-files.json').is_file())
        self.sync()
        self.assertEqual(self.requests, [('HEAD', 'files/a.ipa'), ('HEAD', 'files/b.png'), ('GET', 'source.json')])
        self.assertEqual([key for key, _ in self.uploads], ['source.json'])

    def test_changed_object_local_bytes_and_force_all_require_full_download(self):
        for change in ('inventory', 'head', 'local', 'force', 'scope', 'invalid_cache'):
            with self.subTest(change=change):
                self.setUp()
                self.warm()
                if change == 'inventory':
                    self.objects['files/a.ipa']['etag'] = 'new-object'
                elif change == 'head':
                    self.headers['files/a.ipa']['Last-Modified'] = 'Mon, 12 Oct 2026 00:00:00 GMT'
                elif change == 'local':
                    self.data['files/a.ipa'] = b'changed bytes'
                    (self.root / 'files/a.ipa').write_bytes(self.data['files/a.ipa'])
                elif change == 'scope':
                    self.config['bucket'] = 'other-bucket'
                elif change == 'invalid_cache':
                    (self.root / '.verified-files.json').write_text('invalid')
                self.sync(verify_all=change == 'force')
                self.assertIn(('GET', 'files/a.ipa'), self.requests)

    def test_missing_object_uploads_and_downloads_even_with_old_receipt(self):
        self.warm()
        del self.objects['files/a.ipa']
        self.sync()
        self.assertIn('files/a.ipa', [key for key, _ in self.uploads])
        self.assertIn(('GET', 'files/a.ipa'), self.requests)

    def test_new_files_upload_concurrently_with_multipart_options(self):
        self.barrier = threading.Barrier(2)
        self.sync(objects={})
        self.assertEqual({key for key, _ in self.uploads[:-1]}, set(self.data))
        self.assertEqual(self.uploads[-1][0], 'source.json')
        for _, command in self.uploads:
            self.assertEqual(command[command.index('--s3-upload-cutoff') + 1], '8Mi')
            self.assertEqual(command[command.index('--s3-upload-concurrency') + 1], '4')

    def test_upload_failure_never_publishes_manifest(self):
        self.barrier = threading.Barrier(2)
        self.fail_upload = 'files/a.ipa'
        with self.assertRaisesRegex(RuntimeError, 'upload failed'):
            self.sync(objects={})
        self.assertNotIn('source.json', [key for key, _ in self.uploads])
        self.assertEqual(self.requests, [])

    def test_failed_download_keeps_successful_receipt_for_retry(self):
        self.bad_download = 'files/b.png'
        with self.assertRaisesRegex(ValueError, 'verification failed'):
            self.sync()
        receipt = json.loads((self.root / '.verified-files.json').read_text())
        self.assertEqual(set(receipt['files']), {'files/a.ipa'})
        self.assertNotIn('source.json', [key for key, _ in self.uploads])
        self.bad_download = None
        self.requests.clear()
        self.sync()
        self.assertIn(('HEAD', 'files/a.ipa'), self.requests)
        self.assertNotIn(('GET', 'files/a.ipa'), self.requests)

    def test_missing_or_weak_etag_never_establishes_receipt(self):
        self.headers['files/a.ipa']['ETag'] = 'W/"weak"'
        self.warm()
        self.sync()
        self.assertIn(('GET', 'files/a.ipa'), self.requests)

    def test_failed_forced_recheck_invalidates_previous_receipt(self):
        self.warm()
        self.bad_download = 'files/a.ipa'
        with self.assertRaisesRegex(ValueError, 'verification failed'):
            self.sync(verify_all=True)
        receipt = json.loads((self.root / '.verified-files.json').read_text())
        self.assertNotIn('files/a.ipa', receipt['files'])
        self.bad_download = None
        self.requests.clear()
        self.sync()
        self.assertIn(('GET', 'files/a.ipa'), self.requests)

    def test_concurrency_is_bounded(self):
        for invalid in (0, 9):
            with self.assertRaises(source.argparse.ArgumentTypeError):
                self.sync(upload_workers=invalid)
        self.assertEqual(self.uploads, [])


if __name__ == '__main__':
    unittest.main()
