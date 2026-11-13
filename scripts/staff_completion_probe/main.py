"""NEW repository-resident SQL-role regression probes; never recovered scratch."""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


class PreflightError(RuntimeError):
    """Only fixed prerequisite categories may cross the diagnostic boundary."""


def syntax_gate():
    for name in ('db.py','functional.py','races.py','main.py'):
        source = (HERE / name).read_text(encoding='utf-8')
        compile(source,str(HERE / name),'exec')
    for name, marker in (('fixtures.sql','insert into public.profiles'),
                         ('state.sql',"select current_setting('completion_probe.state');")):
        if marker not in (HERE / name).read_text(encoding='utf-8'):
            raise RuntimeError('incomplete SQL source')
    for name, sections in (('functional.py',('functional','permissions','rollback')),
                           ('races.py',('holder','wait','schedule','races'))):
        source = (HERE / name).read_text(encoding='utf-8')
        if any('def ' + section + '(' not in source for section in sections):
            raise RuntimeError('incomplete Python sections')
    if "if __name__ == '__main__':" not in (HERE / 'main.py').read_text(encoding='utf-8'):
        raise RuntimeError('missing guarded entrypoint')
    print('PASS complete-source compile and entrypoint gate',flush=True)


def preflight():
    if os.environ.get('HTTP_JWT_WORKDIR'):
        raise PreflightError('preflight: inherited context forbidden')
    for executable in ('node','pnpm.cmd' if os.name == 'nt' else 'pnpm','docker'):
        if not shutil.which(executable):
            raise PreflightError('preflight: executable unavailable: ' + executable)
    free = shutil.disk_usage(tempfile.gettempdir()).free
    payload = sum(p.stat().st_size for folder in ('migrations','tests')
                  for p in (ROOT / 'supabase' / folder).iterdir() if p.is_file())
    if free < max(1024**3,payload*4):
        raise PreflightError('preflight: insufficient scratch space')
    print('PASS payload/dependencies/capacity bytes=' + str(payload) +
          ' free=' + str(free),flush=True)


def cached_preflight():
    sys.path.insert(0,str(ROOT / 'scripts'))
    from http_test_support import cli, command
    try:
        services = cli(ROOT,'services','-o','json')
        if services.returncode:
            raise ValueError('unavailable')
        versions = {v['name']:v['local'] for v in json.loads(services.stdout)}
        images = (('postgres',versions['supabase/postgres']),
                  ('gotrue',versions['supabase/gotrue']),
                  ('postgrest',versions['postgrest/postgrest']),('kong','2.8.1'))
    except Exception:
        raise PreflightError('preflight: cached CLI services unavailable') from None
    for image, version in images:
        try:
            command(['docker','image','inspect','public.ecr.aws/supabase/%s:%s' % (image,version)])
        except Exception:
            raise PreflightError('preflight: cached image unavailable: ' + image) from None
    print('PASS cached-image preflight',flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--syntax-only',action='store_true',
                        help='compile complete sources only; cannot start Docker or database')
    parser.add_argument('--group',choices=('functional','permissions','rollback','races'),
                        help='run only this group in one NEW owned disposable stack')
    args = parser.parse_args()
    syntax_gate()
    if args.syntax_only:
        return 0
    preflight()
    sys.path.insert(0,str(ROOT / 'scripts'))
    from http_test_support import DisposableStack
    from db import DB
    import functional
    import races
    cached_preflight()
    stack = DisposableStack()
    with stack as path:
        print('Owned project: ' + path.name,flush=True)
        db = DB(path.name)
        db.sql((HERE / 'fixtures.sql').read_text(encoding='utf-8'))
        coverage = db.snapshot()
        print('STATE_COVERAGE tables=' + str(len(coverage['tables'])) +
              ' sequences=' + str(len(coverage['sequences'])),flush=True)
        groups = {'functional':functional.functional,'permissions':functional.permissions,
                  'rollback':functional.rollback,'races':races.races}
        try:
            for name, action in groups.items():
                if args.group is None or args.group == name:
                    db.group(name,action)
        finally:
            print('TOTAL ' + json.dumps({'assertions':db.assertions,'outcomes':db.outcomes,
                  'protected':db.protected,'waits':db.waits,'groups':db.groups},sort_keys=True),flush=True)
    print('PASS owned cleanup verified by DisposableStack',flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        # Fixed labels only: never print subprocess SQL, data, credentials or traceback.
        label = str(error) if isinstance(error,(AssertionError,PreflightError)) else type(error).__name__
        print('FAIL completion probe: ' + label,file=sys.stderr,flush=True)
        sys.exit(1)
