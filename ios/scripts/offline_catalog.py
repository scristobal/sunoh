"""Prepare the Alps offline-region catalog from a published OpenSkiData GeoPackage.

Requires Shapely 2 for geometry preparation. The output contains coverage metadata, not map tiles. Mapbox resources are downloaded by the app after user confirmation.
"""

import argparse
from collections import defaultdict
import json
import math
import os
from pathlib import Path
import sqlite3
import struct
import tempfile

from shapely import from_wkb
from shapely.geometry import MultiPoint, Polygon, box, mapping
from shapely.ops import transform, unary_union

EARTH_RADIUS = 6_371_000
PADDING_METERS = 200
PACK_INDEX_ZOOMS = (0, 6, 10, 11, 12)
# This rollout envelope excludes the Pyrenees and covers the Alpine ski regions.
ALPS = Polygon([(5.0, 44.0), (7.4, 43.65), (9.3, 45.1), (13.9, 45.45),
                (16.6, 46.0), (16.6, 47.85), (14.3, 48.25), (10.0, 47.8),
                (6.6, 46.75), (5.0, 45.7)])


def geometry(blob):
    if blob is None or blob[:2] != b'GP' or blob[2] != 0 or blob[3] & 0x30:
        raise ValueError('Invalid or empty GeoPackage geometry')
    order = '<' if blob[3] & 1 else '>'
    if struct.unpack_from(order + 'i', blob, 4)[0] != 4326:
        raise ValueError('Offline catalog requires EPSG:4326')
    envelope = (blob[3] >> 1) & 7
    if envelope > 4:
        raise ValueError('Invalid GeoPackage envelope')
    offset = 8 + [0, 32, 48, 48, 64][envelope]
    result = from_wkb(blob[offset:])
    if result.is_empty or not result.is_valid:
        raise ValueError('Invalid source geometry')
    return result


def local_projection(center):
    """Spherical azimuthal equidistant projection, measured in meters."""
    lon0, lat0 = map(math.radians, center)

    def project(lon, lat, z=None):
        lon, lat = math.radians(lon), math.radians(lat)
        delta = lon - lon0
        cosine = max(-1, min(1, math.sin(lat0) * math.sin(lat) + math.cos(lat0) * math.cos(lat) * math.cos(delta)))
        distance = math.acos(cosine)
        scale = distance / math.sin(distance) if distance > 1e-12 else 1
        return (EARTH_RADIUS * scale * math.cos(lat) * math.sin(delta),
                EARTH_RADIUS * scale * (math.cos(lat0) * math.sin(lat) - math.sin(lat0) * math.cos(lat) * math.cos(delta)))

    def unproject(x, y, z=None):
        radius = math.hypot(x, y)
        if radius < 1e-9:
            return center
        distance = radius / EARTH_RADIUS
        lat = math.asin(math.cos(distance) * math.sin(lat0) + y * math.sin(distance) * math.cos(lat0) / radius)
        lon = lon0 + math.atan2(x * math.sin(distance), radius * math.cos(lat0) * math.cos(distance) - y * math.sin(lat0) * math.sin(distance))
        return math.degrees(lon), math.degrees(lat)

    return project, unproject


def approximate_area_square_meters(shape, center):
    """Measure the resort footprint before padding and grid selection."""
    project, _ = local_projection(center)
    area = transform(project, shape).area
    if not math.isfinite(area) or area < 0:
        raise ValueError('Invalid resort area')
    return area


def padded_coverage(shape, center):
    project, unproject = local_projection(center)
    local = transform(project, shape)
    if max(local.bounds[2] - local.bounds[0], local.bounds[3] - local.bounds[1]) > 120_000:
        return None  # Exclude country-wide collections rather than guess connectivity.
    padded = local.simplify(10, preserve_topology=True).buffer(PADDING_METERS, quad_segs=12)
    result = transform(unproject, padded)
    if not result.is_valid or result.geom_type not in ('Polygon', 'MultiPolygon'):
        raise ValueError('Invalid padded coverage')
    return result


def grid_projection(zoom=12):
    count = 2 ** zoom

    def project(lon, lat, z=None):
        return ((lon + 180) / 360 * count,
                (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * count)

    def unproject(x, y, z=None):
        return (x / count * 360 - 180,
                math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / count)))))

    return project, unproject


def tile_coverage(coverage, zoom):
    """Find pack-index footprints without changing the requested resort geometry."""
    project, _ = grid_projection(zoom)
    projected = transform(project, coverage)
    west, north, east, south = projected.bounds
    tiles = [f'{zoom}/{x}/{y}' for x in range(max(0, math.floor(west)), min(2 ** zoom, math.ceil(east)))
             for y in range(max(0, math.floor(north)), min(2 ** zoom, math.ceil(south)))
             if projected.intersection(box(x, y, x + 1, y + 1)).area > 1e-12]
    if not tiles:
        raise ValueError('Coverage does not intersect any tiles')
    return tiles


