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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final records = <Map<String, dynamic>>[];
  final failures = <Map<String, dynamic>>[];
  final completedStations = <String>[];
  final screenshotRoot = '${Directory.systemTemp.path}/ekidoko-map-hints-poc';
  final quality = <String, dynamic>{
    'scope': 'Tokyo, Ueno and Kyoto only',
    'records': records,
    'failures': failures,
    'completedStations': completedStations,
    'completed': false,
    'manualReview': {
      'gameDifficulty': 'unconfirmed',
      'iconReadability': 'unconfirmed',
      'routeColourReadability': 'unconfirmed',
    },
    'screenshotRoot': screenshotRoot,
  };
  binding.reportData ??= <String, dynamic>{};
  binding.reportData!['mapHintsPocQuality'] = quality;

  for (final stationId in ['tokyo', 'ueno', 'kyoto']) {
    testWidgets('$stationId: four PoC map stages render from reviewed data', (
      tester,
    ) async {
      var currentHint = 0;
      try {
        final catalog = await loadStationCatalog();
        final station = catalog.stations.singleWhere((s) => s.id == stationId);
        final poc = await loadMapHintsPoc(station);
        expect(poc, isNotNull);
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
                      key: ValueKey('poc-map-$stationId'),
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
          for (var i = 0; i < 200; i++) {
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
          fail('Actual map did not become ready: $stationId hint:$currentHint');
        }

        Future<List<Map<String, dynamic>>> features(
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
          await tester.pump(const Duration(milliseconds: 250));
          final bytes = await binding.takeScreenshot('$stationId-$stage');
          final file = File('$screenshotRoot/$stationId/$stage.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes);
          // Keep the VM service response small; the host driver copies these
          // twelve files from the simulator's temporary container.
          binding.reportData!.remove('screenshots');
        }

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
          final roads = await features(controller, rect, 'roads');
          final rails = await features(controller, rect, 'railways');
          final buildings = await features(controller, rect, 'buildings');
          final routeLines = await features(
            controller,
            rect,
            'named-railway-colors',
          );
          final routeLabels = await features(
            controller,
            rect,
            'railway-labels',
          );
          final places = await features(controller, rect, 'hint-places');
          final namedFacilities = await features(
            controller,
            rect,
            'hint-facilities',
          );
          final icons = await features(controller, rect, 'poc-facility-icons');
          final iconProperties = icons.map(properties).toList();
          final iconIds = iconProperties
              .map((item) => item['osm_id'])
              .whereType<num>()
              .map((id) => id.toInt())
              .toSet();
          final iconKinds = iconProperties
              .map((item) => item['kind'])
              .whereType<String>()
              .toSet();
          final colours = routeLines
              .map(properties)
              .map((item) => item['color'])
              .whereType<String>()
              .toSet();
          final routeNames = routeLabels
              .map(properties)
              .map((item) => item['name'])
              .whereType<String>()
              .toSet();
          final approvedColours = (poc!.routes['features'] as List)
              .map((feature) => feature['properties']['color'])
              .whereType<String>()
              .toSet();
          final approvedNames = (poc.routes['features'] as List)
              .map((feature) => feature['properties']['name'])
              .whereType<String>()
              .toSet();

          expect(roads, isNotEmpty);
          expect(rails, isNotEmpty);
          if (currentHint < 2) expect(buildings, isNotEmpty);
          if (currentHint < 3) {
            expect(icons, isNotEmpty);
          } else {
            expect(
              icons,
              isEmpty,
              reason: 'Unnamed facility icons must be hidden at 5 km',
            );
          }
          expect(iconIds.length, lessThanOrEqualTo(5));
          expect(iconKinds.difference(facilityKinds), isEmpty);
          for (final item in iconProperties) {
            expect(
              item.keys.where(
                (key) => key.toString().toLowerCase().contains('name'),
              ),
              isEmpty,
            );
          }
          if (currentHint < 3) {
            initialIconIds ??= iconIds;
            expect(
              iconIds.containsAll(initialIconIds),
              true,
              reason: 'Close-range facility icons must persist through H2',
            );
          }

          if (currentHint == 0) {
            expect(routeLines, isEmpty);
          } else {
            expect(routeLines, isNotEmpty);
            expect(colours.difference(approvedColours), isEmpty);
          }
          if (currentHint < 2) {
            expect(routeLabels, isEmpty);
          } else {
            expect(routeLabels, isNotEmpty);
            expect(routeNames.difference(approvedNames), isEmpty);
            for (final name in routeNames) {
              expect(isUsefulRailwayLabel(station, name), true);
            }
          }
          if (currentHint < 3) {
            expect(places, isEmpty);
            expect(namedFacilities, isEmpty);
          } else {
            expect(places, isNotEmpty);
            expect(namedFacilities, isNotEmpty);
            expect(namedFacilities.length, lessThanOrEqualTo(3));
            for (final feature in [...places, ...namedFacilities]) {
              final item = properties(feature);
              final name = item['name:ja'] ?? item['name'];
              expect(name, isA<String>());
              expect(isSafeHintLabel(station, name as String), true);
            }
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
            'rails': rails.length,
            'buildings': buildings.length,
            'facilityIconCount': icons.length,
            'facilityIds': iconIds.toList()..sort(),
            'facilityKinds': iconKinds.toList()..sort(),
            'routeColourFeatureCount': routeLines.length,
            'routeColours': colours.toList()..sort(),
            'routeLabelCount': routeLabels.length,
            'routeNames': routeNames.toList()..sort(),
            'placeLabelCount': places.length,
            'facilityLabelCount': namedFacilities.length,
            'screenshot':
                'docs/screenshots/map-hints-poc/$stationId/$stage.jpg',
          });
        }
        completedStations.add(stationId);
        quality['completed'] =
            completedStations.length == 3 && failures.isEmpty;
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      } catch (error) {
        failures.add({
          'stationId': stationId,
          'hint': currentHint,
          'error': error.toString(),
        });
        quality['completed'] = false;
        rethrow;
      }
    });
  }
}
