"""Prepare OSM-derived hints for any catalog station; no station-specific code.

python3 tool/prepare_station_maps.py --fetch [--station sapporo]
python3 tool/prepare_station_maps.py snapshot1.json snapshot2.json
Read-only Overpass queries are sequential; raw responses are cached under /tmp.
"""
import argparse
import datetime
import hashlib
import json
import subprocess
from pathlib import Path
from build_railway_asset import build, distance, label_key

ROOT = Path(__file__).resolve().parent.parent
ENDPOINT = 'https://overpass-api.de/api/interpreter'

def query(station):
    point = f"{station['latitude']},{station['longitude']}"
    return ('[out:json][timeout:45][maxsize:67108864];'
            f'way[railway~"^(rail|subway|light_rail|tram)$"][name](around:8000,{point});out tags geom;('
            f'node[name][place~"^(suburb|quarter|neighbourhood|city|town)$"](around:4000,{point});'
            f'nwr[name][leisure=park](around:4000,{point});'
            f'nwr[name][tourism~"^(museum|attraction|gallery)$"](around:4000,{point});'
            f'nwr[name][amenity~"^(townhall|university|place_of_worship)$"](around:4000,{point});'
            ');out tags center;')

key = label_key

def safe_label(station, name):
    normalized=key(name)
    aliases=[key(s) for s in [station['name'],station['nameKana'],*station.get('answerAliases',[])]]
    if any(normalized in [a,a+'駅'] or any(a+suffix in normalized for suffix in ['駅','station','ステーション','stn']) for a in aliases):
        return False
    if any(key(s) in normalized for s in station.get('blockedLabels', [])):
        return False
    return name in station.get('allowedLabels',[]) or not any(a in normalized for a in aliases)

