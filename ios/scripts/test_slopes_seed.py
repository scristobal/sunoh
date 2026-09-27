"""Checks for season selection, raw observation preservation and seed verification."""

from contextlib import redirect_stdout
import io
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid
import xml.etree.ElementTree as ET
import zipfile

from slopes_to_gpx import prepare
from seed import seed_files, validate_manifest, verify_import


class SlopesSeedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'exports'
        self.source.mkdir()
        self.output = self.root / 'generated'

    def archive(self, name='activity.slopes', start='2026-01-02 08:00:00 +0100', raw=None, identifier=None):
        if raw is None:
            raw = '1767337200,47.1,11.2,2000.5\n1767337201,47.2,11.3,1999.25\n'
        metadata = ET.Element('Activity', recordStart=start, start='2020-01-01 00:00:00 +0000',
                              identifier=identifier or str(uuid.uuid4()), locationName='Sölden & nearby')
        with zipfile.ZipFile(self.source / name, 'w') as archive:
            archive.writestr('Metadata.xml', ET.tostring(metadata))
            if raw is not False:
                archive.writestr('RawGPS.csv', raw)
            archive.writestr('GPS.csv', '0,0,0,0\n')

    def prepare(self):
        with redirect_stdout(io.StringIO()):
            return prepare(self.source, self.output)

    def test_season_uses_recording_local_date_and_keeps_distinct_same_day_activities(self):
        self.archive('last-season.slopes', '2025-06-30 23:00:00 -0400')
        self.archive('first.slopes', '2025-07-01 00:01:00 +0200')
        self.archive('same-day.slopes', '2025-07-01 00:01:00 +0200')
        self.archive('last.slopes', '2026-06-30 23:59:00 -0400')
        self.archive('next-season.slopes', '2026-07-01 00:00:00 +0200')
        (self.source / '._ignored.slopes').write_bytes(b'not an archive')
        entries = self.prepare()['activities']
        self.assertEqual({entry['archive'] for entry in entries}, {'first.slopes', 'same-day.slopes', 'last.slopes'})
        self.assertEqual(len({entry['gpx'] for entry in entries}), 3)

    def test_conversion_preserves_raw_values_name_and_gaps_and_reports_identical_repeats(self):
        self.archive(raw='1767337200.125678,47.123456,11.234567,2000.125\n'
                         '1767337200.125678,47.123456,11.234567,2000.125\n'
                         '1767347200.875,47.123457,11.234568,1999.75\n')
        entry = self.prepare()['activities'][0]
        self.assertEqual((entry['raw_points'], entry['points'], entry['identical_repeats']), (3, 2, 1))
        root = ET.parse(self.output / 'gpx' / entry['gpx']).getroot()
        ns = {'g': 'http://www.topografix.com/GPX/1/1'}
        self.assertEqual(root.findtext('g:trk/g:name', namespaces=ns), '2026-01-02 — Sölden & nearby')
        self.assertEqual(len(root.findall('.//g:trkseg', ns)), 1)
        points = root.findall('.//g:trkpt', ns)
        self.assertEqual(points[0].attrib, {'lat': '47.123456', 'lon': '11.234567'})
        self.assertEqual(points[0].findtext('g:ele', namespaces=ns), '2000.125')
        self.assertEqual(points[0].findtext('g:time', namespaces=ns), '2026-01-02T07:00:00.125678Z')
        self.assertEqual(points[1].findtext('g:time', namespaces=ns), '2026-01-02T09:46:40.875000Z')

    def test_bad_source_never_replaces_previous_output_or_uses_cache(self):
        self.archive()
        self.prepare()
        old_manifest = (self.output / 'manifest.json').read_bytes()
        for bad in [False, '1767337200,47,11,2000\n1767337200,48,11,2000\n',
                    '1767337200.0001,47,11,2000\n1767337200.0002,47,11,2000\n',
                    '1767337200.0004,47,11,2000\n1767337200.0006,47,11,2000\n',
                    '1767337200,NaN,11,2000\n']:
            self.archive(raw=bad)
            with self.assertRaises(ValueError):
                self.prepare()
            self.assertEqual((self.output / 'manifest.json').read_bytes(), old_manifest)
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            prepare(self.root / 'missing', self.output)

    def test_regeneration_replaces_modified_cache_and_validation_detects_changes(self):
        self.archive()
        manifest = self.prepare()
        file = self.output / 'gpx' / manifest['activities'][0]['gpx']
        original = file.read_bytes()
        file.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'changed'):
            validate_manifest(self.output / 'manifest.json', seed_files(file.parent))
        (file.parent / 'unrelated.gpx').write_bytes(b'unrelated')
        self.prepare()
        self.assertEqual(file.read_bytes(), original)
        self.assertFalse((file.parent / 'unrelated.gpx').exists())
        with redirect_stdout(io.StringIO()):
            validate_manifest(self.output / 'manifest.json', seed_files(file.parent))
        self.archive(raw='1767337200,47,11,999\n')
        with self.assertRaisesRegex(ValueError, 'changed'):
            validate_manifest(self.output / 'manifest.json', seed_files(file.parent))

    def test_duplicate_activity_ids_fail(self):
        identifier = str(uuid.uuid4())
        self.archive('one.slopes', identifier=identifier)
        self.archive('two.slopes', identifier=identifier)
        with self.assertRaisesRegex(ValueError, 'repeated activity identifiers'):
            self.prepare()

    def test_verification_detects_corrupted_saved_observations(self):
        self.archive(raw='1767337200.0009,47.1,11.2,2000.5\n1767337201.0009,47.2,11.3,1999.25\n')
        self.prepare()
        database = self.root / 'Library/Application Support/Activities/Activities.store'
        database.parent.mkdir(parents=True)
        with sqlite3.connect(database) as connection:
            connection.execute('CREATE TABLE ZSTOREDACTIVITY (ZID TEXT)')
            connection.execute('CREATE TABLE ZSTOREDTRACKPOINT (ZACTIVITYID TEXT, ZRECORDEDATMILLISECONDS INTEGER, ZLATITUDE REAL, ZLONGITUDE REAL, ZELEVATIONMETERS REAL)')
            connection.execute("INSERT INTO ZSTOREDACTIVITY VALUES ('a')")
            connection.executemany('INSERT INTO ZSTOREDTRACKPOINT VALUES (?, ?, ?, ?, ?)',
                                   [('a', 1767337200000, 47.1, 11.2, 2000.5), ('a', 1767337201000, 47.2, 11.3, 1999.25)])
        with redirect_stdout(io.StringIO()):
            verify_import(self.root, seed_files(self.output / 'gpx'))
        with sqlite3.connect(database) as connection:
            connection.execute('UPDATE ZSTOREDTRACKPOINT SET ZELEVATIONMETERS = NULL')
        with self.assertRaisesRegex(ValueError, 'do not match'):
            verify_import(self.root, seed_files(self.output / 'gpx'))


if __name__ == '__main__':
    unittest.main()
