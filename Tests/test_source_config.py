"""Private endpoint settings must survive relocation without a public default."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'scripts'))
from source_config import load_config


class SourceConfigTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.env_file = self.root / 'private.env'
        self.config = self.root / 'source.json'
        self.config.write_text(json.dumps({'backend': 'home', 'baseUrlEnv': 'APP_SOURCE_BASE_URL'}))
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_private_file_loads_address_without_shell_execution(self):
        self.env_file.write_text('APP_SOURCE_BASE_URL="https://source.example:15006"\n'
                                 'APP_SOURCE_DOMAIN=source.example\nIGNORED_SECRET=private\n')
        result = load_config(self.config, env_file=self.env_file)
        self.assertEqual(result['baseUrl'], 'https://source.example:15006')
        self.assertEqual(os.environ['APP_SOURCE_DOMAIN'], 'source.example')
        self.assertNotIn('IGNORED_SECRET', os.environ)
        self.assertNotIn('baseUrl', json.loads(self.config.read_text()))

    def test_explicit_process_environment_overrides_file(self):
        self.env_file.write_text('APP_SOURCE_BASE_URL=https://file.example\n')
        os.environ['APP_SOURCE_BASE_URL'] = 'https://override.example/'
        self.assertEqual(load_config(self.config, env_file=self.env_file)['baseUrl'], 'https://override.example')

    def test_missing_or_invalid_address_has_no_default(self):
        for base in ('', 'http://source.example', 'https://name:secret@source.example',
                     'https://source.example/path', 'https://source.example?token=value'):
            with self.subTest(base=base):
                os.environ['APP_SOURCE_BASE_URL'] = base
                with self.assertRaisesRegex(ValueError, 'APP_SOURCE_BASE_URL'):
                    load_config(self.config, env_file=self.env_file)

    def test_retired_config_does_not_require_private_address(self):
        self.config.write_text(json.dumps({'disabled': True, 'baseUrlEnv': 'LEGACY_APP_SOURCE_BASE_URL'}))
        self.assertTrue(load_config(self.config, env_file=self.env_file)['disabled'])

    def test_relocated_client_uses_environment_and_fails_without_address(self):
        client = Path(__file__).parents[1] / 'distribution/app-source/upload_ipa.py'
        ipa = self.root / 'app.ipa'
        ipa.write_bytes(b'IPA plan bytes')
        command = [sys.executable, '-B', str(client), '--ipa', str(ipa), '--plan']
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APP_SOURCE_BASE_URL', result.stderr)
        os.environ['APP_SOURCE_BASE_URL'] = 'https://source.example:15006'
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)['url'], 'https://source.example:15006/api/upload')
        result = subprocess.run(command + ['--url', 'https://override.example/api/upload'],
                                check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(result.stdout)['url'], 'https://override.example/api/upload')


if __name__ == '__main__':
    unittest.main()
