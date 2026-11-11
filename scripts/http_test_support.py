"""Local-only HTTP probes: strict assertions and an owned disposable stack."""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import urllib.request
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
PNPM = 'pnpm.cmd' if os.name == 'nt' else 'pnpm'
EXCLUDE = 'realtime,storage-api,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor'


def error_matches(status, body, statuses=(401, 403), codes=('42501',)):
    return status in statuses and isinstance(body, dict) and body.get('error_code', body.get('code')) in codes


def local_origin(url, port):
    expected = 'http://127.0.0.1:%d' % port
    parts = urlsplit(url)
    if url != expected or parts.hostname != '127.0.0.1':
        raise ValueError('HTTP probe target must be the exact owned loopback origin')
    return expected


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def cli(workdir, *args, timeout=240):
    return subprocess.run([PNPM, 'exec', 'supabase', '--workdir', str(workdir), *args],
                          cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=timeout)


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', timeout=60)
    if result.returncode:
        raise RuntimeError('local Docker preflight failed (no credentials printed)')
    return result.stdout


def owned_context():
    path = Path(os.environ['HTTP_JWT_WORKDIR']).resolve()
    project = path.name
    if not re.fullmatch(r'http-jwt-[0-9a-f]{16}', project) or path.parent != Path(tempfile.gettempdir()).resolve():
        raise ValueError('HTTP probe workdir must be an owned temporary project')
    config = (path / 'supabase' / 'config.toml').read_text(encoding='utf-8')
    if 'project_id = "%s"' % project not in config:
        raise ValueError('HTTP probe project binding mismatch')
    context = json.loads((path / 'context.json').read_text(encoding='utf-8'))
    if context['project'] != project:
        raise ValueError('HTTP probe context binding mismatch')
    return path, context


class DisposableStack:
    def __enter__(self):
        # Supabase truncates project identities at 40 characters. Stay below it
        # so resource names, status and teardown all bind to the same identity.
        self.project = 'http-jwt-' + uuid.uuid4().hex[:16]
        self.path = Path(tempfile.gettempdir()) / self.project
        self.started = False
        try:
            # Match CLI versions to already cached local images. Never install
            # dependencies, pull images, or connect to a hosted Supabase project.
            services = cli(ROOT, 'services', '-o', 'json')
            if services.returncode:
                raise RuntimeError('cannot read local CLI service versions')
            versions = {x['name']: x['local'] for x in json.loads(services.stdout)}
            for name, version in [('postgres', versions['supabase/postgres']),
                                  ('gotrue', versions['supabase/gotrue']),
                                  ('postgrest', versions['postgrest/postgrest']), ('kong', '2.8.1')]:
                command(['docker', 'image', 'inspect', 'public.ecr.aws/supabase/%s:%s' % (name, version)])
            self.path.mkdir()
            folder = self.path / 'supabase'
            folder.mkdir()
            shutil.copytree(ROOT / 'supabase' / 'migrations', folder / 'migrations')
            shutil.copytree(ROOT / 'supabase' / 'tests', folder / 'tests')
            config = (ROOT / 'supabase' / 'config.toml').read_text(encoding='utf-8')
            config = re.sub(r'^project_id = .*$', 'project_id = "%s"' % self.project, config, flags=re.M)
            # Hold every selected port until all have been selected. Another
            # process can still race startup; that fails and cleans this project.
            sockets = []
            def port(match):
                sock = socket.socket()
                sock.bind(('127.0.0.1', 0))
                sockets.append(sock)
                return match.group(1) + str(sock.getsockname()[1])
            try:
                config = re.sub(r'^(\w*port\s*=\s*)\d+', port, config, flags=re.M)
                api_port = int(re.search(r'\[api\][\s\S]*?^port = (\d+)', config, re.M)[1])
                for section in ['studio', 'storage', 'realtime', 'local_smtp', 'analytics', 'edge_runtime', 'db.seed']:
                    config = re.sub(r'(\[' + re.escape(section) + r'\][\s\S]*?enabled = )true',
                                    r'\g<1>false', config, count=1)
                (folder / 'config.toml').write_text(config, encoding='utf-8')
                (self.path / 'context.json').write_text(json.dumps({'project': self.project, 'port': api_port}), encoding='utf-8')
            finally:
                for sock in sockets:
                    sock.close()
            self.started = True  # A failed/partial startup also requires teardown.
            print('Starting disposable local HTTP/JWT stack (cached images only).', flush=True)
            result = cli(self.path, 'start', '--exclude', EXCLUDE)
            if result.returncode:
                raise RuntimeError('disposable stack startup failed (output suppressed to protect credentials)')
            command(['docker', 'inspect', 'supabase_db_' + self.project])
            return self.path
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exc_type, exc, tb):
        if self.started:
            result = cli(self.path, 'stop', '--project-id', self.project, '--no-backup')
            if result.returncode:
                raise RuntimeError('owned stack teardown failed; project retained: ' + self.project)
            for resource in ('container', 'volume', 'network'):
                args = ['docker', resource, 'ls', '--filter', 'label=com.supabase.cli.project=' + self.project, '-q']
                if resource == 'container':
                    args.insert(3, '-a')
                if command(args).strip():
                    raise RuntimeError('owned Docker resources remain: ' + self.project)
        if self.path.exists():
            # The path is generated here, never accepted from a caller.
            if self.path.parent != Path(tempfile.gettempdir()).resolve() or self.path.name != self.project:
                raise RuntimeError('refusing unsafe temporary cleanup')
            shutil.rmtree(self.path)
        print('Disposable HTTP/JWT resources removed.', flush=True)


def isolated_run(script):
    with DisposableStack() as path:
        env = dict(os.environ, HTTP_JWT_WORKDIR=str(path), PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, '-B', str(script)], cwd=ROOT, env=env).returncode
