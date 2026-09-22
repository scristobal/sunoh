import sys
import xml.etree.ElementTree as ET

for point in ET.parse(sys.argv[1]).getroot().iter('{http://www.topografix.com/GPX/1/1}wpt'):
    print(f"{point.get('lat')},{point.get('lon')}")
