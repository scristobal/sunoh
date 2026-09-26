"""Build Sunō's offline ski-feature GeoPackages from an OpenSkiData GeoPackage."""

import argparse
from contextlib import closing
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile
import zipfile


LAYERS = (
    ('runs', 'runs_linestring', 'LINESTRING', ('feature_id', 'ski_area_ids', 'name', 'difficulty', 'ref', 'sources')),
    ('lifts', 'lifts_linestring', 'LINESTRING', ('feature_id', 'ski_area_ids', 'name', 'ref', 'sources')),
    ('ski_areas', 'ski_areas_point', 'POINT', ('feature_id', 'name', 'sources', 'wikidata_id')),
    ('spots', 'spots_point', 'POINT', ('feature_id', 'ski_area_ids', 'spot_type', 'sources')),
)
DOWNHILL_FILTER = "WHERE instr(',' || coalesce(uses, '') || ',', ',downhill,') > 0"
SCHEMA = """
CREATE TABLE gpkg_spatial_ref_sys (
    srs_name TEXT NOT NULL, srs_id INTEGER PRIMARY KEY, organization TEXT NOT NULL,
    organization_coordsys_id INTEGER NOT NULL, definition TEXT NOT NULL, description TEXT);
CREATE TABLE gpkg_contents (
    table_name TEXT PRIMARY KEY, data_type TEXT NOT NULL, identifier TEXT UNIQUE,
    description TEXT DEFAULT '', last_change DATETIME NOT NULL,
    min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE, srs_id INTEGER,
    FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id));
CREATE TABLE gpkg_geometry_columns (
    table_name TEXT PRIMARY KEY, column_name TEXT NOT NULL, geometry_type_name TEXT NOT NULL,
    srs_id INTEGER NOT NULL, z TINYINT NOT NULL, m TINYINT NOT NULL,
    FOREIGN KEY (table_name) REFERENCES gpkg_contents(table_name),
    FOREIGN KEY (srs_id) REFERENCES gpkg_spatial_ref_sys(srs_id));
CREATE TABLE gpkg_extensions (
    table_name TEXT, column_name TEXT, extension_name TEXT NOT NULL,
    definition TEXT NOT NULL, scope TEXT NOT NULL,
    UNIQUE (table_name, column_name, extension_name));
CREATE TABLE sunoh_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def readonly(path):
    return sqlite3.connect(path.resolve().as_uri() + '?mode=ro&immutable=1', uri=True)


def source_digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def geometry_info(blob, expected_type):
    """Read point/line bounds and dimensions without changing the source geometry."""
    if not blob or len(blob) < 13 or blob[:3] != b'GP\x00':
        raise ValueError('Invalid GeoPackage geometry header')
    flags = blob[3]
    envelope_sizes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
    envelope = (flags >> 1) & 7
    if envelope not in envelope_sizes or flags & 0x30:
        raise ValueError('Empty or extended GeoPackage geometries are unsupported')
    header_order = '<' if flags & 1 else '>'
    if struct.unpack_from(header_order + 'i', blob, 4)[0] != 4326:
        raise ValueError('Expected WGS 84 geometry')
    offset = 8 + envelope_sizes[envelope]
    if len(blob) < offset + 5 or blob[offset] not in (0, 1):
        raise ValueError('Invalid WKB header')
    order = '<' if blob[offset] else '>'
    type_code = struct.unpack_from(order + 'I', blob, offset + 1)[0]
    offset += 5
    iso_type = type_code & 0x0FFFFFFF
    dimensions, base_type = divmod(iso_type, 1000)
    has_z = bool(type_code & 0x80000000) or dimensions in (1, 3)
    has_m = bool(type_code & 0x40000000) or dimensions in (2, 3)
    if dimensions > 3 or base_type != {'POINT': 1, 'LINESTRING': 2}[expected_type]:
        raise ValueError(f'Expected {expected_type} geometry')
    if type_code & 0x20000000:
        offset += 4
    count = 1
    if base_type == 2:
        if len(blob) < offset + 4:
            raise ValueError('Truncated line geometry')
        count = struct.unpack_from(order + 'I', blob, offset)[0]
        offset += 4
        if count < 2:
            raise ValueError('Line geometry requires at least two points')
    stride = 2 + has_z + has_m
    if len(blob) != offset + count * stride * 8:
        raise ValueError('Geometry coordinate count does not match its bytes')
    min_x = min_y = math.inf
    max_x = max_y = -math.inf
    for point in struct.iter_unpack(order + 'd' * stride, memoryview(blob)[offset:]):
        x, y = point[:2]
        if not math.isfinite(x) or not math.isfinite(y) or not -180 <= x <= 180 or not -90 <= y <= 90:
            raise ValueError('Invalid WGS 84 coordinates')
        min_x, max_x = min(min_x, x), max(max_x, x)
        min_y, max_y = min(min_y, y), max(max_y, y)
    return (min_x, max_x, min_y, max_y), has_z, has_m


def spatial_triggers(connection, table, index):
    bounds = 'NEW.id, ST_MinX(NEW.geometry), ST_MaxX(NEW.geometry), ST_MinY(NEW.geometry), ST_MaxY(NEW.geometry)'
    connection.executescript(f"""
    CREATE TRIGGER {index}_insert AFTER INSERT ON {table}
    WHEN NEW.geometry IS NOT NULL AND NOT ST_IsEmpty(NEW.geometry)
    BEGIN INSERT OR REPLACE INTO {index} VALUES ({bounds}); END;
    CREATE TRIGGER {index}_update1 AFTER UPDATE OF geometry ON {table}
    WHEN OLD.id = NEW.id AND NEW.geometry IS NOT NULL AND NOT ST_IsEmpty(NEW.geometry)
    BEGIN INSERT OR REPLACE INTO {index} VALUES ({bounds}); END;
    CREATE TRIGGER {index}_update2 AFTER UPDATE OF geometry ON {table}
    WHEN OLD.id = NEW.id AND (NEW.geometry IS NULL OR ST_IsEmpty(NEW.geometry))
    BEGIN DELETE FROM {index} WHERE id = OLD.id; END;
    CREATE TRIGGER {index}_update3 AFTER UPDATE ON {table}
    WHEN OLD.id != NEW.id AND NEW.geometry IS NOT NULL AND NOT ST_IsEmpty(NEW.geometry)
    BEGIN DELETE FROM {index} WHERE id = OLD.id;
    INSERT OR REPLACE INTO {index} VALUES ({bounds}); END;
    CREATE TRIGGER {index}_update4 AFTER UPDATE ON {table}
    WHEN OLD.id != NEW.id AND (NEW.geometry IS NULL OR ST_IsEmpty(NEW.geometry))
    BEGIN DELETE FROM {index} WHERE id IN (OLD.id, NEW.id); END;
    CREATE TRIGGER {index}_delete AFTER DELETE ON {table}
    BEGIN DELETE FROM {index} WHERE id = OLD.id; END;
    """)


def build_package(source, destination, layer, metadata, resort_ids):
    _, table, geometry_type, attributes = layer
    columns = ('id', 'geometry', *attributes)
    available = {row[1] for row in source.execute(f'PRAGMA table_info({table})')}
    missing = set(columns) - available
    if table == 'runs_linestring' and 'uses' not in available:
        missing.add('uses')
    if missing:
        raise ValueError(f'{table}: missing source columns {sorted(missing)}')
    contents = source.execute('SELECT last_change, srs_id FROM gpkg_contents WHERE table_name = ?', (table,)).fetchone()
    if not contents:
        raise ValueError(f'{table}: missing GeoPackage layer metadata')
    last_change, srs_id = contents
    if srs_id != 4326:
        raise ValueError(f'{table}: expected EPSG:4326')
    clause = DOWNHILL_FILTER if table == 'runs_linestring' else ''
    expected_count = source.execute(f'SELECT count(*) FROM {table} {clause}').fetchone()[0]
    if not expected_count:
        raise ValueError(f'{table}: no selected features')
    index = f'rtree_{table}_geometry'
    bounds = [math.inf, -math.inf, math.inf, -math.inf]
    z_values, m_values = set(), set()
    association_count = missing_associations = 0
    connection = sqlite3.connect(destination)
    try:
        connection.execute('PRAGMA application_id = 1196444487')
        connection.execute('PRAGMA user_version = 10300')
        connection.executescript(SCHEMA)
        connection.executemany('INSERT INTO sunoh_metadata VALUES (?, ?)', metadata.items())
        connection.executemany('INSERT INTO gpkg_spatial_ref_sys VALUES (?, ?, ?, ?, ?, ?)', source.execute('SELECT srs_name, srs_id, organization, organization_coordsys_id, definition, description FROM gpkg_spatial_ref_sys ORDER BY srs_id'))
        connection.execute(f'CREATE TABLE {table} (id INTEGER PRIMARY KEY, geometry {geometry_type} NOT NULL, ' + ', '.join(f'{name} TEXT' for name in attributes) + ')')
        connection.execute(f'CREATE UNIQUE INDEX {table}_feature_id ON {table}(feature_id)')
        connection.execute(f'CREATE VIRTUAL TABLE {index} USING rtree(id, minx, maxx, miny, maxy)')
        placeholders = ', '.join('?' for _ in columns)
        for row in source.execute(f'SELECT {", ".join(columns)} FROM {table} {clause} ORDER BY id'):
            record = dict(zip(columns, row))
            if not record['feature_id'] or not record['feature_id'].strip():
                raise ValueError(f'{table}: empty feature_id')
            if not isinstance(record['sources'], str) or not isinstance(json.loads(record['sources']), list):
                raise ValueError(f'{table}: sources must be a JSON array')
            links = record.get('ski_area_ids') or ''
            if 'ski_area_ids' in attributes:
                ids = links.split(',') if links else []
                if any(value not in resort_ids for value in ids):
                    raise ValueError(f'{table}: unresolved ski_area_ids for {record["feature_id"]}')
                association_count += len(ids)
                missing_associations += not ids
            feature_bounds, has_z, has_m = geometry_info(record['geometry'], geometry_type)
            z_values.add(has_z)
            m_values.add(has_m)
            for i, value in enumerate(feature_bounds):
                bounds[i] = min(bounds[i], value) if i % 2 == 0 else max(bounds[i], value)
            connection.execute(f'INSERT INTO {table} VALUES ({placeholders})', row)
            connection.execute(f'INSERT INTO {index} VALUES (?, ?, ?, ?, ?)', (record['id'], *feature_bounds))
        connection.execute('INSERT INTO gpkg_contents VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', (table, 'features', table, '', last_change, bounds[0], bounds[2], bounds[1], bounds[3], 4326))
        dimensions = lambda values: 2 if len(values) > 1 else int(True in values)
        connection.execute('INSERT INTO gpkg_geometry_columns VALUES (?, ?, ?, ?, ?, ?)', (table, 'geometry', geometry_type, 4326, dimensions(z_values), dimensions(m_values)))
        connection.execute('INSERT INTO gpkg_extensions VALUES (?, ?, ?, ?, ?)', (table, 'geometry', 'gpkg_rtree_index', 'http://www.geopackage.org/spec/#extension_rtree', 'write-only'))
        spatial_triggers(connection, table, index)
        connection.commit()
        connection.execute('VACUUM')
        if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
            raise ValueError(f'{table}: SQLite integrity check failed')
        if connection.execute('PRAGMA foreign_key_check').fetchall():
            raise ValueError(f'{table}: GeoPackage metadata references failed')
        for name in (table, index):
            if connection.execute(f'SELECT count(*) FROM {name}').fetchone()[0] != expected_count:
                raise ValueError(f'{table}: feature or spatial-index count changed')
        actual_columns = tuple(row[1] for row in connection.execute(f'PRAGMA table_info({table})'))
        if actual_columns != columns:
            raise ValueError(f'{table}: unexpected output schema')
    finally:
        connection.close()
    return {'file': destination.name, 'features': expected_count, 'bytes': destination.stat().st_size, 'resort_references': association_count, 'missing_resort_associations': missing_associations}


def compress_package(destination):
    archive_path = destination.with_suffix('.zip')
    with tempfile.NamedTemporaryFile(prefix='.ski-zip-', dir=destination.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        entry = zipfile.ZipInfo(destination.name, date_time=(1980, 1, 1, 0, 0, 0))
        entry.external_attr = 0o644 << 16
        with zipfile.ZipFile(temporary_path, 'w') as archive:
            archive.writestr(entry, destination.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        os.replace(temporary_path, archive_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    return archive_path.stat().st_size


def build(source_path, output_path, compress=False):
    source_path, output_path = source_path.resolve(), output_path.resolve()
    repository = Path(__file__).resolve().parents[2]
    if output_path.is_relative_to(repository):
        raise ValueError('Store large ski-feature packages outside the source repository')
    if output_path.exists():
        raise ValueError(f'Output already exists: {output_path}')
    initial_stat = source_path.stat()
    metadata = {'dataset_version': source_digest(source_path), 'package_schema_version': '1'}
    output_path.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.ski-features-', dir=output_path.parent))
    try:
        with closing(readonly(source_path)) as source:
            metadata['source_updated_at'] = source.execute('SELECT max(last_change) FROM gpkg_contents').fetchone()[0]
            if not metadata['source_updated_at']:
                raise ValueError('Source has no dataset timestamp')
            resort_ids = {row[0] for row in source.execute('SELECT feature_id FROM ski_areas_point')}
            results = []
            for layer in LAYERS:
                destination = staging / f'{layer[0]}.gpkg'
                result = build_package(source, destination, layer, metadata, resort_ids)
                if compress:
                    result['zip_bytes'] = compress_package(destination)
                results.append(result)
        final_stat = source_path.stat()
        if (initial_stat.st_size, initial_stat.st_mtime_ns) != (final_stat.st_size, final_stat.st_mtime_ns):
            raise ValueError('Source changed while packages were built')
        if output_path.exists():
            raise ValueError(f'Output appeared during build: {output_path}')
        os.rename(staging, output_path)
        return {'output': str(output_path), **metadata, 'packages': results}
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Original OpenSkiData GeoPackage; opened read-only')
    parser.add_argument('output', type=Path, help='New directory outside the repository; existing data is never overwritten')
    parser.add_argument('--zip', action='store_true', help='Also create a ZIP archive for each package with Deflate level 9')
    args = parser.parse_args()
    try:
        result = build(args.source, args.output, args.zip)
    except (OSError, sqlite3.Error, ValueError, struct.error) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