def stable_id(sources):
    osm = sorted(str(source['id']) for source in sources if source.get('type') == 'openstreetmap' and source.get('id'))
    if osm:
        return 'osm-' + osm[0].replace('/', '-')
    ski = sorted(str(source['id']) for source in sources if source.get('type') == 'skimap.org' and source.get('id'))
    return 'skimap-' + ski[0] if ski else None


def build(source_path, output_path):
    source_path, output_path = source_path.resolve(), output_path.resolve()
    repository = Path(__file__).resolve().parents[2]
    local = Path(__file__).resolve().parents[1] / '.local'
    if output_path.is_relative_to(repository) and not output_path.is_relative_to(local):
        raise ValueError('Store generated coverage under ios/.local or outside the repository')
    if output_path.exists():
        raise ValueError(f'Output already exists: {output_path}')
    initial_stat = source_path.stat()
    source = sqlite3.connect(source_path.as_uri() + '?mode=ro', uri=True)
    source.row_factory = sqlite3.Row
    try:
        candidates = {}
        for row in source.execute('SELECT * FROM ski_areas_point'):
            center = geometry(row['geometry'])
            if not row['name'] or row['status'] != 'operating' or not ALPS.covers(center):
                continue
            if 'downhill' not in (row['activities'] or '').split(','):
                continue
            identifier = stable_id(json.loads(row['sources'] or '[]'))
            if identifier:
                candidates[row['feature_id']] = (row, center, identifier)
        points = defaultdict(list)
        lift_counts = defaultdict(int)
        for table in ('runs_linestring', 'lifts_linestring'):
            condition = "status = 'operating'"
            if table == 'runs_linestring':
                condition += " AND (',' || uses || ',') LIKE '%,downhill,%'"
            for row in source.execute(f'SELECT geometry, ski_area_ids FROM {table} WHERE {condition}'):
                identifiers = [key for key in (row['ski_area_ids'] or '').split(',') if key in candidates]
                if not identifiers:
                    continue
                line = geometry(row['geometry'])
                for key in identifiers:
                    points[key].extend(tuple(coordinate[:2]) for coordinate in line.coords)
                    if table == 'lifts_linestring':
                        lift_counts[key] += 1
        boundaries = {row['feature_id']: geometry(row['geometry']) for row in source.execute('SELECT feature_id, geometry FROM ski_areas_multipolygon') if row['feature_id'] in candidates}
        features = []
        seen = set()
        # Prefer the better populated published grouping for duplicate resort names.
        ordered = sorted(candidates.items(), key=lambda item: (-lift_counts[item[0]], -len(points[item[0]]), item[1][2]))
        named = []
        for key, (row, center, identifier) in ordered:
            if lift_counts[key] == 0 or not points[key] or identifier in seen:
                continue
            if any(name == row['name'].casefold() and center.distance(other) < 0.15 for name, other in named):
                continue
            boundary = boundaries.get(key)
            shape = boundary if boundary is not None else MultiPoint(points[key]).convex_hull
            coverage = padded_coverage(shape, (center.x, center.y))
            if coverage is None:
                continue
            seen.add(identifier)
            named.append((row['name'].casefold(), center))
            features.append({'type': 'Feature', 'id': identifier, 'properties': {
                'id': identifier, 'name': row['name'], 'area': 'Alps',
                'location': ', '.join(filter(None, [row['regions'], row['countries']])).replace(';', ', '),
                'sourceFeatureID': key, 'sources': json.loads(row['sources']),
                'paddingMeters': PADDING_METERS, 'coverageBasis': 'boundary' if boundary is not None else 'runs_and_lifts',
                'approximateAreaSquareMeters': round(approximate_area_square_meters(shape, (center.x, center.y))),
                'tileCoverage': {str(zoom): tile_coverage(coverage, zoom) for zoom in PACK_INDEX_ZOOMS},
                'center': [center.x, center.y],
            }, 'geometry': mapping(coverage)})
        features.sort(key=lambda feature: (feature['properties']['name'].casefold(), feature['id']))
        if not features:
            raise ValueError('No eligible Alpine ski areas in the source')
        catalog = {'type': 'FeatureCollection', 'features': features}
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode='w', dir=output_path.parent, prefix='.offline-catalog-', delete=False) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(catalog, temporary, ensure_ascii=False, separators=(',', ':'))
        try:
            final_stat = source_path.stat()
            if (initial_stat.st_size, initial_stat.st_mtime_ns) != (final_stat.st_size, final_stat.st_mtime_ns):
                raise ValueError('Source changed during catalog preparation')
            os.link(temporary_path, output_path)
        finally:
            temporary_path.unlink(missing_ok=True)
        return {'output': str(output_path), 'regions': len(features),
                'paddingMeters': PADDING_METERS, 'bytes': output_path.stat().st_size}
    finally:
        source.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Published OpenSkiData GeoPackage, opened read-only')
    parser.add_argument('output', type=Path, help='New offline-regions.geojson file; existing files are never overwritten')
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.source, args.output), indent=2))
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'{error}\n')
