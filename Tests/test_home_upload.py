"""Exercise authentication, ingestion, rollback and concurrent source publication."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import io
import json
from pathlib import Path
import plistlib
import socket
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
import home_upload
import home_source


class HomeUploadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.staging, self.public = self.root / 'staging', self.root / 'public'
        self.staging.mkdir()
        self.public.mkdir()
        self.config = dict(backend='home', root=str(self.staging), publicRoot=str(self.public),
                           baseUrl='https://source.example', name='Test source', identifier='test.source')
        self.original = json.dumps(dict(sourceURL='https://source.example/source.json', apps=[], description='Test')).encode()
        for folder in (self.staging, self.public):
            (folder / 'source.json').write_bytes(self.original)
        self.token = 'a' * 43
        self.service = home_upload.UploadService(self.config, self.token,
                         home_upload.REPO / 'cloudflare/app-source/assets/app-store-ios27.png')
        self.server = home_upload.make_server(self.service, ('127.0.0.1', 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.addCleanup(patch.stopall)
        patch.object(home_upload.UploadHandler, 'log_message').start()
        self.verify = patch.object(home_source, 'verify_file', side_effect=self.verify_resource).start()
        patch.object(home_source, 'urlopen', side_effect=lambda *a, **k: io.BytesIO(
            (self.public / 'source.json').read_bytes())).start()

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def verify_resource(self, url, entry, full):
        path = self.public / url.removeprefix('https://source.example/')
        self.assertEqual(path.stat().st_size, entry['size'])
        if full:
            self.assertEqual(home_source.digest(path), entry['sha256'])

    def ipa(self, bundle='example.first', version='1.0', build='1', extra=b''):
        data = io.BytesIO()
        with zipfile.ZipFile(data, 'w') as archive:
            archive.writestr('Payload/Test.app/Info.plist', plistlib.dumps(dict(
                CFBundleIdentifier=bundle, CFBundleShortVersionString=version,
                CFBundleVersion=build, CFBundleDisplayName='测试应用')))
            archive.writestr('Payload/Test.app/Test', b'unchanged app bytes' + extra)
        return data.getvalue()

    def request(self, body, token=None, headers=None, path='/api/upload'):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=10)
        try:
            request_headers = {'Authorization': 'Bearer ' + (self.token if token is None else token),
                               'Content-Type': 'application/octet-stream', **(headers or {})}
            connection.request('POST', path, body=body, headers=request_headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def apps(self):
        return json.loads((self.public / 'source.json').read_text())['apps']

    def test_missing_or_wrong_token_does_not_write_or_read_body(self):
        for auth in ('', 'Bearer wrong'):
            connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
            connection.putrequest('POST', '/api/upload')
            connection.putheader('Content-Length', '999999')
            if auth:
                connection.putheader('Authorization', auth)
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
            connection.close()
        self.assertEqual(list(self.service.incoming.iterdir()), [])
        self.assertEqual((self.public / 'source.json').read_bytes(), self.original)

    def test_valid_upload_is_unchanged_and_visible_in_both_manifests(self):
        body = self.ipa()
        status, receipt = self.request(body, path='/api/upload?developer=Tester&notes=%E6%9B%B4%E6%96%B0')
        self.assertEqual(status, 201)
        self.assertEqual(receipt['sha256'], hashlib.sha256(body).hexdigest())
        self.assertEqual(receipt['size'], len(body))
        app = self.apps()[0]
        self.assertEqual(app['developerName'], 'Tester')
        self.assertEqual(app['versionDescription'], '更新')
        self.assertEqual((self.public / app['downloadURL'].split('.example/')[1]).read_bytes(), body)
        self.assertEqual((self.staging / 'source.json').read_bytes(), (self.public / 'source.json').read_bytes())
        self.assertFalse((self.staging / '.publish-base.sha256').exists())
        self.assertEqual(list(self.service.incoming.iterdir()), [])

    def test_duplicate_does_not_rewrite_metadata_or_current_version(self):
        old = self.ipa()
        self.assertEqual(self.request(old)[0], 201)
        self.assertEqual(self.request(self.ipa(version='2', build='2'))[0], 201)
        before = (self.public / 'source.json').read_bytes()
        status, receipt = self.request(old, path='/api/upload?developer=Replacement')
        self.assertEqual(status, 200)
        self.assertTrue(receipt['duplicate'])
        self.assertEqual((self.public / 'source.json').read_bytes(), before)

    def test_same_version_different_bytes_is_conflict(self):
        self.request(self.ipa())
        status, _ = self.request(self.ipa(extra=b'changed'))
        self.assertEqual(status, 409)
        self.assertEqual(len(self.apps()[0]['versions']), 1)

    def test_invalid_archive_and_checksum_never_publish(self):
        for body, headers, status in [(b'not an IPA', {}, 400), (self.ipa(), {'X-IPA-SHA256': '0' * 64}, 422)]:
            self.assertEqual(self.request(body, headers=headers)[0], status)
        self.assertEqual((self.public / 'source.json').read_bytes(), self.original)
        self.assertEqual(list(self.service.incoming.iterdir()), [])

    def test_corrupt_archive_crc_is_client_error(self):
        body = self.ipa()
        body = body.replace(b'unchanged app bytes', b'damagedxx app bytes')
        self.assertEqual(self.request(body)[0], 400)
        self.assertEqual(self.apps(), [])

    def test_reserved_signos_identity_requires_ota_receipt(self):
        self.assertEqual(self.request(self.ipa(bundle='com.signos.app'))[0], 403)
        self.assertEqual(self.apps(), [])

    def test_oversize_and_multipart_are_rejected(self):
        self.service.max_upload = 10
        self.assertEqual(self.request(b'x' * 11)[0], 413)
        self.service.max_upload = home_upload.MAX_UPLOAD
        self.assertEqual(self.request(self.ipa(), headers={'Content-Type': 'multipart/form-data'})[0], 415)

    def test_pending_local_publication_is_not_overwritten(self):
        marker = self.staging / '.publish-base.sha256'
        marker.write_text('pending')
        self.assertEqual(self.request(self.ipa())[0], 409)
        self.assertEqual(marker.read_text(), 'pending')
        self.assertEqual(self.apps(), [])

    def test_failed_publication_restores_staging_and_can_be_retried(self):
        self.verify.side_effect = ValueError('download failed')
        self.assertEqual(self.request(self.ipa())[0], 502)
        self.assertEqual((self.public / 'source.json').read_bytes(), self.original)
        self.assertEqual((self.staging / 'source.json').read_bytes(), self.original)
        self.assertFalse((self.staging / '.publish-base.sha256').exists())
        self.verify.side_effect = self.verify_resource
        self.assertEqual(self.request(self.ipa())[0], 201)

    def test_manifest_verification_failure_rolls_back(self):
        with patch.object(home_source, 'urlopen', return_value=io.BytesIO(b'wrong manifest')):
            self.assertEqual(self.request(self.ipa())[0], 502)
        self.assertEqual((self.public / 'source.json').read_bytes(), self.original)
        self.assertEqual((self.staging / 'source.json').read_bytes(), self.original)

    def test_parallel_uploads_preserve_both_apps(self):
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(self.request, [self.ipa(bundle='example.one'), self.ipa(bundle='example.two')]))
        self.assertEqual([r[0] for r in results], [201, 201])
        self.assertEqual({a['bundleIdentifier'] for a in self.apps()}, {'example.one', 'example.two'})

    def test_budget_rejection_leaves_previous_manifest(self):
        with patch.object(home_upload.app_source, 'BUDGET_BYTES', len(self.original) + len(self.ipa()) + 1):
            self.assertEqual(self.request(self.ipa())[0], 507)
        self.assertEqual(self.apps(), [])

    def test_admission_limit_rejects_without_temporary_files(self):
        self.service.slots.acquire()
        self.service.slots.acquire()
        try:
            self.assertEqual(self.request(self.ipa())[0], 503)
        finally:
            self.service.slots.release()
            self.service.slots.release()
        self.assertEqual(list(self.service.incoming.iterdir()), [])

    def test_incomplete_request_is_not_published(self):
        connection = socket.create_connection(self.server.server_address)
        connection.sendall(('POST /api/upload HTTP/1.1\r\nHost: local\r\nAuthorization: Bearer ' + self.token
                            + '\r\nContent-Type: application/octet-stream\r\nContent-Length: 20\r\n\r\nx').encode())
        connection.shutdown(socket.SHUT_WR)
        response = b''
        while block := connection.recv(4096):
            response += block
        connection.close()
        self.assertIn(b'400 Bad Request', response)
        self.assertEqual(self.apps(), [])


if __name__ == '__main__':
    unittest.main()
