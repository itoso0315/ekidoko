import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/map/facility_icons.dart';
import 'package:ekidoko/map/map_hints_poc.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/catalog.dart';

const tiles = {
  'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
};

final source = File('assets/maps/map_hints_poc.json').readAsStringSync();
final data = jsonDecode(source) as Map<String, dynamic>;
final hintData =
    jsonDecode(File('assets/maps/station_hints.json').readAsStringSync())
        as Map<String, dynamic>;

List<dynamic> features(Map<String, dynamic> collection) =>
    collection['features'] as List<dynamic>;

Map<String, dynamic> layer(Map<String, dynamic> style, String id) =>
    Map<String, dynamic>.from(
      (style['layers'] as List<dynamic>).singleWhere(
            (item) => (item as Map)['id'] == id,
          )
          as Map,
    );

bool hasLayer(Map<String, dynamic> style, String id) =>
    (style['layers'] as List<dynamic>).any((item) => (item as Map)['id'] == id);

double distanceMeters(double latitude, double longitude, List<dynamic> point) {
  final dx =
      ((point[0] as num).toDouble() - longitude) *
      cos(latitude * pi / 180) *
      111320;
  final dy = ((point[1] as num).toDouble() - latitude) * 111320;
  return sqrt(dx * dx + dy * dy);
}

