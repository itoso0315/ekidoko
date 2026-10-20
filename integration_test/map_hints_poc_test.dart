import 'dart:io';
import 'dart:math';

import 'package:ekidoko/main.dart';
import 'package:ekidoko/map/map_hints_poc.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:ekidoko/map/real_station_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const stationIds = [
  'tokyo',
  'shinjuku',
  'shibuya',
  'shinagawa',
  'ueno',
  'ikebukuro',
  'nagoya',
  'osaka',
  'kyoto',
  'yokohama',
  'sapporo',
  'sendai',
  'omiya',
  'kanazawa',
  'shizuoka',
  'shin_osaka',
  'sannomiya',
  'hiroshima',
  'takamatsu',
  'hakata',
  'hakodate',
  'asahikawa',
  'morioka',
  'kita_senju',
  'akihabara',
  'tachikawa',
  'kawasaki',
  'chiba',
  'funabashi',
  'kashiwa',
  'kanayama',
  'chikusa',
  'gifu',
  'hamamatsu',
  'nagano',
  'niigata',
  'tennoji',
  'kyobashi_osaka',
  'namba_nankai',
  'nara',
  'kobe_jr',
  'okayama',
  'fukuyama',
  'matsue',
  'tokushima',
  'kochi',
  'kokura',
  'kumamoto',
  'kagoshima_chuo',
  'kurume',
];

bool _pointIsInBounds(List<dynamic> point, LatLngBounds bounds) {
  final longitude = (point[0] as num).toDouble();
  final latitude = (point[1] as num).toDouble();
  return longitude >= bounds.southwest.longitude &&
      longitude <= bounds.northeast.longitude &&
      latitude >= bounds.southwest.latitude &&
      latitude <= bounds.northeast.latitude;
}

bool _segmentIntersectsBounds(
  List<dynamic> start,
  List<dynamic> end,
  LatLngBounds bounds,
) {
  final x0 = (start[0] as num).toDouble();
  final y0 = (start[1] as num).toDouble();
  final dx = (end[0] as num).toDouble() - x0;
  final dy = (end[1] as num).toDouble() - y0;
  var minimum = 0.0;
  var maximum = 1.0;

  bool clip(double direction, double distance) {
    if (direction == 0) return distance >= 0;
    final ratio = distance / direction;
    if (direction < 0) {
      if (ratio > maximum) return false;
      minimum = max(minimum, ratio);
    } else {
      if (ratio < minimum) return false;
      maximum = min(maximum, ratio);
    }
    return true;
  }

  return clip(-dx, x0 - bounds.southwest.longitude) &&
      clip(dx, bounds.northeast.longitude - x0) &&
      clip(-dy, y0 - bounds.southwest.latitude) &&
      clip(dy, bounds.northeast.latitude - y0);
}

bool _linesIntersectBounds(
  Map<String, dynamic> collection,
  LatLngBounds bounds,
) {
  for (final feature in collection['features'] as List<dynamic>) {
    final coordinates = feature['geometry']['coordinates'] as List<dynamic>;
    if (coordinates.any((point) => _pointIsInBounds(point as List, bounds))) {
      return true;
    }
    for (var index = 1; index < coordinates.length; index++) {
      if (_segmentIntersectsBounds(
        coordinates[index - 1] as List,
        coordinates[index] as List,
        bounds,
      )) {
        return true;
      }
    }
  }
  return false;
}

String? _osmObjectKey(Map<dynamic, dynamic> properties) {
  final type = properties['osm_type'];
  if (!const {'node', 'way', 'relation'}.contains(type)) return null;
  final rawId = properties['osm_id'];
  int? id;
  if (rawId is num &&
      rawId.isFinite &&
      rawId > 0 &&
      rawId == rawId.roundToDouble()) {
    id = rawId.toInt();
  } else if (rawId is String) {
    id = int.tryParse(rawId);
  }
  return id == null || id <= 0 ? null : '$type/$id';
}

