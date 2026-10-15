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
final highSpeedProof =
    jsonDecode(
          File(
            'docs/map-hints-poc/high-speed-rail-audit.json',
          ).readAsStringSync(),
        )
        as Map;
final highSpeedOsmEvidence =
    jsonDecode(
          File(
            'docs/map-hints-poc/high-speed-rail-osm-evidence.json',
          ).readAsStringSync(),
        )
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
const expectedHighSpeedNames = {
  'tokyo': {'東海道新幹線', '東北新幹線'},
  'ueno': {'東北新幹線'},
  'kyoto': {'東海道新幹線'},
};
const expectedHighSpeedFeatureCounts = {'tokyo': 4, 'ueno': 2, 'kyoto': 2};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reviewed Shinkansen lines match independent OSM evidence', () {
    expect(
      highSpeedProof['provenance']['attribution'],
      contains('OpenStreetMap'),
    );
    expect(highSpeedProof['provenance']['license'], 'ODbL-1.0');
    expect(highSpeedProof['provenance']['selectionRule'], {
      'stationSpecificReviewedNames': true,
      'maxStationDistanceMeters': highSpeedRailMaxDistanceMeters.toInt(),
    });
    expect(highSpeedProof['provenance']['requiredWayTags'], {
      'railway': 'rail',
      'highspeed': 'yes',
      'usage': 'main',
      'service': null,
      'gauge': '1435',
    });
    expect(
      highSpeedOsmEvidence['provenance']['attribution'],
      contains('OpenStreetMap'),
    );
    expect(highSpeedOsmEvidence['provenance']['license'], 'ODbL-1.0');
    final evidenceWays = {
      for (final way in highSpeedOsmEvidence['ways']) way['id']: way,
    };
    final evidenceRelations = {
      for (final relation in highSpeedOsmEvidence['relations'])
        relation['id']: relation,
    };
    final referencedWayIds = <dynamic>{};
    final referencedRelationIds = <dynamic>{};
    for (final station in stations.where(
      (station) => mapHintsPocStationIds.contains(station.id),
    )) {
      final audit = highSpeedProof['stations'][station.id] as Map;
      expect(audit['stationCenter'], [station.longitude, station.latitude]);
      final sourceRecord = proof['stations'][station.id] as Map;
      final rawSource = audit['rawSource'] as Map;
      expect(
        rawSource['name'],
        sourceRecord['sourceFiles']['overpass']['name'],
      );
      expect(
        rawSource['sha256'],
        sourceRecord['sourceFiles']['overpass']['sha256'],
      );
      expect(
        rawSource['queryName'],
        sourceRecord['sourceFiles']['query']['name'],
      );
      expect(
        rawSource['querySha256'],
        sourceRecord['sourceFiles']['query']['sha256'],
      );
      expect(rawSource['osmBaseTimestamp'], sourceRecord['osmBaseTimestamp']);
      final evidenceSource = (highSpeedOsmEvidence['sources'] as List)
          .singleWhere((source) => source['name'] == rawSource['name']);
      expect(evidenceSource['sha256'], rawSource['sha256']);
      expect(evidenceSource['osmBaseTimestamp'], rawSource['osmBaseTimestamp']);

      final railwayFeatures =
          hintData[station.id]['railways']['features'] as List;
      final auditedLines = audit['lines'] as List;
      expect(
        auditedLines,
        hasLength(expectedHighSpeedFeatureCounts[station.id]!),
      );
      expect(
        auditedLines.map((line) => line['lineId']).toSet(),
        hasLength(auditedLines.length),
      );
      for (final line in auditedLines) {
        final evidenceWayIds = (line['evidenceWayIds'] as List).toSet();
        referencedWayIds.addAll(evidenceWayIds);
        referencedRelationIds.add(line['supportingRelationId']);
        final matches = railwayFeatures.where((feature) {
          final properties = feature['properties'] as Map;
          return properties['name'] == line['expectedName'] &&
              (properties['osm_way_ids'] as List).toSet().containsAll(
                evidenceWayIds,
              );
        }).toList();
        expect(matches, hasLength(1), reason: line['lineId'] as String);
        expect(
          expectedHighSpeedNames[station.id],
          contains(line['expectedName']),
        );
        final featureCoordinates =
            matches.single['geometry']['coordinates'] as List;
        final featureEdges = <String>{};
        for (var i = 1; i < featureCoordinates.length; i++) {
          featureEdges.add(
            jsonEncode([featureCoordinates[i - 1], featureCoordinates[i]]),
          );
          featureEdges.add(
            jsonEncode([featureCoordinates[i], featureCoordinates[i - 1]]),
          );
        }
        final rawPoints = <dynamic>[];
        for (final wayId in evidenceWayIds) {
          final way = evidenceWays[wayId] as Map;
          expect(way['type'], 'way');
          final tags = way['tags'] as Map;
          expect(tags['name'], line['expectedName']);
          expect(tags['railway'], 'rail');
          expect(tags['highspeed'], 'yes');
          expect(tags['usage'], 'main');
          expect(tags['gauge'], '1435');
          expect(tags.containsKey('service'), false);
          final geometry = way['geometry'] as List;
          rawPoints.addAll(geometry);
          for (var i = 1; i < geometry.length; i++) {
            final edge = jsonEncode([
              [geometry[i - 1]['lon'], geometry[i - 1]['lat']],
              [geometry[i]['lon'], geometry[i]['lat']],
            ]);
            expect(featureEdges, contains(edge), reason: 'way $wayId');
          }
        }
        final relation = evidenceRelations[line['supportingRelationId']] as Map;
        expect(relation['type'], 'relation');
        expect(relation['tags']['type'], 'route');
        expect(relation['tags']['route'], 'train');
        final memberWayIds = (relation['members'] as List)
            .where((member) => member['type'] == 'way')
            .map((member) => member['ref'])
            .toSet();
        expect(memberWayIds.containsAll(evidenceWayIds), true);

        final distances = rawPoints.map((point) {
          final dx =
              ((point['lon'] as num) - station.longitude) *
              cos(station.latitude * pi / 180) *
              111320;
          final dy = ((point['lat'] as num) - station.latitude) * 111320;
          return sqrt(dx * dx + dy * dy);
        });
        final minimumDistance = distances.reduce(min);
        expect(
          minimumDistance,
          closeTo(line['observedMinimumDistanceMeters'] as num, 0.11),
        );
        expect(
          minimumDistance,
          lessThanOrEqualTo(highSpeedRailMaxDistanceMeters),
        );
        expect(line['supportingRelationId'], isA<int>());
      }
    }
    expect(evidenceWays.keys.toSet(), referencedWayIds);
    expect(evidenceRelations.keys.toSet(), referencedRelationIds);
  });
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
          expect(
            (style['sources'] as Map).containsKey('high-speed-railways'),
            false,
          );
          final layers = style['layers'] as List;
          expect(layers.any((l) => l['id'] == 'poc-facility-icons'), false);
          expect(layers.any((l) => l['id'] == 'high-speed-rail'), false);
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
            railways: hintData[station.id]['railways'],
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
          final highSpeedSource =
              (style['sources']
                      as Map)['high-speed-railways']['data']['features']
                  as List;
          final originalHighSpeed =
              (hintData[station.id]['railways']['features'] as List)
                  .where(
                    (feature) => expectedHighSpeedNames[station.id]!.contains(
                      feature['properties']['name'] as String,
                    ),
                  )
                  .toList();
          expect(
            originalHighSpeed
                .map((feature) => feature['properties']['name'])
                .toSet(),
            expectedHighSpeedNames[station.id],
          );
          for (final feature
              in hintData[station.id]['railways']['features'] as List) {
            final name = feature['properties']['name'] as String;
            expect(
              isHighSpeedRailwayLabel(station, name),
              expectedHighSpeedNames[station.id]!.contains(name),
            );
          }
          expect(
            highSpeedSource,
            hasLength(expectedHighSpeedFeatureCounts[station.id]!),
          );
          expect(highSpeedSource, hasLength(originalHighSpeed.length));
          for (final feature in highSpeedSource) {
            expect(feature['properties'], {'railType': 'highSpeed'});
            expect(
              originalHighSpeed.map((item) => item['geometry']),
              contains(feature['geometry']),
            );
          }
          final casingIndex = layers.indexWhere(
            (layer) => layer['id'] == 'high-speed-rail-casing',
          );
          final highSpeedIndex = layers.indexWhere(
            (layer) => layer['id'] == 'high-speed-rail',
          );
          final routeColourIndex = layers.indexWhere(
            (layer) => layer['id'] == 'named-railway-colors',
          );
          expect(
            casingIndex,
            greaterThan(layers.indexWhere((l) => l['id'] == 'rail-sleepers')),
          );
          expect(highSpeedIndex, casingIndex + 1);
          expect(routeColourIndex, greaterThan(highSpeedIndex));
          final casing = layers[casingIndex];
          final highSpeed = layers[highSpeedIndex];
          expect(casing['paint']['line-color'], '#f7f3fa');
          expect(casing['paint']['line-width'], [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            2.8,
            18,
            5.4,
          ]);
          expect(highSpeed['paint']['line-color'], '#6f6686');
          expect(highSpeed['paint']['line-width'], [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            1.6,
            18,
            3.4,
          ]);
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