Map<String, dynamic> cloneData() =>
    jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'schema v2 contains and loads exactly all 50 enabled stations',
    () async {
      expect(data['schemaVersion'], 2);
      expect(data['provenance'], isA<Map>());
      expect(data['services'], isA<Map>());
      final rows = data['stations'] as Map;
      expect(rows.keys.toSet(), stations.map((station) => station.id).toSet());
      expect(rows, hasLength(50));
      expect(stations.where((station) => station.easyEligible), hasLength(34));

      for (final station in stations) {
        final parsed = MapHintsPoc.parse(source, station);
        final loaded = await loadMapHintsPoc(station);
        expect(parsed.stationId, station.id);
        expect(loaded.stationId, station.id);
        expect(parsed.facilities['type'], 'FeatureCollection');
        expect(parsed.routes['type'], 'FeatureCollection');
        expect(parsed.highSpeedRailways['type'], 'FeatureCollection');
        expect(
          parsed.hasHighSpeedRailways,
          station.hasHighSpeedRailway,
          reason: station.id,
        );
        expect(parsed.representativeFacilities['type'], 'FeatureCollection');
      }
    },
  );

  test(
    'anonymous facility icons are real, name-free, unique and capped at five',
    () {
      for (final station in stations) {
        final parsed = MapHintsPoc.parse(source, station);
        final icons = features(parsed.facilities);
        expect(icons.length, lessThanOrEqualTo(5), reason: station.id);
        final objectIds = <String>{};
        final ranks = <int>{};
        for (final feature in icons) {
          final properties = feature['properties'] as Map;
          expect(
            properties.keys,
            unorderedEquals(['kind', 'rank', 'osm_type', 'osm_id']),
            reason: station.id,
          );
          expect(facilityKinds, contains(properties['kind']));
          expect(
            objectIds.add('${properties['osm_type']}/${properties['osm_id']}'),
            true,
            reason: station.id,
          );
          expect(
            ranks.add(properties['rank'] as int),
            true,
            reason: station.id,
          );
          expect(
            distanceMeters(
              station.latitude,
              station.longitude,
              feature['geometry']['coordinates'] as List<dynamic>,
            ),
            lessThanOrEqualTo(501),
            reason: '${station.id}: facility must be inside the 500 m rule',
          );
        }
      }
    },
  );

  test(
    'representative names are safe, real-positioned and capped at three',
    () {
      for (final station in stations) {
        final parsed = MapHintsPoc.parse(source, station);
        final representatives = features(parsed.representativeFacilities);
        expect(
          representatives.length,
          lessThanOrEqualTo(3),
          reason: station.id,
        );
        for (final feature in representatives) {
          final properties = feature['properties'] as Map;
          expect(
            properties.keys,
            unorderedEquals(['kind', 'name', 'rank', 'osm_type', 'osm_id']),
            reason: station.id,
          );
          expect(properties['kind'], 'facility');
          expect(
            isSafeHintLabel(station, properties['name'] as String),
            true,
            reason: '${station.id}: ${properties['name']}',
          );
          expect(
            distanceMeters(
              station.latitude,
              station.longitude,
              feature['geometry']['coordinates'] as List<dynamic>,
            ),
            lessThanOrEqualTo(2501),
            reason: station.id,
          );
        }
      }
    },
  );

  test('only relation-backed strict colours are accepted and rendered', () {
    final services = data['services'] as Map;
    final referencedServices = <String>{};
    for (final station in stations) {
      final parsed = MapHintsPoc.parse(source, station);
      for (final feature in features(parsed.routes)) {
        final properties = feature['properties'] as Map;
        final serviceId = properties['serviceId'] as String;
        referencedServices.add(serviceId);
        final service = services[serviceId] as Map;
        expect(properties['name'], service['name']);
        expect(properties['color'], service['color']);
        expect(properties['color'], matches(RegExp(r'^#[0-9A-Fa-f]{6}$')));
        expect(properties['osm_way_ids'], isNotEmpty);
        expect(properties['osm_relation_ids'], isNotEmpty);
        expect(
          (properties['osm_relation_ids'] as List).every(
            (id) => (service['relationIds'] as List).contains(id),
          ),
          true,
          reason: station.id,
        );
      }
    }
    expect(services.keys.toSet(), referencedServices);
  });

  test(
    'high-speed features are name-free and use only audited OSM way IDs',
    () {
      var stationsWithHighSpeed = 0;
      var stationsWithoutHighSpeed = 0;
      for (final station in stations) {
        final parsed = MapHintsPoc.parse(source, station);
        final highSpeed = features(parsed.highSpeedRailways);
        if (highSpeed.isEmpty) {
          stationsWithoutHighSpeed++;
        } else {
          stationsWithHighSpeed++;
        }
        for (final feature in highSpeed) {
          final properties = feature['properties'] as Map;
          expect(
            properties.keys,
            unorderedEquals(['railType', 'osm_way_ids']),
            reason: station.id,
          );
          expect(properties['railType'], 'highSpeed');
          expect(properties['osm_way_ids'], isNotEmpty);
          expect(jsonEncode(properties).toLowerCase(), isNot(contains('name')));
        }
      }
      expect(stationsWithHighSpeed, greaterThan(0));
      expect(stationsWithoutHighSpeed, greaterThan(0));
    },
  );

  test('all four stages expose only their specified layers', () {
    for (final station in stations) {
      final parsed = MapHintsPoc.parse(source, station);
      for (var hint = 0; hint < 4; hint++) {
        final style = quizMapStyle(
          station,
          tiles,
          hint: hint,
          railways: Map<String, dynamic>.from(
            (hintData[station.id] as Map)['railways'] as Map,
          ),
          hintLabels: Map<String, dynamic>.from(
            (hintData[station.id] as Map)['labels'] as Map,
          ),
          poc: parsed,
        );
        final sources = style['sources'] as Map;
        expect(sources.containsKey('poc-facilities'), parsed.hasFacilities);
        expect(sources.containsKey('verified-routes'), parsed.hasRoutes);
        expect(
          sources.containsKey('high-speed-railways'),
          parsed.hasHighSpeedRailways,
        );
        expect(hasLayer(style, 'poc-facility-icons'), parsed.hasFacilities);
        expect(hasLayer(style, 'verified-route-colors'), parsed.hasRoutes);
        expect(hasLayer(style, 'high-speed-rail'), parsed.hasHighSpeedRailways);
        expect(
          hasLayer(style, 'high-speed-rail-casing'),
          parsed.hasHighSpeedRailways,
        );

        expect(
          layer(style, 'railway-labels')['layout']['visibility'],
          hint >= 2 ? 'visible' : 'none',
        );
        expect(
          layer(style, 'hint-places')['layout']['visibility'],
          hint == 3 ? 'visible' : 'none',
        );
        expect(
          layer(style, 'hint-facilities')['layout']['visibility'],
          hint == 3 ? 'visible' : 'none',
        );
        final layerIds = (style['layers'] as List<dynamic>)
            .map((item) => (item as Map)['id'] as String)
            .toList();
        expect(
          layerIds.indexOf('railway-labels'),
          lessThan(layerIds.indexOf('hint-facilities')),
          reason: '${station.id}: representative labels need visual priority',
        );
        final representativeLayout =
            layer(style, 'hint-facilities')['layout'] as Map;
        expect(representativeLayout['text-allow-overlap'], true);
        expect(representativeLayout['text-ignore-placement'], true);
        if (parsed.hasRoutes) {
          expect(
            layer(style, 'verified-route-colors')['layout']['visibility'],
            hint >= 1 ? 'visible' : 'none',
          );
          final runtimeFeatures =
              ((sources['verified-routes'] as Map)['data'] as Map)['features']
                  as List;
          for (final feature in runtimeFeatures) {
            expect(
              (feature['properties'] as Map).keys,
              unorderedEquals(['color', 'lineOffset']),
            );
          }
        }
        if (parsed.hasFacilities) {
          final icon = layer(style, 'poc-facility-icons');
          expect(icon['layout']['visibility'], 'none');
          expect(icon['layout'].containsKey('text-field'), false);
          expect(icon['layout']['icon-size'], hint == 2 ? 1.125 : 1.5);
        }

        final reviewed =
            ((sources['reviewed-hints'] as Map)['data'] as Map)['features']
                as List;
        for (final feature in reviewed) {
          final name = feature['properties']['name'] as String;
          expect(isSafeHintLabel(station, name), true, reason: station.id);
        }
      }
    }
  });

  test('anonymous icons have no H3 text fallback', () {
    for (final station in stations) {
      final parsed = MapHintsPoc.parse(source, station);
      final style = quizMapStyle(
        station,
        tiles,
        hint: 3,
        railways: Map<String, dynamic>.from(
          (hintData[station.id] as Map)['railways'] as Map,
        ),
        hintLabels: Map<String, dynamic>.from(
          (hintData[station.id] as Map)['labels'] as Map,
        ),
        poc: parsed,
      );
      final reviewed =
          (((style['sources'] as Map)['reviewed-hints'] as Map)['data']
                  as Map)['features']
              as List;
      final representativeIds = features(parsed.representativeFacilities)
          .map(
            (feature) =>
                '${feature['properties']['osm_type']}/'
                '${feature['properties']['osm_id']}',
          )
          .toSet();
      final renderedFacilities = reviewed.where(
        (feature) => feature['properties']['kind'] == 'facility',
      );
      expect(
        renderedFacilities.map(
          (feature) =>
              '${feature['properties']['osm_type']}/'
              '${feature['properties']['osm_id']}',
        ),
        unorderedEquals(representativeIds),
        reason: station.id,
      );
    }
  });

  test('high-speed casing and purple rail stay above conventional colours', () {
    var checked = 0;
    for (final station in stations) {
      final parsed = MapHintsPoc.parse(source, station);
      if (!parsed.hasRoutes || !parsed.hasHighSpeedRailways) continue;
      final style = quizMapStyle(
        station,
        tiles,
        hint: 1,
        railways: Map<String, dynamic>.from(
          (hintData[station.id] as Map)['railways'] as Map,
        ),
        hintLabels: Map<String, dynamic>.from(
          (hintData[station.id] as Map)['labels'] as Map,
        ),
        poc: parsed,
      );
      final ids = (style['layers'] as List)
          .map((item) => item['id'] as String)
          .toList();
      expect(
        ids.indexOf('verified-route-colors'),
        lessThan(ids.indexOf('high-speed-rail-casing')),
        reason: station.id,
      );
      expect(
        ids.indexOf('high-speed-rail-casing'),
        lessThan(ids.indexOf('high-speed-rail')),
        reason: station.id,
      );
      checked++;
    }
    expect(checked, greaterThan(0));
  });

  test('parser rejects invented or leaking capability data', () {
    final station = stations.first;

    final tooManyIcons = cloneData();
    final iconList =
        tooManyIcons['stations'][station.id]['facilities']['features'] as List;
    if (iconList.isEmpty) {
      iconList.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [station.longitude, station.latitude],
        },
        'properties': {
          'kind': 'culture',
          'rank': 0,
          'osm_type': 'node',
          'osm_id': 1,
        },
      });
    }
    final template = jsonDecode(jsonEncode(iconList.first));
    while (iconList.length < 6) {
      final copy = jsonDecode(jsonEncode(template));
      copy['properties']['rank'] = iconList.length;
      copy['properties']['osm_id'] = 900000000 + iconList.length;
      iconList.add(copy);
    }
    expect(
      () => MapHintsPoc.fromDecoded(tooManyIcons, station),
      throwsFormatException,
    );

    final leakingIcon = cloneData();
    final leakList =
        leakingIcon['stations'][station.id]['facilities']['features'] as List;
    if (leakList.isEmpty) leakList.add(template);
    leakList.first['properties']['name'] = station.name;
    expect(
      () => MapHintsPoc.fromDecoded(leakingIcon, station),
      throwsFormatException,
    );

    final inventedHighSpeed = cloneData();
    inventedHighSpeed['stations'][station.id]['highSpeedRailways']['features'] =
        [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                [station.longitude, station.latitude],
                [station.longitude + .001, station.latitude],
              ],
            },
            'properties': {'railType': 'highSpeed', 'osm_way_ids': []},
          },
        ];
    expect(
      () => MapHintsPoc.fromDecoded(inventedHighSpeed, station),
      throwsFormatException,
    );
  });

  test('existing game pools, scoring and question count stay unchanged', () {
    expect(Game.points, [100, 70, 40, 10]);
    expect(catalog.select(), hasLength(50));
    expect(
      catalog.select().where((station) => station.easyEligible),
      hasLength(34),
    );
    for (final difficulty in GameDifficulty.values) {
      final game = Game(catalog: catalog, random: Random(7))
        ..selectDifficulty(difficulty)
        ..start();
      expect(game.questions, hasLength(10));
      expect(
        game.questions.map((station) => station.id).toSet(),
        hasLength(10),
      );
      expect(
        game.questions.every(
          (station) =>
              difficulty == GameDifficulty.hard || station.easyEligible,
        ),
        true,
      );
      game.dispose();
    }
  });

  test('six facility icons remain available', () async {
    final images = await facilityIconImages();
    expect(images.keys, {for (final kind in facilityKinds) 'facility-$kind'});
    expect(images.values.every((bytes) => bytes.length > 100), true);
  });
}