Map<String, dynamic> _representativeRecord(Map<dynamic, dynamic> properties) {
  final name = properties['name'];
  final osmKey = _osmObjectKey(properties);
  return {
    'key': osmKey ?? (name is String ? 'name:${name.trim()}' : null),
    'osmType': properties['osm_type'],
    'osmId': properties['osm_id'],
    'name': name,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const saveScreenshots = bool.fromEnvironment(
    'EKIDOKO_CAPTURE',
    defaultValue: true,
  );
  final records = <Map<String, dynamic>>[];
  final failures = <Map<String, dynamic>>[];
  final completedStations = <String>[];
  final screenshotRoot =
      '${Directory.systemTemp.path}/ekidoko-map-hints-50stations';
  final quality = <String, dynamic>{
    'schemaVersion': 2,
    'scope': 'all 50 enabled stations, four hint stages',
    'expectedPatternCount': 200,
    'records': records,
    'failures': failures,
    'completedStations': completedStations,
    'completed': false,
    'manualReview': {
      'iconReadability': 'unconfirmed',
      'routeColourAccuracyAndReadability': 'unconfirmed',
      'highSpeedAlignment': 'unconfirmed',
      'labelClipping': 'unconfirmed',
      'semanticAnswerLeakage': 'unconfirmed',
    },
    'captureEnabled': saveScreenshots,
    'screenshotRoot': screenshotRoot,
  };
  binding.reportData ??= <String, dynamic>{};
  binding.reportData!['mapHints50Quality'] = quality;
  setUpAll(() async {
    final directory = Directory(screenshotRoot);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  for (final stationId in stationIds) {
    testWidgets('$stationId: four Phase 4 map stages render', (tester) async {
      var currentHint = 0;
      try {
        final catalog = await loadStationCatalog();
        expect(catalog.stations, hasLength(50));
        final station = catalog.stations.singleWhere((s) => s.id == stationId);
        final poc = await loadMapHintsPoc(station);
        final hint = ValueNotifier<int>(0);
        addTearDown(hint.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildEkidokoTheme(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Center(
                child: SizedBox.square(
                  dimension: 350,
                  child: ValueListenableBuilder<int>(
                    valueListenable: hint,
                    builder: (context, value, child) => RealStationMap(
                      key: ValueKey('phase4-map-$stationId'),
                      station: station,
                      hint: value,
                      reveal: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        Future<RealStationMapState> waitForMap() async {
          for (var i = 0; i < 300; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final finder = find.byType(RealStationMap);
            if (finder.evaluate().length != 1) continue;
            final state = tester.state<RealStationMapState>(finder);
            if (state.error != null) {
              fail(
                '${state.error} station:$stationId hint:$currentHint '
                'features:${state.renderedFeatureCounts}',
              );
            }
            if (state.ready) {
              await tester.pump(const Duration(milliseconds: 200));
              return state;
            }
          }
          fail('Actual map did not become ready: $stationId H$currentHint');
        }

        Future<List<Map<String, dynamic>>> rendered(
          MapLibreMapController controller,
          Rect rect,
          String layer,
        ) async {
          final result = await controller.queryRenderedFeaturesInRect(rect, [
            layer,
          ], null);
          return result
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
        }

        Map<String, dynamic> properties(Map<String, dynamic> feature) =>
            Map<String, dynamic>.from(feature['properties'] as Map);

        Future<void> capture(String stage) async {
          if (!saveScreenshots) return;
          await tester.pump(const Duration(milliseconds: 250));
          final bytes = await binding.takeScreenshot('$stationId-$stage');
          final file = File('$screenshotRoot/$stationId/$stage.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
          binding.reportData!.remove('screenshots');
        }

        final approvedColours = (poc.routes['features'] as List)
            .map((feature) => feature['properties']['color'])
            .whereType<String>()
            .toSet();
        Set<int>? initialIconIds;
        for (currentHint = 0; currentHint <= 3; currentHint++) {
          if (hint.value != currentHint) {
            hint.value = currentHint;
            await tester.pump();
          }
          final watch = Stopwatch()..start();
          final state = await waitForMap();
          final controller = state.controller!;
          final mapFinder = find.byType(RealStationMap);
          final size = tester.getSize(mapFinder);
          final rect = Offset.zero & size;
          final roads = await rendered(controller, rect, 'roads');
          final rails = await rendered(controller, rect, 'railways');
          final buildings = await rendered(controller, rect, 'buildings');
          final routeLabels = await rendered(
            controller,
            rect,
            'railway-labels',
          );
          final places = await rendered(controller, rect, 'hint-places');
          final namedFacilities = await rendered(
            controller,
            rect,
            'hint-facilities',
          );
          final icons = poc.hasFacilities
              ? await rendered(controller, rect, 'poc-facility-icons')
              : <Map<String, dynamic>>[];
          final routeLines = poc.hasRoutes
              ? await rendered(controller, rect, 'verified-route-colors')
              : <Map<String, dynamic>>[];
          final highSpeedRails = poc.hasHighSpeedRailways
              ? await rendered(controller, rect, 'high-speed-rail')
              : <Map<String, dynamic>>[];
          final highSpeedCasing = poc.hasHighSpeedRailways
              ? await rendered(controller, rect, 'high-speed-rail-casing')
              : <Map<String, dynamic>>[];
          final bounds = await controller.getVisibleRegion();
          final expectsIcons =
              currentHint < 3 &&
              poc.hasFacilities &&
              (poc.facilities['features'] as List).any(
                (feature) => _pointIsInBounds(
                  feature['geometry']['coordinates'] as List<dynamic>,
                  bounds,
                ),
              );
          final expectsRouteColours =
              currentHint >= 1 &&
              poc.hasRoutes &&
              _linesIntersectBounds(poc.routes, bounds);
          final expectsHighSpeed =
              poc.hasHighSpeedRailways &&
              _linesIntersectBounds(poc.highSpeedRailways, bounds);
          final expectedRepresentatives = currentHint == 3
              ? (poc.representativeFacilities['features'] as List)
                    .where(
                      (feature) => _pointIsInBounds(
                        feature['geometry']['coordinates'] as List<dynamic>,
                        bounds,
                      ),
                    )
                    .map(
                      (feature) =>
                          _representativeRecord(feature['properties'] as Map),
                    )
                    .toList()
              : <Map<String, dynamic>>[];
          final renderedRepresentatives = namedFacilities
              .map(properties)
              .map(_representativeRecord)
              .toList();
          final expectedRepresentativeKeys = expectedRepresentatives
              .map((item) => item['key'])
              .whereType<String>()
              .toSet();
          final renderedRepresentativeKeys = renderedRepresentatives
              .map((item) => item['key'])
              .whereType<String>()
              .toSet();

          expect(roads, isNotEmpty);
          expect(rails, isNotEmpty);
          if (currentHint < 2) expect(buildings, isNotEmpty);

          if (expectsHighSpeed) {
            expect(highSpeedRails, isNotEmpty, reason: stationId);
            expect(highSpeedCasing, isNotEmpty, reason: stationId);
            for (final feature in highSpeedRails) {
              final item = properties(feature);
              expect(item['railType'], 'highSpeed');
              expect(
                item.keys.where(
                  (key) => key.toString().toLowerCase().contains('name'),
                ),
                isEmpty,
              );
            }
          } else if (!poc.hasHighSpeedRailways) {
            expect(
              state.renderedFeatureCounts.containsKey('highSpeedRails'),
              false,
            );
          }

          final iconProperties = icons.map(properties).toList();
          final iconIds = iconProperties
              .map((item) => item['osm_id'])
              .whereType<num>()
              .map((id) => id.toInt())
              .toSet();
          if (expectsIcons) {
            expect(icons, isNotEmpty, reason: '$stationId H$currentHint');
            initialIconIds ??= iconIds;
          }
          if (initialIconIds != null && currentHint < 3) {
            expect(iconIds.containsAll(initialIconIds), true);
          }
          if (currentHint == 3) {
            expect(
              icons,
              isEmpty,
              reason: 'anonymous facility icons must be hidden at H3',
            );
          }
          expect(iconIds.length, lessThanOrEqualTo(5));
          for (final item in iconProperties) {
            expect(
              item.keys.where(
                (key) => key.toString().toLowerCase().contains('name'),
              ),
              isEmpty,
              reason: '$stationId leaked an anonymous facility name',
            );
          }

          final renderedColours = routeLines
              .map(properties)
              .map((item) => item['color'])
              .whereType<String>()
              .toSet();
          if (currentHint == 0) {
            expect(routeLines, isEmpty);
          }
          if (expectsRouteColours) {
            expect(routeLines, isNotEmpty, reason: '$stationId H$currentHint');
            expect(renderedColours.difference(approvedColours), isEmpty);
          }

          final routeNames = routeLabels
              .map(properties)
              .map((item) => item['name'])
              .whereType<String>()
              .toSet();
          if (currentHint < 2) {
            expect(routeLabels, isEmpty);
          } else {
            expect(routeLabels, isNotEmpty);
            for (final name in routeNames) {
              expect(
                isUsefulRailwayLabel(station, name),
                true,
                reason: '$stationId: $name',
              );
            }
          }
          if (currentHint < 3) {
            expect(places, isEmpty);
            expect(namedFacilities, isEmpty);
            expect(state.expectedRepresentativeKeys, isEmpty);
            expect(state.renderedRepresentativeKeys, isEmpty);
            expect(state.missingRepresentativeKeys, isEmpty);
          } else {
            expect([...places, ...namedFacilities], isNotEmpty);
            expect(namedFacilities.length, lessThanOrEqualTo(3));
            if (!poc.hasRepresentativeFacilities) {
              expect(namedFacilities, isEmpty);
            }
            for (final feature in [...places, ...namedFacilities]) {
              final item = properties(feature);
              final name = item['name:ja'] ?? item['name'];
              expect(name, isA<String>());
              expect(
                isSafeHintLabel(station, name as String),
                true,
                reason: '$stationId: $name',
              );
            }
            expect(
              state.expectedRepresentativeKeys,
              expectedRepresentativeKeys,
              reason: '$stationId expected representative contract',
            );
            expect(
              state.renderedRepresentativeKeys,
              renderedRepresentativeKeys,
              reason: '$stationId rendered representative contract',
            );
            expect(state.missingRepresentativeKeys, isEmpty);
            expect(
              state.renderedFeatureCounts['expectedRepresentativeLabels'],
              expectedRepresentativeKeys.length,
            );
            expect(
              state.renderedFeatureCounts['matchedRepresentativeLabels'],
              expectedRepresentativeKeys.length,
              reason: 'generic place labels cannot replace representatives',
            );
            expect(
              state.renderedFeatureCounts['missingRepresentativeLabels'],
              0,
            );
          }

          final camera = controller.cameraPosition!;
          expect(camera.target.latitude, closeTo(station.latitude, .000001));
          expect(camera.target.longitude, closeTo(station.longitude, .000001));
          expect(camera.bearing, closeTo(0, .001));
          expect(camera.tilt, closeTo(0, .001));
          expect(
            camera.zoom,
            closeTo(
              quizZoom(
                station.latitude,
                min(size.width, size.height),
                currentHint,
              ),
              .001,
            ),
          );
          expect(
            find.text('© OpenMapTiles · © OpenStreetMap contributors'),
            findsOneWidget,
          );
          expect(
            find.text('白縁の紫線＝新幹線'),
            currentHint == 0 && highSpeedRails.isNotEmpty
                ? findsOneWidget
                : findsNothing,
          );
          expect(find.text('${station.name}駅'), findsNothing);

          if (currentHint == 0) {
            final before = camera;
            await tester.drag(mapFinder, const Offset(70, 45));
            await tester.tap(mapFinder);
            await tester.pump(const Duration(milliseconds: 500));
            final after = controller.cameraPosition!;
            expect(
              after.target.latitude,
              closeTo(before.target.latitude, .000001),
            );
            expect(
              after.target.longitude,
              closeTo(before.target.longitude, .000001),
            );
            expect(after.zoom, closeTo(before.zoom, .0001));
          }

          final stage = ['initial', 'hint1', 'hint2', 'hint3'][currentHint];
          await capture(stage);
          records.add({
            'stationId': stationId,
            'hint': currentHint,
            'stage': stage,
            'elapsedMs': watch.elapsedMilliseconds,
            'zoom': camera.zoom,
            'center': [camera.target.longitude, camera.target.latitude],
            'roads': roads.length,
            'baseRailFeatureCount': rails.length,
            'buildingFeatureCount': buildings.length,
            'buildingVerification': currentHint < 2
                ? 'machine-confirmed-rendered-feature'
                : 'manual-required-vector-tile-zoom-limit',
            'facilityIconCount': icons.length,
            'verifiedRouteColourCount': routeLines.length,
            'routeNames': routeNames.toList()..sort(),
            'placeNameCount': places.length,
            'representativeFacilityNameCount': namedFacilities.length,
            'representativeLabels': namedFacilities.length,
            'expectedRepresentativeLabels':
                state.renderedFeatureCounts['expectedRepresentativeLabels'] ??
                0,
            'matchedRepresentativeLabels':
                state.renderedFeatureCounts['matchedRepresentativeLabels'] ?? 0,
            'missingRepresentativeLabels':
                state.renderedFeatureCounts['missingRepresentativeLabels'] ?? 0,
            'expectedRepresentativeKeys':
                state.expectedRepresentativeKeys.toList()..sort(),
            'renderedRepresentativeKeys':
                state.renderedRepresentativeKeys.toList()..sort(),
            'renderedRepresentativeObjects': renderedRepresentatives,
            'visibleBounds': {
              'west': bounds.southwest.longitude,
              'south': bounds.southwest.latitude,
              'east': bounds.northeast.longitude,
              'north': bounds.northeast.latitude,
            },
            'highSpeedRailFeatureCount': highSpeedRails.length,
            'highSpeedRailCasingFeatureCount': highSpeedCasing.length,
            'expectsFacilityIconsInViewport': expectsIcons,
            'expectsRouteColorsInViewport': expectsRouteColours,
            'expectsHighSpeedInViewport': expectsHighSpeed,
            'capabilities': {
              'facilities': poc.hasFacilities,
              'routes': poc.hasRoutes,
              'highSpeedRailways': poc.hasHighSpeedRailways,
              'representativeFacilities': poc.hasRepresentativeFacilities,
            },
          });
        }
        completedStations.add(stationId);
        quality['completed'] =
            completedStations.length == stationIds.length &&
            records.length == stationIds.length * 4;
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      } catch (error, stackTrace) {
        failures.add({
          'stationId': stationId,
          'hint': currentHint,
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        });
        rethrow;
      }
    });
  }
}
