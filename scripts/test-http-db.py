"""Run the pgTAP suite in an owned disposable local Supabase project."""
import sys

from http_test_support import DisposableStack, cli


def main():
    with DisposableStack() as workdir:
        result = cli(workdir, 'test', 'db', timeout=600)
        if result.stdout:
            print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, file=sys.stderr, end='')
        return result.returncode


if __name__ == '__main__':
    sys.exit(main())
