import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
import pathlib
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET


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


def validate_manifest(path, files):
    manifest = json.loads(pathlib.Path(path).read_text())
    entries = manifest['activities']
    if not entries or len(entries) != len(files) or {p.name for p in files} != {e['gpx'] for e in entries}:
        raise ValueError('GPX files do not match the prepared Slopes manifest')
    source = pathlib.Path(manifest['source'])
    for entry in entries:
        if pathlib.Path(entry['archive']).name != entry['archive'] or pathlib.Path(entry['gpx']).name != entry['gpx']:
            raise ValueError('Manifest filenames must not contain directories')
        for file, expected in [(source / entry['archive'], entry['archive_sha256']),
                               (files[0].parent / entry['gpx'], entry['gpx_sha256'])]:
            if hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                raise ValueError(f'Seed source changed: {file}. Run just prepare-seed again.')
        root = ET.parse(files[0].parent / entry['gpx']).getroot()
        points = root.findall('.//{http://www.topografix.com/GPX/1/1}trkpt')
        if len(points) != entry['points']:
            raise ValueError(f'Point count differs from the manifest: {entry["gpx"]}')
    print(f'Validated {len(entries)} Slopes activities and {sum(e["points"] for e in entries)} GPX points', flush=True)
    return manifest


def observation_signature(points):
    digest = hashlib.sha256()
    count = 0
    for timestamp, latitude, longitude, elevation in points:
        digest.update(struct.pack('>qdd', timestamp, latitude, longitude))
        digest.update(b'none' if elevation is None else struct.pack('>d', elevation))
        count += 1
    return count, digest.hexdigest()


def gpx_signature(file):
    root = ET.parse(file).getroot()
    ns = '{http://www.topografix.com/GPX/1/1}'
    points = []
    for point in root.iter(ns + 'trkpt'):
        timestamp = datetime.fromisoformat(point.findtext(ns + 'time').replace('Z', '+00:00'))
        # Foundation's GPX date parser retains milliseconds and discards smaller fractions.
        elapsed = timestamp - datetime(1970, 1, 1, tzinfo=timezone.utc)
        milliseconds = (elapsed.days * 86400 + elapsed.seconds) * 1000 + elapsed.microseconds // 1000
        elevation = point.findtext(ns + 'ele')
        points.append((milliseconds, float(point.attrib['lat']), float(point.attrib['lon']),
                       float(elevation) if elevation is not None else None))
    return observation_signature(points)


def verify_import(container, files):
    expected = Counter(gpx_signature(file) for file in files)
    database = container / 'Library/Application Support/Activities/Activities.store'
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
        if connection.execute('PRAGMA quick_check').fetchone() != ('ok',):
            raise ValueError('Seed database failed its integrity check')
        saved = Counter()
        for (activity,) in connection.execute('SELECT ZID FROM ZSTOREDACTIVITY'):
            points = connection.execute('SELECT ZRECORDEDATMILLISECONDS, ZLATITUDE, ZLONGITUDE, ZELEVATIONMETERS '
                                        'FROM ZSTOREDTRACKPOINT WHERE ZACTIVITYID = ? ORDER BY ZRECORDEDATMILLISECONDS', (activity,))
            saved[observation_signature(points)] += 1
    if expected - saved:
        raise ValueError('The saved observations do not match all prepared seed activities')
    print(f'Verified {len(files)} saved activities: timestamps, coordinates, elevations and point counts match GPX', flush=True)


def seed_physical(device, bundle, files):
    domain = ['--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', bundle]
    with tempfile.TemporaryDirectory(prefix='sunoh-device-seed-') as temporary:
        root = pathlib.Path(temporary)
        remote = f'tmp/{root.name}'
        staging = root / 'gpx'
        staging.mkdir()
        for index, file in enumerate(files):
            shutil.copyfile(file, staging / f'{index:06d}.gpx')
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'to', *domain,
                        '--source', str(staging), '--destination', remote], check=True)
        completed = False
        with subprocess.Popen(['xcrun', 'devicectl', 'device', 'process', 'launch',
                               '--device', device, '--terminate-existing', '--console',
                               bundle, '--seed', remote], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as process:
            for line in process.stdout:
                print(line, end='', flush=True)
                if line.startswith('SUNOH_SEED_OK '):
                    completed = True
            result = process.wait()
        if result != 0 or not completed:
            raise SystemExit('Device seed import failed. Completed imports are preserved for retry.')
        # The importer has exited, so copy a consistent store for read-only verification.
        container = root / 'verification'
        destination = container / 'Library/Application Support/Activities'
        destination.parent.mkdir(parents=True)
        subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', *domain,
                        '--source', 'Library/Application Support/Activities',
                        '--destination', str(destination)], check=True)
        verify_import(container, files)
    subprocess.run(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, bundle], check=True)


def main():
    parser = argparse.ArgumentParser(description='Import GPX recordings into a Debug installation of Sunō.')
    parser.add_argument('--check', action='store_true', help='Check the source without accessing a simulator.')
    parser.add_argument('--manifest', help='Validate the original Slopes archives and generated GPX before importing')
    parser.add_argument('--physical', action='store_true', help='Use a paired physical iPhone instead of a simulator')
    parser.add_argument('paths', nargs='+', help='SOURCE with --check, otherwise DEVICE BUNDLE SOURCE')
    args = parser.parse_args()
    if len(args.paths) != (1 if args.check else 3):
        parser.error('Use --check SOURCE or DEVICE BUNDLE SOURCE')
    try:
        files = seed_files(args.paths[-1])
        if args.manifest:
            validate_manifest(args.manifest, files)
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        parser.error(str(error))
    if args.check:
        return

    simulator, bundle, source = args.paths
    if args.physical:
        seed_physical(simulator, bundle, files)
        return
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

    if args.manifest:
        try:
            verify_import(container, files)
        except (OSError, ValueError, sqlite3.Error) as error:
            raise SystemExit(f'Seed verification failed: {error}') from error
    subprocess.run(['xcrun', 'simctl', 'launch', simulator, bundle], check=True)


if __name__ == '__main__':
    main()
