import math
import struct
import unittest

from shapely.geometry import Point, Polygon
from shapely.ops import transform

from offline_catalog import EARTH_RADIUS, PACK_INDEX_ZOOMS, approximate_area_square_meters, geometry, grid_projection, local_projection, padded_coverage, tile_coverage
from shapely.geometry import box
from shapely.ops import unary_union


class OfflineGeometryTests(unittest.TestCase):
    def test_area_uses_square_meters_and_subtracts_holes_at_different_latitudes(self):
        footprint = Polygon([(-2000, -2000), (2000, -2000), (2000, 2000), (-2000, 2000)],
                            [[(-500, -500), (-500, 500), (500, 500), (500, -500)]])
        for center in [(11, 0), (11, 47), (11, 70)]:
            _, unproject = local_projection(center)
            area = approximate_area_square_meters(transform(unproject, footprint), center)
            self.assertAlmostEqual(area, 15_000_000, delta=1)

    def test_area_distinguishes_footprints_with_the_same_grid_coverage(self):
        _, unproject = local_projection((11, 47))
        small = transform(unproject, box(-50, -50, 50, 50))
        large = transform(unproject, box(-250, -250, 250, 250))
        self.assertEqual(tile_coverage(padded_coverage(small, (11, 47)), 12),
                         tile_coverage(padded_coverage(large, (11, 47)), 12))
        self.assertAlmostEqual(approximate_area_square_meters(small, (11, 47)), 10_000, delta=1)
        self.assertAlmostEqual(approximate_area_square_meters(large, (11, 47)), 250_000, delta=1)

    def test_graticules_do_not_change_request_geometry_or_select_touching_neighbors(self):
        _, unproject = grid_projection()
        original = transform(unproject, box(2000, 1400, 2001, 1401))
        before = original.wkb
        self.assertEqual(tile_coverage(original, 12), ['12/2000/1400'])
        self.assertEqual(original.wkb, before)

    def test_grid_covers_every_intersection_and_reuses_shared_cells(self):
        project, unproject = grid_projection()
        first = transform(unproject, box(2000.2, 1400.2, 2001.2, 1401.2))
        second = transform(unproject, box(2001.1, 1401.1, 2002.1, 1402.1))
        first_cells = tile_coverage(first, 12)
        second_cells = tile_coverage(second, 12)
        self.assertEqual(len(first_cells), 4)
        self.assertEqual(set(first_cells) & set(second_cells), {'12/2001/1401'})
        footprints = unary_union([box(int(x), int(y), int(x) + 1, int(y) + 1)
                                  for _, x, y in (tile.split('/') for tile in first_cells)])
        self.assertLess(transform(project, first).difference(footprints).area, 1e-10)

    def test_grid_retains_holes_and_disconnected_groups(self):
        project, unproject = grid_projection()
        ring = box(2000, 1400, 2003, 1403).difference(box(2001, 1401, 2002, 1402))
        source = unary_union([ring, box(2010, 1410, 2011, 1411)])
        coverage = transform(unproject, source)
        cells = tile_coverage(coverage, 12)
        self.assertEqual(len(cells), 9)
        self.assertNotIn('12/2001/1401', cells)
        self.assertEqual(coverage.geom_type, 'MultiPolygon')
        self.assertTrue(coverage.is_valid)
        self.assertLess(transform(project, coverage).symmetric_difference(source).area, 1e-10)

    def test_graticules_follow_every_supported_pack_index_zoom(self):
        coverage = box(10.99, 46.99, 11.01, 47.01)
        for zoom in PACK_INDEX_ZOOMS:
            tiles = tile_coverage(coverage, zoom)
            self.assertTrue(tiles)
            self.assertTrue(all(tile.startswith(f'{zoom}/') for tile in tiles))
        self.assertEqual(tile_coverage(coverage, 0), ['0/0/0'])

    def test_padding_preserves_concave_boundary_and_hole(self):
        project, unproject = local_projection((11, 47))
        # A broad L-shaped resort has a notch that must not become a convex hull.
        boundary = Polygon([(0, 0), (20000, 0), (20000, 6000), (6000, 6000),
                            (6000, 20000), (0, 20000)],
                           [[(1000, 1000), (1000, 5000), (5000, 5000), (5000, 1000)]])
        padded = padded_coverage(transform(unproject, boundary), (11, 47))
        local = transform(project, padded)
        self.assertTrue(local.is_valid)
        self.assertTrue(local.covers(boundary))
        self.assertFalse(local.covers(Point(15000, 15000)))
        self.assertAlmostEqual(local.bounds[0], -200, delta=1)
        self.assertAlmostEqual(local.bounds[2], 20200, delta=1)

    def test_point_padding_has_two_hundred_meter_radius(self):
        origin = (10.5, 47.25)
        padded = padded_coverage(Point(origin), origin)
        lon0, lat0 = map(math.radians, origin)
        for lon, lat in padded.exterior.coords:
            lon, lat = math.radians(lon), math.radians(lat)
            haversine = math.sin((lat - lat0) / 2) ** 2 + math.cos(lat0) * math.cos(lat) * math.sin((lon - lon0) / 2) ** 2
            distance = 2 * EARTH_RADIUS * math.asin(math.sqrt(haversine))
            self.assertAlmostEqual(distance, 200, delta=0.01)

    def test_projection_round_trips_alpine_coordinates(self):
        project, unproject = local_projection((10.5, 47.25))
        for point in [(10.5, 47.25), (10.1, 47.6), (11, 46.9)]:
            result = unproject(*project(*point))
            self.assertAlmostEqual(result[0], point[0], places=9)
            self.assertAlmostEqual(result[1], point[1], places=9)

    def test_rejects_collection_spanning_more_than_one_hundred_twenty_kilometers(self):
        self.assertIsNone(padded_coverage(Polygon([(8, 46), (12, 46), (12, 47), (8, 47)]), (10, 46.5)))

    def test_reads_standard_geopackage_and_rejects_wrong_crs_and_empty_geometry(self):
        point = Point(11, 47)
        blob = b'GP\x00\x01' + struct.pack('<i', 4326) + point.wkb
        self.assertEqual(geometry(blob), point)
        with self.assertRaises(ValueError):
            geometry(b'GP\x00\x01' + struct.pack('<i', 3857) + point.wkb)
        with self.assertRaises(ValueError):
            geometry(b'GP\x00\x11' + struct.pack('<i', 4326) + point.wkb)


if __name__ == '__main__':
    unittest.main()
