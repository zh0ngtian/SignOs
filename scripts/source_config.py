"""Resolve public source templates using an untracked private environment file."""
import json
import os
from pathlib import Path
import re
import shlex
from urllib.parse import urlsplit

PRIVATE_ENV = Path.home() / '.config/yao-app-source/home-source.env'


def load_environment(path=None):
    """Load only source endpoint settings; explicit process variables take precedence."""
    path = Path(path) if path is not None else PRIVATE_ENV
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        key, separator, value = line.strip().removeprefix('export ').partition('=')
        if not separator or key not in ('APP_SOURCE_DOMAIN', 'APP_SOURCE_BASE_URL'):
            continue
        parts = shlex.split(value, comments=True)
        if len(parts) != 1:
            raise ValueError('Invalid private environment setting: ' + key)
        os.environ.setdefault(key, parts[0])


def load_config(path, *, env_file=None):
    config = json.loads(Path(path).expanduser().read_text())
    variable = config.get('baseUrlEnv')
    if variable and not config.get('disabled'):
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', variable):
            raise ValueError('Invalid baseUrlEnv variable name')
        load_environment(env_file)
        base = os.environ.get(variable, '').rstrip('/')
        url = urlsplit(base)
        if (url.scheme != 'https' or not url.hostname or url.username or url.password
                or url.query or url.fragment or url.path):
            raise ValueError('Set ' + variable + ' to the private HTTPS source origin')
        config['baseUrl'] = base
    return config
