import com.onthegomap.planetiler.FeatureCollector;
import com.onthegomap.planetiler.Planetiler;
import com.onthegomap.planetiler.Profile;
import com.onthegomap.planetiler.config.Arguments;
import com.onthegomap.planetiler.reader.SourceFeature;
import java.nio.file.Path;
import java.util.List;
import java.util.Set;

/** Sunō's existing OSM layer contract, with independently generated archives. */
public class Sunoh implements Profile {
  private final boolean ski;
  private static final List<String> PLACES = List.of("city", "town", "village", "hamlet", "suburb", "neighbourhood");
  private static final Set<String> LIFTS = Set.of("cable_car", "gondola", "chair_lift", "drag_lift", "t-bar", "platter", "rope_tow", "magic_carpet", "mixed_lift");

  Sunoh(boolean ski) { this.ski = ski; }

  public static void main(String[] argv) throws Exception {
    var args = Arguments.fromArgsOrConfigFile(argv);
    String archive = args.getString("archive", "basemap or ski", "basemap");
    if (!Set.of("basemap", "ski").contains(archive)) throw new IllegalArgumentException("Unknown archive: " + archive);
    Planetiler.create(args.orElse(Arguments.of("minzoom", archive.equals("ski") ? 7 : 0, "maxzoom", 14)))
      .setProfile(new Sunoh(archive.equals("ski")))
      .addOsmSource("osm", Path.of("/data/downloads/osm/planet.osm.pbf"), null)
      .overwriteOutput(Path.of("/data/tiles", archive + ".pmtiles"))
      .run();
  }

  private static FeatureCollector.Feature named(FeatureCollector.Feature f, SourceFeature s) {
    return f.setAttr("name", s.getTag("name")).setAttr("name:en", s.getTag("name:en"));
  }

  @Override public void processFeature(SourceFeature s, FeatureCollector f) {
    if (ski) {
      if (s.hasTag("piste:type", "downhill")) {
        var run = s.canBePolygon() ? f.polygon("runs") : s.canBeLine() ? f.line("runs") : null;
        if (run != null) run.setMinZoom(7).setMinPixelSize(0)
          .setAttr("name", s.hasTag("name") ? s.getTag("name") : s.getTag("piste:name"))
          .setAttr("ref", s.getTag("ref")).setAttr("piste:type", "downhill")
          .setAttr("piste:difficulty", s.getTag("piste:difficulty"));
      }
      if (s.canBeLine() && LIFTS.contains(s.getString("aerialway", ""))) {
        named(f.line("lifts"), s).setMinZoom(7).setMinPixelSize(0)
          .setAttr("ref", s.getTag("ref")).setAttr("aerialway", s.getTag("aerialway"));
      }
      return;
    }
    if (s.canBePolygon()) {
      if (s.hasTag("building")) named(f.polygon("buildings"), s).setMinZoom(13).setAttr("kind", s.getTag("building"));
      if (s.hasTag("natural", "water") || s.hasTag("waterway")) {
        named(f.polygon("water"), s).setMinZoom(0).setAttr("kind", s.getString("natural", "water"));
      }
      String natural = s.getString("natural", "");
      if (Set.of("wood", "bare_rock", "scree", "glacier", "scrub").contains(natural) || s.hasTag("landuse", "forest")) {
        f.polygon("natural").setMinZoom(7).setAttr("kind", natural.equals("wood") || s.hasTag("landuse", "forest") ? "forest" : natural);
      }
    }
    if (s.canBeLine()) {
      if (s.hasTag("waterway")) named(f.line("water"), s).setMinZoom(9).setAttr("kind", s.getTag("waterway"));
      road(s, f);
    }
    if (s.isPoint()) {
      int rank = PLACES.indexOf(s.getString("place", "")) + 1;
      if (rank > 0) named(f.point("places"), s).setMinZoom(2).setAttr("kind", s.getTag("place")).setAttr("rank", rank);
      if (s.hasTag("natural", "peak")) named(f.point("peaks"), s).setMinZoom(9).setAttr("elevation", s.getTag("ele"));
    }
  }

  private static boolean enabled(SourceFeature s, String key) {
    return !Set.of("", "no", "false", "0").contains(s.getString(key, ""));
  }

  private static void road(SourceFeature s, FeatureCollector f) {
    if (s.hasTag("area", "yes")) return;
    String kind = s.getString("highway", "");
    String base = kind.replaceFirst("_link$", "");
    String cls = base;
    int zoom, rank;
    switch (base) {
      case "motorway" -> { zoom = 6; rank = 8; }
      case "trunk" -> { zoom = 7; rank = 7; }
      case "primary" -> { zoom = 8; rank = 6; }
      case "secondary" -> { zoom = 9; rank = 5; }
      case "tertiary" -> { zoom = 10; rank = 4; }
      case "unclassified", "residential", "living_street", "road" -> { cls = "minor"; zoom = 12; rank = 3; }
      case "service" -> { zoom = 13; rank = 2; }
      case "pedestrian" -> { zoom = 13; rank = 1; }
      default -> { return; }
    }
    int layer = 0;
    try { layer = Integer.parseInt(s.getString("layer", "0")); } catch (NumberFormatException ignored) {}
    named(f.line("roads"), s).setMinZoom(zoom).setAttr("kind", kind).setAttr("class", cls)
      .setAttr("ref", s.getTag("ref")).setAttr("surface", s.getTag("surface"))
      .setAttr("brunnel", enabled(s, "tunnel") ? "tunnel" : enabled(s, "bridge") ? "bridge" : "surface")
      .setAttr("layer", layer).setAttr("sort_key", layer * 10 + rank).setSortKey(layer * 10 + rank);
  }

  @Override public String name() { return ski ? "ski" : "basemap"; }
  @Override public String attribution() { return "© OpenStreetMap contributors (https://www.openstreetmap.org/copyright)"; }
}
