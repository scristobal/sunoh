"""Convert Slopes RawGPS.csv observations to GPX for simulator seeding."""

import argparse
import csv
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import io
import math
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile


def convert(source, year):
    with zipfile.ZipFile(source) as archive:
        metadata = ET.fromstring(archive.read('Metadata.xml'))
        start = datetime.strptime(metadata.attrib['start'], '%Y-%m-%d %H:%M:%S %z')
        if year is not None and start.year != year:
            return None
        rows = csv.reader(io.StringIO(archive.read('RawGPS.csv').decode('utf-8-sig')))
        root = ET.Element('gpx', version='1.1', creator='Sunoh',
                          xmlns='http://www.topografix.com/GPX/1/1')
        track = ET.SubElement(root, 'trk')
        ET.SubElement(track, 'name').text = source.stem
        segment = ET.SubElement(track, 'trkseg')
        previous = None
        previous_values = None
        duplicates = 0
        count = 0
        for line, row in enumerate(rows, 1):
            if not row:
                continue
            if len(row) < 4:
                raise ValueError(f'{source.name}:{line}: expected time, latitude, longitude, elevation')
            timestamp, latitude, longitude, elevation = row[:4]
            values = [float(value) for value in row[:4]]
            if not all(math.isfinite(value) for value in values):
                raise ValueError(f'{source.name}:{line}: nonfinite observation')
            if not -90 <= values[1] <= 90 or not -180 <= values[2] <= 180:
                raise ValueError(f'{source.name}:{line}: invalid coordinates')
            microseconds = int(Decimal(timestamp) * 1_000_000)
            if microseconds == previous and values == previous_values:
                duplicates += 1
                continue
            if previous is not None and microseconds <= previous:
                raise ValueError(f'{source.name}:{line}: timestamps must increase')
            if previous is not None and round(values[0] * 1000) <= round(previous / 1000):
                raise ValueError(f'{source.name}:{line}: timestamps collide at app millisecond precision')
            previous = microseconds
            previous_values = values
            date = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(microseconds=microseconds)
            point = ET.SubElement(segment, 'trkpt', lat=latitude, lon=longitude)
            ET.SubElement(point, 'ele').text = elevation
            ET.SubElement(point, 'time').text = date.isoformat(timespec='microseconds').replace('+00:00', 'Z')
            count += 1
        if not count:
            raise ValueError(f'{source.name}: RawGPS.csv is empty')
        if duplicates:
            print(f'{source.name}: omitted {duplicates} identical time/coordinate/elevation repeats')
        return ET.ElementTree(root), count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Slopes archive or directory of archives')
    parser.add_argument('output', type=Path, help='Directory for GPX files; existing files are not overwritten')
    parser.add_argument('--year', type=int, help='Select the activity start year from Metadata.xml')
    args = parser.parse_args()
    sources = sorted(args.source.iterdir()) if args.source.is_dir() else [args.source]
    sources = [path for path in sources if not path.name.startswith('.') and path.suffix.lower() in ('.slopes', '.slope')]
    converted = []
    for source in sources:
        result = convert(source, args.year)
        if result is not None:
            converted.append((source, *result))
    if not converted:
        parser.error('No matching activities found')
    args.output.mkdir(parents=True, exist_ok=True)
    for source, _, _ in converted:
        if (args.output / source.with_suffix('.gpx').name).exists():
            parser.error(f'Output already exists for {source.name}')
    for source, tree, count in converted:
        destination = args.output / source.with_suffix('.gpx').name
        with destination.open('xb') as output:
            tree.write(output, encoding='utf-8', xml_declaration=True)
        print(f'{destination.name}: {count} points')
    print(f'Converted {len(converted)} activities, {sum(item[2] for item in converted)} raw points')


if __name__ == '__main__':
    main()
