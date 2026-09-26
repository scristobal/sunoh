import argparse
import os
import pathlib
import shutil
import subprocess
import tempfile


def seed_files(source):
    path = pathlib.Path(source).expanduser()
    files = sorted(path.iterdir()) if path.is_dir() else [path]
    if path.is_dir():
        files = [file for file in files if file.suffix.lower() == '.gpx']
    if not files:
        raise ValueError(f'No GPX seed files found in {path}')
    for file in files:
        if file.suffix.lower() != '.gpx' or not file.is_file():
            raise ValueError(f'Expected a GPX file or directory of GPX files: {file}')
        with file.open('rb') as content:
            if not content.read(1):
                raise ValueError(f'GPX seed file is empty: {file}')
    return files


def main():
    parser = argparse.ArgumentParser(description='Import a GPX file or directory into Sunō on a simulator.')
    parser.add_argument('--check', action='store_true', help='Check the source without accessing a simulator.')
    parser.add_argument('paths', nargs='+', help='SOURCE with --check, otherwise SIMULATOR BUNDLE SOURCE')
    args = parser.parse_args()
    if len(args.paths) != (1 if args.check else 3):
        parser.error('Use --check SOURCE or SIMULATOR BUNDLE SOURCE')
    try:
        files = seed_files(args.paths[-1])
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.check:
        return

    simulator, bundle, source = args.paths
    container = pathlib.Path(subprocess.check_output(
        ['xcrun', 'simctl', 'get_app_container', simulator, bundle, 'data'], text=True).strip())
    # Stage only this invocation's files; remove them after the import finishes.
    with tempfile.TemporaryDirectory(prefix='sunoh-seed-', dir=container / 'tmp') as staging:
        for index, file in enumerate(files):
            shutil.copyfile(file, pathlib.Path(staging) / f'{index:06d}.gpx')
        print(f'Importing {len(files)} GPX files from {source}', flush=True)
        completed = False
        with subprocess.Popen(
            ['xcrun', 'simctl', 'launch', '--console-pty', simulator, bundle, '--seed', staging],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env={**os.environ, 'SIMCTL_CHILD_LLVM_PROFILE_FILE': str(container / 'tmp' / 'seed-%p.profraw')},
        ) as process:
            for line in process.stdout:
                print(line, end='', flush=True)
                if line.startswith('SUNOH_SEED_OK '):
                    completed = True
            result = process.wait()
        if result != 0 or not completed:
            raise SystemExit('Seed import failed. See the app output above; completed imports are preserved for retry.')

    subprocess.run(['xcrun', 'simctl', 'launch', simulator, bundle], check=True)


if __name__ == '__main__':
    main()
