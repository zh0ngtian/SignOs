"""A staging renewal must never change or reload the production server."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('renew_home_tls', Path(__file__).parents[1] / 'scripts/renew_home_tls.py')
renew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renew)


class RenewalTests(unittest.TestCase):
    def config(self, root):
        return dict(acmeRoot=str(root / 'production'), docker='docker', credentials='/private/dns.env',
                    image='lego@sha256:pinned', email='owner@example.com', domain='home.example',
                    container='source', probeUrl='https://home.example:15006/source.json')

    def test_staging_has_separate_storage_and_never_reloads(self):
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            with patch.object(renew.subprocess, 'run') as execute, \
                 patch.object(renew, 'fingerprint', return_value='test'), patch.object(renew, 'peer') as peer:
                result = renew.run(config, staging=True)
            self.assertTrue(result['staging'])
            peer.assert_not_called()
            self.assertEqual(execute.call_count, 1)
            args = execute.call_args.args[0]
            self.assertIn('letsencrypt-staging', args)
            self.assertIn(str(Path(directory) / 'production-staging') + ':/acme', args)
            self.assertFalse(Path(config['acmeRoot']).exists())

    def test_failed_acme_does_not_reload_server(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(renew.subprocess, 'run', side_effect=RuntimeError('DNS failed')) as execute:
                with self.assertRaisesRegex(RuntimeError, 'DNS failed'):
                    renew.run(self.config(Path(directory)))
            self.assertEqual(execute.call_count, 1)

    def test_pending_reload_is_retried_when_certificate_already_renewed(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(renew.subprocess, 'run') as execute, \
                 patch.object(renew, 'fingerprint', return_value='new'), \
                 patch.object(renew, 'peer', side_effect=[('old', 'old date'), ('new', 'new date')]):
                result = renew.run(self.config(Path(directory)))
            self.assertTrue(result['tlsVerified'])
            self.assertEqual(execute.call_args_list[-1].args[0][-3:], ['nginx', '-s', 'reload'])


if __name__ == '__main__':
    unittest.main()
