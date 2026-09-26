from contextlib import closing
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location('ski_data', Path(__file__).with_name('ski_data.py'))
ski_data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ski_data)


def geometry(kind, points, z=False):
    header = b'GP\x00\x01' + struct.pack('<i', 4326)
    wkb = b'\x01' + struct.pack('<I', kind | (0x80000000 if z else 0))
    if kind == 2:
        wkb += struct.pack('<I', len(points))
    return header + wkb + b''.join(struct.pack('<' + 'd' * len(point), *point) for point in points)


class SkiDataTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / 'source.gpkg'
        self.output = self.root / 'packages'
        self.line = geometry(2, [(10, 45, 1000), (11, 46, 1200)], z=True)
        self.point = geometry(1, [(10, 45)])
        self.updated = '2026-09-23T23:39:37.490Z'
        with closing(sqlite3.connect(self.source)) as connection, connection:
            connection.executescript(ski_data.SCHEMA)
            connection.execute('INSERT INTO gpkg_spatial_ref_sys VALUES (?, ?, ?, ?, ?, ?)', ('WGS 84', 4326, 'EPSG', 4326, 'test', 'test'))
            for _, table, kind, attributes in ski_data.LAYERS:
                extra = ', uses TEXT' if table == 'runs_linestring' else ''
                connection.execute(f'CREATE TABLE {table} (id INTEGER PRIMARY KEY, geometry BLOB, ' + ', '.join(f'{name} TEXT' for name in attributes) + extra + ')')
                connection.execute('INSERT INTO gpkg_contents VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', (table, 'features', table, '', self.updated, -999, -999, 999, 999, 4326))
                values = {'feature_id': 'resort' if table == 'ski_areas_point' else table, 'ski_area_ids': 'resort', 'name': None, 'difficulty': 'intermediate', 'ref': '12', 'sources': '[{"type":"openstreetmap","id":"way/123"}]', 'wikidata_id': 'Q123', 'spot_type': 'lift_station'}
                row = [1, self.line if kind == 'LINESTRING' else self.point] + [values[name] for name in attributes]
                if table == 'runs_linestring':
                    row.append('nordic,downhill')
                connection.execute(f'INSERT INTO {table} VALUES (' + ', '.join('?' for _ in row) + ')', row)
            for feature_id, uses in [('nordic-only', 'nordic'), ('false-substring', 'downhillish')]:
                connection.execute('INSERT INTO runs_linestring SELECT id + ?, geometry, ?, ski_area_ids, name, difficulty, ref, sources, ? FROM runs_linestring WHERE id = 1', (1 if feature_id == 'nordic-only' else 2, feature_id, uses))

    def test_packages_keep_shared_downhill_geometry_and_identity_fields(self):
        source_before = self.source.read_bytes()
        result = ski_data.build(self.source, self.output, compress=True)
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(result['dataset_version'], hashlib.sha256(source_before).hexdigest())
        self.assertEqual([item['features'] for item in result['packages']], [1, 1, 1, 1])
        for name, table, _, attributes in ski_data.LAYERS:
            path = self.output / f'{name}.gpkg'
            with closing(ski_data.readonly(path)) as connection:
                self.assertEqual(tuple(row[1] for row in connection.execute(f'PRAGMA table_info({table})')), ('id', 'geometry', *attributes))
                self.assertEqual(connection.execute('PRAGMA integrity_check').fetchall(), [('ok',)])
                metadata = dict(connection.execute('SELECT key, value FROM sunoh_metadata'))
                self.assertEqual(metadata['source_updated_at'], self.updated)
                self.assertEqual(metadata['package_schema_version'], '1')
                self.assertEqual(metadata['dataset_version'], result['dataset_version'])
                self.assertEqual(connection.execute('SELECT min_x, min_y, max_x, max_y FROM gpkg_contents').fetchone(), (10, 45, 11, 46) if name in ('runs', 'lifts') else (10, 45, 10, 45))
                self.assertEqual(connection.execute('SELECT z FROM gpkg_geometry_columns').fetchone()[0], int(name in ('runs', 'lifts')))
                self.assertEqual(connection.execute(f'SELECT count(*) FROM rtree_{table}_geometry').fetchone()[0], 1)
                self.assertEqual(json.loads(connection.execute(f'SELECT sources FROM {table}').fetchone()[0])[0]['id'], 'way/123')
                if name == 'runs':
                    self.assertEqual(connection.execute(f'SELECT geometry, ref FROM {table}').fetchone(), (self.line, '12'))
            with zipfile.ZipFile(path.with_suffix('.zip')) as archive:
                self.assertEqual(archive.read(path.name), path.read_bytes())

    def test_unresolved_resort_preserves_source_and_leaves_no_partial_output(self):
        with closing(sqlite3.connect(self.source)) as connection, connection:
            connection.execute("UPDATE lifts_linestring SET ski_area_ids = 'unknown'")
        with self.assertRaisesRegex(ValueError, 'unresolved ski_area_ids'):
            ski_data.build(self.source, self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob('.ski-features-*')), [])

    def test_duplicate_ids_and_truncated_geometry_reject_incomplete_packages(self):
        with closing(sqlite3.connect(self.source)) as connection, connection:
            connection.execute("UPDATE runs_linestring SET uses = 'downhill', feature_id = 'same-id'")
        with self.assertRaises(sqlite3.IntegrityError):
            ski_data.build(self.source, self.output)
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, 'coordinate count'):
            ski_data.geometry_info(self.line[:-1], 'LINESTRING')

    def test_existing_output_is_preserved_and_build_is_reproducible(self):
        ski_data.build(self.source, self.output, compress=True)
        other = self.root / 'second-build'
        ski_data.build(self.source, other, compress=True)
        for path in self.output.iterdir():
            self.assertEqual(path.read_bytes(), (other / path.name).read_bytes())
        with self.assertRaisesRegex(ValueError, 'already exists'):
            ski_data.build(self.source, self.output)
        self.assertEqual(len(list(self.output.iterdir())), 8)


if __name__ == '__main__':
    unittest.main()
