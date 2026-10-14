"""Build the reviewed three-station PoC from OSM relations and actual tile POIs.

python3 tool/prepare_map_hints_poc.py /tmp/ekidoko-poc-sources
The directory contains <station>.json Overpass responses and decoded
<station>-tile.json (mapbox_vector_tile, default y-up coordinates). Queries,
tile URLs, source tags/vertices and reviewed colour references are recorded.
No network calls, colour inference, interpolated paths or invented POIs.
"""
import argparse
import datetime
import hashlib
import json
import math
from pathlib import Path
from build_railway_asset import build

ROOT = Path(__file__).resolve().parent.parent
# Reviewed relation IDs, not names guessed from proximity or track shapes.
SERVICES = {
    'yamanote': ('山手線', '#B1CB39', [1972920, 1972960], 'https://www.jreast.co.jp/tc/info/map_a4ol.pdf'),
    'keihin': ('京浜東北線', '#00BFFF', [5195691, 5195692], 'https://www.jreast.co.jp/press/2021/yokohama/20220209_y01.pdf'),
    'chuo_rapid': ('中央線快速', '#F15620', [10363875, 10363876], 'https://www.jreast.co.jp/press/2024/hachioji/20241213_hc01.pdf'),
    'marunouchi': ('丸ノ内線', '#F62E36', [443282, 8015932], 'https://www.tokyometro.jp/station/line_marunouchi/index.html'),
    'ginza': ('銀座線', '#FF9500', [443281, 8026074], 'https://www.tokyometro.jp/station/line_ginza/index.html'),
    'hibiya': ('日比谷線', '#B5B5AC', [443272, 8026155], 'https://www.tokyometro.jp/station/line_hibiya/index.html'),
    'nara': ('奈良線', '#BA7C31', [11370090, 11370478], 'https://www.westjr.co.jp/press/article/2014/08/page_5993.html'),
    'karasuma': ('烏丸線', '#3CB371', [536800, 8030560], 'https://www.city.kyoto.lg.jp/kotsu/page/0000296682.html'),
}
REVIEW = {
    'tokyo': {'services': ['yamanote', 'keihin', 'chuo_rapid', 'marunouchi'], 'pois': [('node', 3164340661), ('node', 4646514991), ('node', 2214684270), ('node', 6604348338)]},
    'ueno': {'services': ['yamanote', 'keihin', 'ginza', 'hibiya'], 'pois': [('way', 203960903), ('way', 203960902), ('node', 441655802), ('way', 625528441), ('way', 138585452)]},
    'kyoto': {'services': ['nara', 'karasuma'], 'pois': [('node', 5111884542), ('way', 441352467), ('node', 5936885886), ('node', 12462481217), ('way', 171692862)]},
}


def poi_kind(properties):
    cls, sub = properties.get('class'), properties.get('subclass')
    if cls in ['school', 'college']: return 'education'
    if cls == 'hospital': return 'hospital'
    if cls == 'place_of_worship' and sub in ['shinto', 'buddhist']: return 'religion'
    if cls in ['museum', 'art_gallery']: return 'culture'
    if sub in ['mall', 'department_store']: return 'shopping'
    if sub == 'stadium': return 'stadium'
    return None


def tile_point(tile, point):
    extent = tile['layers']['poi']['extent']
    x = (tile['x'] + point[0] / extent) / 2 ** tile['z']
    y = (tile['y'] + 1 - point[1] / extent) / 2 ** tile['z']
    return [x * 360 - 180, math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y))))]


def shared_offset(service, memberships):
    ordered = sorted(set(memberships))
    return (ordered.index(service) - (len(ordered) - 1) / 2) * 2.8


