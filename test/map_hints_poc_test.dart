import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/map/map_hints_poc.dart';
import 'package:ekidoko/map/facility_icons.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'support/catalog.dart';

const tiles = {
  'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
};
final source = File('assets/maps/map_hints_poc.json').readAsStringSync();
final data = jsonDecode(source) as Map<String, dynamic>;
final hintData =
    jsonDecode(File('assets/maps/station_hints.json').readAsStringSync())
        as Map;
final proof =
    jsonDecode(File('docs/map-hints-poc/sources.json').readAsStringSync())
        as Map;
const expectedServices = {
  'tokyo': {'yamanote', 'keihin', 'chuo_rapid', 'marunouchi'},
  'ueno': {'yamanote', 'keihin', 'ginza', 'hibiya'},
  'kyoto': {'nara', 'karasuma'},
};
const expectedRepresentativeFacilities = {
  'tokyo': {'東京国立近代美術館', 'インターメディアテク', '国立映画アーカイブ'},
  'ueno': {'国立西洋美術館', '国立科学博物館', '東京国立博物館'},
  'kyoto': {'京都タワー', '京都国立博物館', '京都鉄道博物館'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rollout is exactly Tokyo/Ueno/Kyoto; all 47 other stations keep the original hints',
    () async {
      expect((data['stations'] as Map).keys.toSet(), mapHintsPocStationIds);
      expect(catalog.select(), hasLength(50));
      expect(catalog.select().where((s) => s.easyEligible), hasLength(34));
      for (final station in stations.where(
        (s) => !mapHintsPocStationIds.contains(s.id),
      )) {
        expect(await loadMapHintsPoc(station), isNull);
        for (var hint = 0; hint < 4; hint++) {
          final style = quizMapStyle(station, tiles, hint: hint);
          expect(
            (style['sources'] as Map).containsKey('poc-facilities'),
            false,
          );
          final layers = style['layers'] as List;
          expect(layers.any((l) => l['id'] == 'poc-facility-icons'), false);
          expect(
            layers.singleWhere(
              (l) => l['id'] == 'named-railway-colors',
            )['layout']['visibility'],
            hint >= 2 ? 'visible' : 'none',
          );
          expect(
            layers.where((l) => l['type'] == 'symbol').map((l) => l['id']),
            ['hint-places', 'hint-facilities', 'railway-labels'],
          );
        }
      }
    },
  );
  test(
    'curated facilities have actual tile/OSM positions and no name or popup data',
    () {
      for (final station in stations.where(
        (s) => mapHintsPocStationIds.contains(s.id),
      )) {
        final poc = MapHintsPoc.parse(source, station);
        final features = poc.facilities['features'] as List;
        expect(features.length, lessThanOrEqualTo(5));
        final origin = proof['stations'][station.id] as Map;
        for (final f in features) {
          final p = f['properties'] as Map;
          expect(
            p.keys,
            unorderedEquals(['kind', 'rank', 'osm_type', 'osm_id']),
          );
          expect(facilityKinds, contains(p['kind']));
          final record = (origin['pois'] as List).singleWhere(
            (r) =>
                r['osm']['type'] == p['osm_type'] &&
                r['osm']['id'] == p['osm_id'],
          );
          expect(f['geometry']['coordinates'], record['position']);
          expect(record['tileFeature']['properties']['name'], isNotEmpty);
          final encodedType = {
            'node': 1,
            'way': 2,
            'relation': 3,
          }[p['osm_type']];
          expect(
            record['tileFeature']['id'],
            (p['osm_id'] as int) * 10 + encodedType!,
          );
          final coords = f['geometry']['coordinates'] as List;
          final tilePoint =
              record['tileFeature']['geometry']['coordinates'] as List;
          final tile = origin['tileCoordinates'] as Map;
          final extent = origin['tilePoiExtent'] as num;
          final scale = pow(2, tile['z'] as int);
          final worldX =
              ((tile['x'] as num) + (tilePoint[0] as num) / extent) / scale;
          final worldY =
              ((tile['y'] as num) + 1 - (tilePoint[1] as num) / extent) / scale;
          final tileLongitude = worldX * 360 - 180;
          final mercatorAngle = pi * (1 - 2 * worldY);
          final hyperbolicSine = (exp(mercatorAngle) - exp(-mercatorAngle)) / 2;
          final tileLatitude = atan(hyperbolicSine) * 180 / pi;
          expect(coords[0], closeTo(tileLongitude, 0.000000001));
          expect(coords[1], closeTo(tileLatitude, 0.000000001));
          final raw = record['osm'];
          final anchor = raw['type'] == 'node' ? raw : raw['center'];
          // Independent geographic check against the original OSM node/area.
          final dx =
              (coords[0] - anchor['lon']) *
              cos(station.latitude * pi / 180) *
              111320;
          final dy = (coords[1] - anchor['lat']) * 111320;
          expect(sqrt(dx * dx + dy * dy), lessThan(150));
          final stationDx =
              (coords[0] - station.longitude) *
              cos(station.latitude * pi / 180) *
              111320;
          final stationDy = (coords[1] - station.latitude) * 111320;
          expect(
            sqrt(stationDx * stationDx + stationDy * stationDy),
            lessThan(500),
          );
        }
      }
    },
  );
  test(
    'every coloured edge and way is supported by the exact reviewed route relation',
    () {
      for (final station in stations.where(
        (s) => mapHintsPocStationIds.contains(s.id),
      )) {
        final poc = MapHintsPoc.parse(source, station);
        final origin = proof['stations'][station.id];
        final serviceIds = (poc.routes['features'] as List)
            .map((feature) => feature['properties']['serviceId'] as String)
            .toSet();
        expect(serviceIds, expectedServices[station.id]);
        final ways = {for (final w in origin['ways']) w['id']: w};
        final relations = {for (final r in origin['relations']) r['id']: r};
        for (final serviceId in expectedServices[station.id]!) {
          final expectedRelations =
              (proof['services'][serviceId]['relationIds'] as List).toSet();
          expect(relations.keys.toSet().containsAll(expectedRelations), true);
        }
        for (final f in poc.routes['features']) {
          final p = f['properties'];
          final service = proof['services'][p['serviceId']];
          expect(p['name'], service['name']);
          expect(p['color'], service['color']);
          final sourceEdges = <String>{};
          for (final id in p['osm_way_ids']) {
            expect(
              (p['osm_relation_ids'] as List).any(
                (r) => (relations[r]['members'] as List).any(
                  (m) => m['type'] == 'way' && m['ref'] == id,
                ),
              ),
              true,
            );
            final raw = ways[id]['geometry'] as List;
            final points = raw.map((v) => [v['lon'], v['lat']]).toList();
            for (var i = 1; i < points.length; i++) {
              sourceEdges.add(jsonEncode([points[i - 1], points[i]]));
              sourceEdges.add(jsonEncode([points[i], points[i - 1]]));
            }
          }
          for (final id in p['osm_relation_ids']) {
            expect(
              relations[id]['tags']['colour'].toString().toUpperCase(),
              p['color'].toString().toUpperCase(),
            );
            expect(service['relationIds'], contains(id));
          }
          final points = f['geometry']['coordinates'] as List;
          for (var i = 1; i < points.length; i++) {
            expect(
              sourceEdges,
              contains(jsonEncode([points[i - 1], points[i]])),
            );
          }
        }
      }
    },
  );
  test(
    'PoC starts without route colours/text and reveals colours only at hint one',
    () {
      for (final station in stations.where(
        (s) => mapHintsPocStationIds.contains(s.id),
      )) {
        final poc = MapHintsPoc.parse(source, station);
        for (var hint = 0; hint < 4; hint++) {
          final style = quizMapStyle(
            station,
            tiles,
            hint: hint,
            hintLabels: hintData[station.id]['labels'],
            poc: poc,
          );
          final layers = style['layers'] as List;
          final icon = layers.singleWhere(
            (l) => l['id'] == 'poc-facility-icons',
          );
          expect(icon['layout'].containsKey('text-field'), false);
          expect(icon['layout']['icon-size'], [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            1.0,
            15.5,
            1.5,
          ]);
          expect(icon['layout']['icon-allow-overlap'], true);
          expect(icon['layout']['icon-ignore-placement'], true);
          expect(
            layers.any((layer) => layer['id'] == 'hint-facility-markers'),
            false,
          );
          final representativeNames =
              ((style['sources'] as Map)['reviewed-hints']['data']['features']
                      as List)
                  .where(
                    (feature) => feature['properties']['kind'] == 'facility',
                  )
                  .map((feature) => feature['properties']['name'] as String)
                  .toSet();
          expect(
            representativeNames,
            expectedRepresentativeFacilities[station.id],
          );
          expect(
            (style['sources'] as Map)['poc-facilities']['data']['features'],
            hasLength((poc.facilities['features'] as List).length),
          );
          expect(
            layers.singleWhere(
              (l) => l['id'] == 'named-railway-colors',
            )['layout']['visibility'],
            hint >= 1 ? 'visible' : 'none',
          );
          expect(
            layers.singleWhere(
              (l) => l['id'] == 'railway-labels',
            )['layout']['visibility'],
            hint >= 2 ? 'visible' : 'none',
          );
          expect(
            layers.singleWhere(
              (l) => l['id'] == 'hint-facilities',
            )['layout']['visibility'],
            hint >= 3 ? 'visible' : 'none',
          );
          expect(
            (style['sources'] as Map)['named-railways']['data']['features'],
            poc.routes['features'],
          );
        }
      }
    },
  );
  test(
    'missing facilities are not invented; invalid positions/counts/unknown colours are rejected',
    () {
      final station = stations.firstWhere((s) => s.id == 'tokyo');
      Map<String, dynamic> copy() => jsonDecode(source) as Map<String, dynamic>;
      final empty = copy();
      empty['stations']['tokyo']['facilities']['features'] = [];
      expect(
        MapHintsPoc.parse(jsonEncode(empty), station).facilities['features'],
        isEmpty,
      );
      final tooMany = copy();
      final features =
          tooMany['stations']['tokyo']['facilities']['features'] as List;
      features.addAll(List.of(features));
      expect(
        () => MapHintsPoc.parse(jsonEncode(tooMany), station),
        throwsFormatException,
      );
      final invalid = copy();
      invalid['stations']['tokyo']['facilities']['features'][0]['geometry']['coordinates'][1] =
          200;
      expect(
        () => MapHintsPoc.parse(jsonEncode(invalid), station),
        throwsFormatException,
      );
      final named = copy();
      named['stations']['tokyo']['facilities']['features'][0]['properties']['name'] =
          'Secret station name';
      expect(
        () => MapHintsPoc.parse(jsonEncode(named), station),
        throwsFormatException,
      );
      final duplicateRank = copy();
      duplicateRank['stations']['tokyo']['facilities']['features'][1]['properties']['rank'] =
          0;
      expect(
        () => MapHintsPoc.parse(jsonEncode(duplicateRank), station),
        throwsFormatException,
      );
      final unverified = copy();
      unverified['stations']['tokyo']['routes']['features'][0]['properties']['serviceId'] =
          'unreviewed';
      expect(
        () => MapHintsPoc.parse(jsonEncode(unverified), station),
        throwsFormatException,
      );
      final recoloured = copy();
      recoloured['stations']['tokyo']['routes']['features'][0]['properties']['color'] =
          '#FFFFFF';
      expect(
        () => MapHintsPoc.parse(jsonEncode(recoloured), station),
        throwsFormatException,
      );
    },
  );
  testWidgets('all six facility types have locally generated icons', (
    tester,
  ) async {
    final images = await tester.runAsync(facilityIconImages);
    expect(
      images!.keys.toSet(),
      facilityKinds.map((k) => 'facility-$k').toSet(),
    );
    expect(images.values.every((bytes) => bytes.length > 100), true);
  });
}