def labels(elements, station):
    features = []
    for item in elements:
        tags = item.get('tags', {})
        # Never import station names, stops, platforms, or commercial POI lists.
        if tags.get('railway') or tags.get('public_transport'):
            continue
        name = tags.get('name:ja', tags.get('name', ''))
        if not name or not safe_label(station, name):
            continue
        kind = 'place' if tags.get('place') in ['suburb','quarter','neighbourhood','city','town'] else 'facility'
        if kind == 'facility' and not (tags.get('leisure') == 'park' or
            tags.get('tourism') in ['museum','attraction','gallery'] or
            tags.get('amenity') in ['townhall','university','place_of_worship']):
            continue
        point = item if 'lat' in item else item.get('center', {})
        if 'lat' not in point:
            continue
        coord = [point['lon'], point['lat']]
        d = distance(coord, [station['longitude'], station['latitude']])
        if d > 4000:
            continue
        # Keep the map readable: real major landmarks precede minor attractions.
        allowed = name in station.get('allowedLabels',[])
        if tags.get('tourism') == 'attraction' and not (allowed or tags.get('historic') or tags.get('man_made') == 'tower' or tags.get('leisure') == 'park'):
            continue
        if kind == 'place':
            priority = 2 if any(c.isdigit() or c in '一二三四五六七八九十' for c in name) and '丁目' in name else 0
        else:
            priority = 0 if allowed else (1 if tags.get('leisure') == 'park' or tags.get('tourism') == 'museum' or tags.get('amenity') in ['townhall','university'] else 2)
        features.append((priority, d, {'type':'Feature', 'geometry':{'type':'Point','coordinates':coord},
            'properties':{'name':name,'kind':kind,'osm_type':item['type'],'osm_id':item['id'],
                          'rank':priority, 'anchor':'node' if item['type']=='node' else 'OSM bounding-box center'}}))
    features.sort(key=lambda f: (f[0], f[1]))
    # Deduplicate OSM nodes/areas with the same name and nearby anchors.
    selected=[]; counts={'place':0,'facility':0}
    for priority,d,feature in features:
        kind=feature['properties']['kind']; name=feature['properties']['name']
        if counts[kind] >= 18: continue
        if any(f['properties']['name']==name and distance(f['geometry']['coordinates'],feature['geometry']['coordinates']) < 500 for f in selected): continue
        selected.append(feature); counts[kind]+=1
    return {'type':'FeatureCollection','features':selected}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshots', nargs='*')
    parser.add_argument('--fetch', action='store_true')
    parser.add_argument('--station', action='append', help='Repeat to update multiple station IDs while preserving existing hints')
    parser.add_argument('--endpoint', default=ENDPOINT, help='Read-only Overpass endpoint')
    args = parser.parse_args()
    catalog_path = ROOT/'assets/data/stations.json'
    stations = json.loads(catalog_path.read_text())
    selected = [s for s in stations if s['enabled'] and (not args.station or s['id'] in args.station)]
    if not selected:
        parser.error('No matching enabled stations')
    snapshots = args.snapshots[:]
    if args.fetch:
        cache = Path('/tmp/ekidoko-osm-hints'); cache.mkdir(exist_ok=True)
        for station in selected:
            text = query(station)
            path = cache/(station['id']+'-'+hashlib.sha256(text.encode()).hexdigest()[:12]+'.json')
            if path.exists():
                try:
                    cached=json.loads(path.read_text())
                    if cached.get('remark') or not isinstance(cached.get('elements'),list): path.unlink()
                except (ValueError,OSError): path.unlink(missing_ok=True)
            if not path.exists():
                query_path=cache/(station['id']+'.query'); query_path.write_text(text)
                print('Fetching '+station['id'],flush=True)
                subprocess.run(['curl','--fail','--retry','2','--retry-delay','30','--retry-all-errors','--max-time','65','-sS','-G','-A','ekidoko-prototype/1.0',
                    '--data-urlencode','data@'+str(query_path),args.endpoint,'-o',str(path.with_suffix('.download'))], check=True)
                downloaded=json.loads(path.with_suffix('.download').read_text())
                if downloaded.get('remark') or not isinstance(downloaded.get('elements'),list):
                    raise ValueError(station['id']+': '+downloaded.get('remark','Invalid OSM response'))
                path.with_suffix('.download').replace(path)
            snapshot=json.loads(path.read_text())
            snapshot['_source']=args.endpoint; snapshot['_query']=text
            path.write_text(json.dumps(snapshot,ensure_ascii=False))
            snapshots.append(str(path))
    if not snapshots:
        parser.error('Supply snapshots or --fetch')
    elements={}; dates=[]; sources=[]
    for filename in snapshots:
        data=json.loads(Path(filename).read_text())
        if data.get('remark'):
            raise ValueError(filename+': '+data['remark'])
        dates.append(data.get('osm3s',{}).get('timestamp_osm_base'))
        query_path=Path(filename).with_suffix('.query')
        sources.append({'source':data.get('_source',ENDPOINT),'query':query_path.read_text() if query_path.exists() else data.get('_query','See regeneration queries'),'osm_base_timestamp':data.get('osm3s',{}).get('timestamp_osm_base')})
        elements.update({(e['type'],e['id']):e for e in data['elements']})
    path=ROOT/'assets/maps/station_hints.json'
    result=json.loads(path.read_text()) if path.exists() and args.station else {}
    for station in selected:
        railways=build(list(elements.values()), (station['id'],station['latitude'],station['longitude'],station['name']),
            answer_aliases=[station['nameKana'],*station.get('answerAliases',[])], blocked_labels=station.get('blockedLabels',[]))
        hint_labels=labels(elements.values(), station)
        if not railways['features'] or not hint_labels['features']:
            raise ValueError(station['id']+': railway/landmark data missing; no asset written')
        result[station['id']]={'latitude':station['latitude'],'longitude':station['longitude'],
            'railways':railways,'labels':hint_labels}
        print(f"{station['id']}: {len(railways['features'])} rail paths, {len(hint_labels['features'])} labels")
    previous=result.get('_provenance',{})
    combined_sources=previous.get('sources',[]) + sources
    unique_sources={json.dumps(s,sort_keys=True,ensure_ascii=False):s for s in combined_sources}
    previous_queries=previous.get('regeneration_queries',[])
    result['_provenance']={'date':str(datetime.date.today()),'attribution':'© OpenStreetMap contributors',
        'license':'ODbL-1.0','source':ENDPOINT,'osm_base_timestamps':list(dict.fromkeys(previous.get('osm_base_timestamps',[])+dates)),
        'railway_radius_meters':8000,'label_radius_meters':4000,'sources':list(unique_sources.values()),'regeneration_queries':list(dict.fromkeys(previous_queries+[query(s) for s in selected])),
        'note':'Real OSM vertices; joins only at equal endpoints. Labels use real nodes or geometric centers. No fictional features.'}
    path.write_text(json.dumps(result,ensure_ascii=False,separators=(',',':'))+'\n')
    print(f'{path}: {path.stat().st_size:,} bytes')

if __name__=='__main__': main()
