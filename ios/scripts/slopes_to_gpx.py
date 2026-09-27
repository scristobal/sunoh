"""Prepare the 2025/2026 Slopes season as disposable GPX seed data."""

import argparse
import csv
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
import hashlib
import io
import json
import math
from pathlib import Path
import tempfile
import uuid
import xml.etree.ElementTree as ET
import zipfile


SEASON_START = date(2025, 7, 1)
SEASON_END = date(2026, 7, 1)
DEFAULT_SOURCE = Path('/Volumes/Downloads/sunoh/exports/slopes-21-09-2026')
DEFAULT_OUTPUT = Path(__file__).resolve().parents[1] / '.local/seed/slopes-2025-2026'
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def convert(source):
    data = source.read_bytes()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        metadata = ET.fromstring(archive.read('Metadata.xml'))
        start = datetime.strptime(metadata.attrib['recordStart'], '%Y-%m-%d %H:%M:%S %z')
        if not SEASON_START <= start.date() < SEASON_END:
            return None
        identifier = str(uuid.UUID(metadata.attrib['identifier']))
        name = metadata.attrib.get('locationName', source.stem)
        root = ET.Element('gpx', version='1.1', creator='Sunō',
                          xmlns='http://www.topografix.com/GPX/1/1')
        track = ET.SubElement(root, 'trk')
        ET.SubElement(track, 'name').text = f'{start.date()} — {name}'
        segment = ET.SubElement(track, 'trkseg')
        previous = None
        previous_values = None
        previous_ms = None
        duplicates = count = raw_count = 0
        first_time = last_time = None
        rows = csv.reader(io.StringIO(archive.read('RawGPS.csv').decode('utf-8-sig')))
        for line, row in enumerate(rows, 1):
            if not row:
                continue
            raw_count += 1
            if len(row) < 4:
                raise ValueError(f'{source.name}:{line}: expected time, latitude, longitude, elevation')
            timestamp, latitude, longitude, elevation = row[:4]
            values = [Decimal(value) for value in row[:4]]
            if not all(value.is_finite() and math.isfinite(float(value)) for value in values):
                raise ValueError(f'{source.name}:{line}: nonfinite observation')
            if not -90 <= values[1] <= 90 or not -180 <= values[2] <= 180:
                raise ValueError(f'{source.name}:{line}: invalid coordinates')
            microseconds = values[0] * 1_000_000
            if microseconds != microseconds.to_integral_value() or microseconds < 0:
                raise ValueError(f'{source.name}:{line}: unsupported timestamp precision or range')
            milliseconds = int(values[0] * 1000)
            if microseconds == previous and values == previous_values:
                duplicates += 1
                continue
            if previous is not None and (microseconds <= previous or milliseconds <= previous_ms):
                raise ValueError(f'{source.name}:{line}: distinct timestamps must increase at app millisecond precision')
            previous, previous_values, previous_ms = microseconds, values, milliseconds
            timestamp_text = (EPOCH + timedelta(microseconds=int(microseconds))).isoformat(timespec='microseconds').replace('+00:00', 'Z')
            point = ET.SubElement(segment, 'trkpt', lat=latitude, lon=longitude)
            ET.SubElement(point, 'ele').text = elevation
            ET.SubElement(point, 'time').text = timestamp_text
            first_time = first_time or timestamp_text
            last_time = timestamp_text
            count += 1
        if not count:
            raise ValueError(f'{source.name}: RawGPS.csv is empty')
        gpx = ET.tostring(root, encoding='utf-8', xml_declaration=True)
        entry = dict(activity_id=identifier, name=name, recording_start=start.isoformat(),
                     archive=source.name, archive_sha256=sha256(data),
                     gpx=f'{start.date()}-{identifier}.gpx', gpx_sha256=sha256(gpx),
                     raw_points=raw_count, points=count, identical_repeats=duplicates,
                     first_point=first_time, last_point=last_time)
        return entry, gpx


def prepare(source=DEFAULT_SOURCE, output=DEFAULT_OUTPUT):
    source, output = Path(source).expanduser().resolve(), Path(output).expanduser().resolve()
    if not source.is_dir():
        raise ValueError(f'Slopes export directory is unavailable: {source}')
    if source == output or source in output.parents or output in source.parents:
        raise ValueError('The generated seed directory must be separate from the original exports')
    archives = sorted(p for p in source.iterdir() if not p.name.startswith('.') and p.suffix.lower() in ('.slopes', '.slope'))
    if not archives:
        raise ValueError(f'No Slopes archives found in {source}')
    converted = []
    for archive in archives:
        try:
            result = convert(archive)
        except (OSError, ValueError, ArithmeticError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
            raise ValueError(f'Cannot prepare {archive.name}: {error}') from error
        if result is not None:
            converted.append(result)
    if not converted:
        raise ValueError('No Slopes activities found for the 2025/2026 season')
    converted.sort(key=lambda item: (item[0]['recording_start'], item[0]['activity_id']))
    identifiers = [entry['activity_id'] for entry, _ in converted]
    if len(identifiers) != len(set(identifiers)):
        raise ValueError('Selected Slopes archives contain repeated activity identifiers')
    manifest = dict(source=str(source), season_start=str(SEASON_START), season_end_exclusive=str(SEASON_END),
                    activities=[entry for entry, _ in converted])
    # Rebuild from the originals every time. A stale or edited cache is never a fallback.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.slopes-seed-', dir=output.parent) as temporary:
        staged = Path(temporary) / 'prepared'
        (staged / 'gpx').mkdir(parents=True)
        for entry, data in converted:
            (staged / 'gpx' / entry['gpx']).write_bytes(data)
        (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
        previous = Path(temporary) / 'previous'
        if output.exists():
            output.rename(previous)
        try:
            staged.rename(output)
        except OSError:
            if previous.exists():
                previous.rename(output)
            raise
    total = sum(entry['points'] for entry, _ in converted)
    repeats = sum(entry['identical_repeats'] for entry, _ in converted)
    print(f'Source: {source}\nSeason: {SEASON_START} through {SEASON_END} (exclusive)')
    print(f'Prepared {len(converted)} activities, {total} points, {repeats} identical repeats omitted')
    print(f'Recordings: {converted[0][0]["recording_start"]} through {converted[-1][0]["recording_start"]}')
    print(f'GPX: {output / "gpx"}')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE, help='Original Slopes export directory')
    parser.add_argument('--output', type=Path, default=DEFAULT_OUTPUT, help='Disposable generated seed directory')
    args = parser.parse_args()
    try:
        prepare(args.source, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