def source_file(path):
    content = path.read_bytes()
    return {
        'name': path.name,
        'bytes': len(content),
        'sha256': hashlib.sha256(content).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source_dir', type=Path)
    args = parser.parse_args()
    stations = json.loads((ROOT / 'assets/data/stations.json').read_text())
    result = {'stations': {}, 'provenance': {'date': '2026-10-14', 'attribution': '© OpenStreetMap contributors', 'license': 'ODbL-1.0', 'colourReview': 'Exact RGB comes from reviewed OSM relation colour tags. Operator publications confirm line identity and hue; these RGB values are not claimed to be an operator brand specification.'}}
    proof = {
        'provenance': {
            'date': '2026-10-14',
            'purpose': 'Audit evidence only; facility names are not copied to the runtime asset.',
            'osm': {
                'attribution': '© OpenStreetMap contributors',
                'license': 'ODbL-1.0',
                'url': 'https://www.openstreetmap.org/copyright',
            },
            'tileSchema': {
                'name': 'OpenMapTiles',
                'license': 'CC BY 4.0',
                'poiDefinition': 'https://github.com/openmaptiles/openmaptiles/blob/master/layers/poi/poi.yaml',
                'transportationDefinition': 'https://github.com/openmaptiles/openmaptiles/blob/master/layers/transportation/transportation.yaml',
            },
            'tileDecoder': 'mapbox-vector-tile 2.2.0, default y-up coordinates',
        },
        'stations': {},
        'services': {k: {'name': v[0], 'color': v[1], 'relationIds': v[2], 'operatorReference': v[3]} for k, v in SERVICES.items()},
    }
    result['services'] = proof['services']
    for station_id, review in REVIEW.items():
        if len(review['pois']) > 5:
            raise ValueError(f'{station_id}: PoC permits at most five facilities')
        station = next(s for s in stations if s['id'] == station_id)
        raw_path = args.source_dir / f'{station_id}.json'
        query_path = args.source_dir / f'{station_id}.query'
        tile_path = args.source_dir / f'{station_id}-tile.json'
        pbf_path = args.source_dir / f'{station_id}-tile.pbf'
        raw = json.loads(raw_path.read_text())
        tile = json.loads(tile_path.read_text())
        if raw.get('remark'): raise ValueError('Incomplete OSM response')
        elements = {(e['type'], e['id']): e for e in raw['elements']}
        memberships, used_relations = {}, {}
        for service in review['services']:
            name, color, relation_ids, _ = SERVICES[service]
            for relation_id in relation_ids:
                relation = elements.get(('relation', relation_id))
                if relation is None:
                    raise ValueError(f'{station_id}: reviewed relation missing: {relation_id}')
                tags = relation['tags']
                if tags.get('type') != 'route' or tags.get('route') not in ['train', 'subway'] or tags.get('colour', '').upper() != color.upper():
                    raise ValueError(f'{relation_id}: reviewed route/colour changed')
                used_relations[relation_id] = relation
                for member in relation['members']:
                    way = elements.get(('way', member['ref'])) if member['type'] == 'way' else None
                    if not way or way.get('tags', {}).get('railway') not in ['rail', 'subway'] or way['tags'].get('service') in ['yard', 'siding', 'spur']: continue
                    memberships.setdefault(way['id'], {}).setdefault(service, []).append(relation_id)
        route_features, source_ways = [], {}
        for service in review['services']:
            name, color, _, _ = SERVICES[service]
            groups = {}
            for way_id, members in memberships.items():
                if service not in members: continue
                way = elements['way', way_id]
                source_ways[way_id] = way
                offset = shared_offset(service, members.keys())
                # Keep all source vertices. Join only exactly shared endpoints.
                groups.setdefault(offset, []).append({**way, 'tags': {**way['tags'], 'name': name, 'name:ja': name}})
            for offset, ways in groups.items():
                features = build(ways, (station_id, station['latitude'], station['longitude'], station['name']))['features']
                for feature in features:
                    ids = feature['properties']['osm_way_ids']
                    feature['properties'] = {'name': name, 'color': color, 'serviceId': service, 'lineOffset': offset, 'osm_way_ids': ids, 'osm_relation_ids': sorted({r for wid in ids for r in memberships[wid][service]})}
                    route_features.append(feature)
        generated_services = {feature['properties']['serviceId'] for feature in route_features}
        if generated_services != set(review['services']):
            missing = sorted(set(review['services']) - generated_services)
            raise ValueError(f'{station_id}: reviewed services generated no paths: {missing}')
        pois, source_pois = [], []
        for rank, (osm_type, osm_id) in enumerate(review['pois']):
            original = elements[osm_type, osm_id]
            tile_id = osm_id * 10 + {'node': 1, 'way': 2, 'relation': 3}[osm_type]
            matches = [p for p in tile['layers']['poi']['features'] if p['id'] == tile_id]
            if len(matches) != 1: raise ValueError(f'{station_id}: reviewed tile POI missing/duplicated: {osm_id}')
            poi = matches[0]; kind = poi_kind(poi['properties'])
            if kind is None or poi['geometry']['type'] != 'Point': raise ValueError('Unreviewed facility classification/position')
            point = tile_point(tile, poi['geometry']['coordinates'])
            pois.append({'type': 'Feature', 'geometry': {'type': 'Point', 'coordinates': point}, 'properties': {'kind': kind, 'rank': rank, 'osm_type': osm_type, 'osm_id': osm_id}})
            source_pois.append({'osm': original, 'tileFeature': poi, 'position': point})
        result['stations'][station_id] = {'latitude': station['latitude'], 'longitude': station['longitude'], 'facilities': {'type': 'FeatureCollection', 'features': pois[:5]}, 'routes': {'type': 'FeatureCollection', 'features': route_features}}
        proof['stations'][station_id] = {
            'query': query_path.read_text(),
            'osmEndpoint': 'https://overpass-api.de/api/interpreter',
            'osmBaseTimestamp': raw.get('osm3s', {}).get('timestamp_osm_base'),
            'tileUrl': tile['url'],
            'tileCoordinates': {key: tile[key] for key in ['z', 'x', 'y']},
            'tilePoiExtent': tile['layers']['poi']['extent'],
            'sourceFiles': {
                'query': source_file(query_path),
                'overpass': source_file(raw_path),
                'decodedTile': source_file(tile_path),
                **({'vectorTile': source_file(pbf_path)} if pbf_path.exists() else {}),
            },
            'pois': source_pois,
            'relations': list(used_relations.values()),
            'ways': list(source_ways.values()),
        }
        print(station_id, 'facilities', len(pois), 'route paths', len(route_features), 'shared offsets', sorted({f['properties']['lineOffset'] for f in route_features}))
    (ROOT / 'assets/maps/map_hints_poc.json').write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
    (ROOT / 'docs/map-hints-poc/sources.json').write_text(json.dumps(proof, ensure_ascii=False, separators=(',', ':')) + '\n')


if __name__ == '__main__': main()
