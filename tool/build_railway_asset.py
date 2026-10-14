"""Build named passenger-track data from an Overpass JSON snapshot.

Used by prepare_station_maps.py. Query centers are read from stations.json.
"""
import math
import re
from collections import defaultdict

COLORS = {'山手線': '#3b946b', '中央本線': '#c88335', '中央緩行線': '#ac972a',
          '中央線': '#c88335', '京浜東北線': '#4b93b6', '東海道本線': '#529f96',
          '横須賀線': '#647dab', '東海道新幹線': '#5683ad', '東北新幹線': '#4c8c85',
          '東北本線': '#659b74', '京葉線': '#bd646c', '総武本線': '#8e79a9',
          '埼京線': '#408e89', '小田急小田原線': '#568eae', '京王線': '#a867a6',
          '京王新線': '#9780ad', '井の頭線': '#649bad', '東横線': '#a86d7c',
          '田園都市線': '#549e88', '銀座線': '#c58b37', '半蔵門線': '#8b78af',
          '丸ノ内線': '#bd6864', '千代田線': '#529575', '有楽町線': '#a9966c',
          '東西線': '#6096af', '副都心線': '#aa8768', '大江戸線': '#a96f91',
          '三田線': '#698bae', '浅草線': '#b98086'}


def label_key(value):
    converted=''.join(chr(ord(c)-0x60) if 'ァ' <= c <= 'ヶ' else c for c in value.lower())
    return re.sub(r'[\s　_\-]', '', converted)


def route_name(tags):
    name = tags.get('name:ja', tags.get('name', ''))
    if ('貨物' in name or 'freight' in name.lower() or
            tags.get('railway:traffic_mode') == 'freight' or
            tags.get('service') in ['yard', 'siding', 'spur']):
        return None
    for prefix in ['東京メトロ', '都営地下鉄', '京王電鉄', 'JR', '東急']:
        if name.startswith(prefix):
            name = name[len(prefix):]
    # Municipal tram operator prefixes are not the branch name. Keep the
    # source name in osm_names, and use its actual named branch (e.g. 大森線).
    if tags.get('railway') == 'tram':
        name = re.sub(r'^.+?市電(?=.+線)', '', name)
    # A bridge / platform suffix is not part of the verified line name.
    name = name.split(';')[0]
    name = re.sub(r'\s+\([^)]*\)$', '', name)
    if name == '東海道本線（横須賀線）':
        name = '横須賀線'
    return name or None


def distance(a, b):
    return math.hypot((a[0] - b[0]) * math.cos(math.radians(b[1])) * 111320,
                      (a[1] - b[1]) * 111320)


def build(ways, station, answer_aliases=(), blocked_labels=()):
    _, lat, lon, answer = station
    groups = defaultdict(list)
    seen = set()
    for way in ways:
        if way['id'] in seen or way.get('type') != 'way':
            continue
        seen.add(way['id'])
        name = route_name(way.get('tags', {}))
        if not name or any(label_key(alias) in label_key(name) for alias in [answer,*answer_aliases,*blocked_labels]):
            continue
        points = [[p['lon'], p['lat']] for p in way.get('geometry', []) if p]
        if len(points) < 2 or min(distance(p, [lon, lat]) for p in points) > 8000:
            continue
        groups[name].append((points, [way['id']], {way['tags'].get('name', '')}))
    features = []
    for name, segments in groups.items():
        pending = segments[:]
        while pending:
            points, ids, names = pending.pop(0)
            joined = True
            while joined:
                joined = False
                for i, (other, other_ids, other_names) in enumerate(pending):
                    if points[-1] == other[0]:
                        points += other[1:]
                    elif points[-1] == other[-1]:
                        points += list(reversed(other))[1:]
                    elif points[0] == other[-1]:
                        points = other + points[1:]
                    elif points[0] == other[0]:
                        points = list(reversed(other)) + points[1:]
                    else:
                        continue
                    ids += other_ids
                    names.update(other_names)
                    pending.pop(i)
                    joined = True
                    break
            if sum(distance(a, b) for a, b in zip(points, points[1:])) < 150:
                continue
            features.append({'type': 'Feature', 'properties': {
                'name': name, 'color': COLORS.get(name, '#718e86'),
                'osm_way_ids': ids, 'osm_names': sorted(names)},
                'geometry': {'type': 'LineString', 'coordinates': points}})
    return {'type': 'FeatureCollection', 'features': features}


