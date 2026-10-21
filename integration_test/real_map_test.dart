import 'dart:math';
import 'dart:io';
import 'package:ekidoko/map/map_hint_data.dart';
import 'package:ekidoko/map/map_hints_poc.dart';
import 'support/question_order_random.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/main.dart';
import 'package:ekidoko/map/home_map_preview.dart';
import 'package:ekidoko/map/real_station_map.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:ekidoko/screens/app_screen.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

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
  final measurements = <Map<String, dynamic>>[];
  const quick = bool.fromEnvironment('EKIDOKO_QUICK_STYLE_CHECK');
  const phase3 = bool.fromEnvironment('EKIDOKO_PHASE3');
  const phase4 = bool.fromEnvironment('EKIDOKO_PHASE4');
  const diagnoseLabels = bool.fromEnvironment('EKIDOKO_DIAG_LABELS');
  const requestedBatch = int.fromEnvironment('EKIDOKO_MAP_BATCH');
  const runId = String.fromEnvironment(
    'EKIDOKO_QUALITY_RUN_ID',
    defaultValue: 'manual',
  );
  const commitSha = String.fromEnvironment('EKIDOKO_COMMIT_SHA');
  const sourceTreeDirty = bool.fromEnvironment('EKIDOKO_SOURCE_DIRTY');
  const mapHintsAssetSha256 = String.fromEnvironment(
    'EKIDOKO_MAP_HINTS_SHA256',
  );
  const stationHintsAssetSha256 = String.fromEnvironment(
    'EKIDOKO_STATION_HINTS_SHA256',
  );
  const stationCatalogSha256 = String.fromEnvironment(
    'EKIDOKO_STATIONS_SHA256',
  );
  const cacheCondition = String.fromEnvironment(
    'EKIDOKO_CACHE_CONDITION',
    defaultValue: 'unknown',
  );
  const saveScreenshots = bool.fromEnvironment(
    'EKIDOKO_CAPTURE',
    defaultValue: true,
  );
  final qualityMode = phase3 || phase4;
  for (final batch
      in qualityMode
          ? [requestedBatch]
          : List.generate(quick ? 1 : 2, (i) => i)) {
    testWidgets('map batch $batch: ten real stations, four stages and full game', (
      tester,
    ) async {
      String? verifyingStation;
      int? verifyingHint;
      var verifyingStage = 'setup';
      final choiceAudits = <Map<String, dynamic>>[];
      final quality = <String, dynamic>{
        'schemaVersion': phase4 ? 4 : 3,
        'runId': runId,
        'batch': batch,
        'records': measurements,
        'failures': <Map<String, dynamic>>[],
        'choiceAudits': choiceAudits,
        'captureEnabled': saveScreenshots,
        'commitSha': commitSha,
        'sourceTreeDirty': sourceTreeDirty,
        'mapHintsAssetSha256': mapHintsAssetSha256,
        'stationHintsAssetSha256': stationHintsAssetSha256,
        'stationCatalogSha256': stationCatalogSha256,
        'cacheCondition': cacheCondition,
        'expectedRecordCount': 40,
        'completed': false,
      };
      final setupWatch = Stopwatch()..start();
      if (qualityMode) {
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['phase3Quality'] = quality;
      }
      try {
        if (phase4) {
          expect(
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(runId),
            true,
            reason: 'Phase 4 run ID must be safe for artifact paths',
          );
          for (final value in [
            commitSha,
            mapHintsAssetSha256,
            stationHintsAssetSha256,
            stationCatalogSha256,
            cacheCondition,
          ]) {
            expect(value, isNotEmpty, reason: 'Phase 4 metadata is required');
          }
          final tempRoot = Directory(
            '${Directory.systemTemp.path}/ekidoko-quality/$runId/batch-$batch',
          );
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        }
        final catalogWatch = Stopwatch()..start();
        final catalog = await loadStationCatalog();
        final catalogLoadMs = catalogWatch.elapsedMilliseconds;
        final hintsWatch = Stopwatch()..start();
        await loadMapHints(catalog.stations.first);
        await loadMapHintsPoc(catalog.stations.first);
        final hintAssetLoadMs = hintsWatch.elapsedMilliseconds;
        final mode = qualityMode && batch != 0
            ? GameDifficulty.hard
            : GameDifficulty.easy;
        quality['difficulty'] = mode.label;
        final desired = qualityMode
            ? catalog.stations
                  .skip(batch * 10)
                  .take(10)
                  .map((s) => s.id)
                  .toList()
            : batch == 0
            ? [
                'kyoto',
                'tokyo',
                ...catalog.stations
                    .take(10)
                    .where((s) => !['kyoto', 'tokyo'].contains(s.id))
                    .map((s) => s.id),
              ]
            : catalog.stations.skip(10).take(10).map((s) => s.id).toList();
        final game = Game(
          catalog: catalog,
          random: QuestionOrderRandom(
            catalog
                .select()
                .where((s) => mode == GameDifficulty.hard || s.easyEligible)
                .map((s) => s.id)
                .toList(),
            desired,
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildEkidokoTheme(),
            debugShowCheckedModeBanner: false,
            home: AppScreen(game: game),
          ),
        );
        Future<void> capture(String name) async {
          if (!saveScreenshots) return;
          if (!qualityMode) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          await tester.pump(const Duration(milliseconds: 100));
          final bytes = await binding.takeScreenshot(name);
          if (qualityMode) {
            // Persist in the app's temporary container. Do not retain 200 PNGs
            // in the VM report; the host driver copies/compresses each batch.
            final root = phase4
                ? '${Directory.systemTemp.path}/ekidoko-quality/$runId/batch-$batch'
                : '${Directory.systemTemp.path}/ekidoko-quality/batch-$batch';
            final file = File('$root/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
            binding.reportData!.remove('screenshots');
            quality['screenshotRoot'] = root;
          }
        }

        await tester.pumpAndSettle();
        expect(find.text('Ekidoko'), findsOneWidget);
        expect(find.byType(HomeMapPreview), findsOneWidget);
        expect(find.byType(RealStationMap), findsNothing);
        quality['testSetupToHomeMapMs'] = setupWatch.elapsedMilliseconds;
        final homeMap = tester.getSize(find.byType(HomeMapPreview));
        expect(homeMap.width, closeTo(homeMap.height, 0.1));
        if (batch == 0) {
          await capture(
            phase4
                ? 'phase4/$runId/home'
                : phase3
                ? 'phase3/home'
                : 'phase2/home',
          );
        }
        if (mode == GameDifficulty.hard) {
          await tester.ensureVisible(find.text('Hard'));
          await tester.tap(find.text('Hard'));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(game.difficulty, mode);
        final initialWatch = Stopwatch()..start();
        await tester.ensureVisible(find.text('ゲームをはじめる'));
        await tester.tap(find.text('ゲームをはじめる'));
        await tester.pump(const Duration(milliseconds: 500));
        quality['quizTransitionMs'] = initialWatch.elapsedMilliseconds;

        Future<RealStationMapState> waitForMap() async {
          for (var i = 0; i < 180; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final maps = find.byType(RealStationMap);
            if (maps.evaluate().length == 1) {
              final state = tester.state<RealStationMapState>(maps);
              if (state.error != null) {
                final diagnostics = <String, dynamic>{
                  'stationId': game.station.id,
                  'hint': game.hint,
                  'counts': Map<String, int>.from(state.renderedFeatureCounts),
                };
                // The error UI disposes the native map; inspect collisions
                // before the deadline using EKIDOKO_DIAG_LABELS instead.
                (quality['diagnostics'] ??= <Map<String, dynamic>>[]).add(
                  diagnostics,
                );
                debugPrint('DIAG $diagnostics');
                fail(
                  '${state.error} station:${game.station.name} hint:${game.hint} features:${state.renderedFeatureCounts}',
                );
              }
              if (state.ready) {
                await tester.pump(const Duration(milliseconds: 100));
                await tester.pump(const Duration(milliseconds: 100));
                if (state.ready) return state;
              }
              if (diagnoseLabels &&
                  game.hint == 3 &&
                  i > 20 &&
                  state.renderedFeatureCounts['routeLabels'] == 0 &&
                  (state.renderedFeatureCounts['labels'] ?? 0) > 0) {
                final controller = state.controller!;
                final beforeCounts = Map<String, int>.from(
                  state.renderedFeatureCounts,
                );
                await capture('diagnostics/${game.station.id}-before');
                await controller.setLayerVisibility('hint-places', false);
                await controller.setLayerVisibility('hint-facilities', false);
                await tester.pump(const Duration(seconds: 1));
                await Future<void>.delayed(const Duration(seconds: 1));
                final rect = Offset.zero & tester.getSize(maps);
                final routes = await controller.queryRenderedFeaturesInRect(
                  rect,
                  ['railway-labels'],
                  null,
                );
                debugPrint(
                  'DIAG ${game.station.id}: routes without place/facility collision = ${routes.length}',
                );
                await capture(
                  'diagnostics/${game.station.id}-without-other-labels',
                );
                (quality['diagnostics'] ??= <Map<String, dynamic>>[]).add({
                  'stationId': game.station.id,
                  'hint': game.hint,
                  'counts': beforeCounts,
                  'routeLabelsWithoutOtherLabels': routes.length,
                  'routeNamesWithoutOtherLabels': routes
                      .map((f) => f['properties']['name'])
                      .toSet()
                      .toList(),
                });
                fail(
                  'Diagnostic only: ${routes.length} routes when other labels are hidden',
                );
              }
            }
          }
          fail('Actual map did not render');
        }

        expect(game.questions.map((s) => s.id), orderedEquals(desired));
        quality['questionStationIds'] = game.questions
            .map((station) => station.id)
            .toList();
        Future<void> recordStage(
          RealStationMapState state,
          int hint,
          int elapsedMs,
        ) async {
          final station = game.station;
          final controller = state.controller!;
          final poc = await loadMapHintsPoc(station);
          final camera = controller.cameraPosition!;
          final rect =
              Offset.zero & tester.getSize(find.byType(RealStationMap));
          Future<List> features(String layer) async =>
              controller.queryRenderedFeaturesInRect(rect, [layer], null);
          final places = await features('hint-places');
          final facilities = await features('hint-facilities');
          final routes = await features('railway-labels');
          final icons = poc.hasFacilities
              ? await features('poc-facility-icons')
              : <dynamic>[];
          final routeColors = poc.hasRoutes
              ? await features('verified-route-colors')
              : <dynamic>[];
          final highSpeedRails = poc.hasHighSpeedRailways
              ? await features('high-speed-rail')
              : <dynamic>[];
          final highSpeedCasing = poc.hasHighSpeedRailways
              ? await features('high-speed-rail-casing')
              : <dynamic>[];
          final bounds = await controller.getVisibleRegion();
          final expectsFacilityIconsInViewport =
              hint < 3 &&
              poc.hasFacilities &&
              (poc.facilities['features'] as List).any(
                (feature) => _pointIsInBounds(
                  feature['geometry']['coordinates'] as List<dynamic>,
                  bounds,
                ),
              );
          final expectsRouteColorsInViewport =
              hint >= 1 &&
              poc.hasRoutes &&
              _linesIntersectBounds(poc.routes, bounds);
          final expectsHighSpeedInViewport =
              poc.hasHighSpeedRailways &&
              _linesIntersectBounds(poc.highSpeedRailways, bounds);
          final expectedRepresentatives = hint == 3
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
          final renderedRepresentatives = facilities
              .map((feature) => feature['properties'] as Map)
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
          expect(routes, hint < 2 ? isEmpty : isNotEmpty);
          if (hint < 3) {
            expect(places, isEmpty);
            expect(facilities, isEmpty);
            expect(state.expectedRepresentativeKeys, isEmpty);
            expect(state.renderedRepresentativeKeys, isEmpty);
            expect(state.missingRepresentativeKeys, isEmpty);
          } else {
            expect(
              state.expectedRepresentativeKeys,
              expectedRepresentativeKeys,
              reason: '${station.id} expected representative contract',
            );
            expect(
              state.renderedRepresentativeKeys,
              renderedRepresentativeKeys,
              reason: '${station.id} rendered representative contract',
            );
            expect(state.missingRepresentativeKeys, isEmpty);
            expect(
              state.renderedFeatureCounts['expectedRepresentativeLabels'],
              expectedRepresentativeKeys.length,
            );
            expect(
              state.renderedFeatureCounts['matchedRepresentativeLabels'],
              expectedRepresentativeKeys.length,
              reason: 'generic places cannot substitute for representatives',
            );
            expect(
              state.renderedFeatureCounts['missingRepresentativeLabels'],
              0,
            );
          }
          final names = [
            ...places,
            ...facilities,
          ].map((f) => f['properties']['name']).toSet().toList();
          final routeNames = routes
              .map((f) => f['properties']['name'])
              .whereType<String>()
              .toSet()
              .toList();
          final iconProperties = icons
              .map((feature) => feature['properties'] as Map)
              .toList();
          final renderedColors = routeColors
              .map((feature) => feature['properties']['color'])
              .whereType<String>()
              .toSet();
          final approvedColors = (poc.routes['features'] as List)
              .map((feature) => feature['properties']['color'])
              .whereType<String>()
              .toSet();
          if (expectsFacilityIconsInViewport) {
            expect(icons, isNotEmpty, reason: '${station.id} H$hint icons');
          }
          if (hint == 3) {
            expect(icons, isEmpty, reason: '${station.id} H$hint icons');
          }
          for (final properties in iconProperties) {
            expect(
              properties.keys.where(
                (key) => key.toString().toLowerCase().contains('name'),
              ),
              isEmpty,
            );
          }
          if (expectsRouteColorsInViewport) {
            expect(
              routeColors,
              isNotEmpty,
              reason: '${station.id} H$hint route colours',
            );
            expect(renderedColors.difference(approvedColors), isEmpty);
          }
          if (hint == 0) {
            expect(routeColors, isEmpty);
          }
          if (expectsHighSpeedInViewport) {
            expect(highSpeedRails, isNotEmpty, reason: station.id);
            expect(highSpeedCasing, isNotEmpty, reason: station.id);
          }
          for (final name in [...routeNames, ...names]) {
            expect(isSafeHintLabel(station, name as String), true);
          }
          final record = <String, dynamic>{
            'stationId': station.id,
            'stationName': station.name,
            'hint': hint,
            'elapsedFromActionMs': elapsedMs,
            'zoom': camera.zoom,
            'latitude': camera.target.latitude,
            'longitude': camera.target.longitude,
            'counts': Map<String, int>.from(state.renderedFeatureCounts),
            'roadCount': (await features('roads')).length,
            'railCount': (await features('railways')).length,
            'buildingCount': (await features('buildings')).length,
            'buildingVerification': hint < 2
                ? 'machine-confirmed-rendered-feature'
                : 'manual-required-vector-tile-zoom-limit',
            'waterCount': (await features('water')).length,
            'parkCount': (await features('parks')).length,
            'routeNames': routeNames,
            'placeNames': places
                .map((f) => f['properties']['name'])
                .toSet()
                .toList(),
            'facilityNames': facilities
                .map((f) => f['properties']['name'])
                .toSet()
                .toList(),
            'labelNames': names,
            'representativeLabels': facilities.length,
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
            'facilityIconCount': icons.length,
            'anonymousFacilityNameCount': iconProperties
                .where(
                  (properties) => properties.keys.any(
                    (key) => key.toString().toLowerCase().contains('name'),
                  ),
                )
                .length,
            'verifiedRouteColorCount': routeColors.length,
            'verifiedRouteColors': renderedColors.toList()..sort(),
            'highSpeedRailCount': highSpeedRails.length,
            'highSpeedRailCasingCount': highSpeedCasing.length,
            'expectsFacilityIconsInViewport': expectsFacilityIconsInViewport,
            'expectsRouteColorsInViewport': expectsRouteColorsInViewport,
            'expectsHighSpeedInViewport': expectsHighSpeedInViewport,
            'capabilities': {
              'facilities': poc.hasFacilities,
              'routes': poc.hasRoutes,
              'highSpeedRailways': poc.hasHighSpeedRailways,
              'representativeFacilities': poc.hasRepresentativeFacilities,
            },
            'catalogLoadMs': catalogLoadMs,
            'hintAssetLoadMs': hintAssetLoadMs,
            'renderStatus': 'ok',
            'labelFilterStatus': 'passed',
            'visualLabelReview': 'unconfirmed',
            'tileCompleteness':
                'Individual tile completeness is not exposed by this SDK',
            'difficulty': mode.label,
          };
          try {
            record['rssBytes'] = ProcessInfo.currentRss;
          } catch (error) {
            record['rssBytes'] = null;
            record['rssUnavailable'] = error.toString();
          }
          expect(camera.target.latitude, closeTo(station.latitude, .000001));
          expect(camera.target.longitude, closeTo(station.longitude, .000001));
          expect(camera.bearing, closeTo(0, .001));
          expect(camera.tilt, closeTo(0, .001));
          final size = tester.getSize(find.byType(RealStationMap));
          expect(
            camera.zoom,
            closeTo(
              quizZoom(station.latitude, min(size.width, size.height), hint),
              .001,
            ),
          );
          expect(record['roadCount'], greaterThan(0));
          expect(record['railCount'], greaterThan(0));
          if (hint < 2) expect(record['buildingCount'], greaterThan(0));
          expect(camera.target.latitude, closeTo(station.latitude, .000001));
          expect(camera.target.longitude, closeTo(station.longitude, .000001));
          expect(camera.bearing, closeTo(0, .001));
          expect(camera.tilt, closeTo(0, .001));
          if (hint == 3) {
            debugPrint(
              'LABELS ${station.id}: places=${places.length} facilities=${facilities.length}',
            );
          }
          measurements.add(record);
          binding.reportData ??= <String, dynamic>{};
          if (!qualityMode) {
            binding.reportData!['phase2Quality'] = measurements;
          }
          final stage = ['initial', 'hint1', 'hint2', 'hint3'][hint];
          final screenshot = phase4
              ? 'phase4/$runId/stations/${station.id}/$stage'
              : phase3
              ? 'stations/${station.id}/$stage'
              : 'phase2/${station.id}-stage$hint';
          await capture(screenshot);
          record['screenshot'] = saveScreenshots
              ? '$screenshot.${qualityMode ? 'jpg' : 'png'}'
              : null;
        }

        for (var question = 0; question < (quick ? 2 : 10); question++) {
          final station = game.station;
          verifyingStation = station.id;
          verifyingHint = 0;
          verifyingStage = 'initial';
          debugPrint('VERIFY ${station.id}: initial and hints 1/2/3');
          final choiceIds = game.choices.map((choice) => choice.id).toList();
          final correctChoiceCount = game.choices
              .where((choice) => choice.id == station.id)
              .length;
          expect(choiceIds, hasLength(4));
          expect(choiceIds.toSet(), hasLength(4));
          expect(correctChoiceCount, 1);
          if (mode == GameDifficulty.easy) {
            expect(game.choices.every((choice) => choice.easyEligible), true);
          }
          choiceAudits.add({
            'question': question,
            'stationId': station.id,
            'choiceIds': choiceIds,
            'correctChoiceCount': correctChoiceCount,
            'allEasyEligible': game.choices.every(
              (choice) => choice.easyEligible,
            ),
          });
          var state = await waitForMap();
          final mapFinder = find.byType(RealStationMap);
          final mapSize = tester.getSize(mapFinder);
          final rect = Offset.zero & mapSize;
          final controller = state.controller!;
          final before = controller.cameraPosition!;
          final geometry = await controller.queryRenderedFeaturesInRect(rect, [
            'roads',
            'railways',
            'buildings',
          ], null);
          expect(geometry, isNotEmpty);
          final initialLabels = await controller.queryRenderedFeaturesInRect(
            rect,
            ['hint-places', 'hint-facilities', 'railway-labels'],
            null,
          );
          expect(initialLabels, isEmpty);
          await recordStage(state, 0, initialWatch.elapsedMilliseconds);
          // The Flutter hit-test barrier is in addition to every native gesture flag.
          await tester.drag(mapFinder, const Offset(90, 60));
          await tester.tap(mapFinder);
          await tester.tap(mapFinder);
          final center = tester.getCenter(mapFinder);
          final a = await tester.startGesture(
            center - const Offset(30, 0),
            pointer: 1,
          );
          final b = await tester.startGesture(
            center + const Offset(30, 0),
            pointer: 2,
          );
          await a.moveTo(center - const Offset(80, 20));
          await b.moveTo(center + const Offset(80, 20));
          await a.up();
          await b.up();
          await tester.pump(const Duration(milliseconds: 500));
          final after = controller.cameraPosition!;
          expect(
            after.target.latitude,
            closeTo(before.target.latitude, 0.000001),
          );
          expect(
            after.target.longitude,
            closeTo(before.target.longitude, 0.000001),
          );
          expect(after.zoom, closeTo(before.zoom, 0.0001));
          expect(after.bearing, closeTo(0, 0.001));
          expect(after.tilt, closeTo(0, 0.001));
          for (var hint = 1; hint <= 3; hint++) {
            verifyingHint = hint;
            verifyingStage = 'hint$hint';
            final hintWatch = Stopwatch()..start();
            await tester.ensureVisible(find.text('ヒントを見る'));
            await tester.tap(find.text('ヒントを見る'));
            state = await waitForMap();
            expect(game.hint, hint);
            final camera = controller.cameraPosition!;
            expect(camera.target.latitude, closeTo(station.latitude, 0.000001));
            expect(
              camera.target.longitude,
              closeTo(station.longitude, 0.000001),
            );
            expect(
              camera.zoom,
              closeTo(
                before.zoom - log(mapSpans[hint] / mapSpans[0]) / ln2,
                .001,
              ),
            );
            final labels = await controller.queryRenderedFeaturesInRect(rect, [
              'hint-places',
              'hint-facilities',
            ], null);
            if (hint < 3) expect(labels, isEmpty);
            if (hint >= 2) {
              final routeLabels = await controller.queryRenderedFeaturesInRect(
                rect,
                ['railway-labels'],
                null,
              );
              expect(routeLabels, isNotEmpty);
              for (final route in routeLabels) {
                expect(
                  isUsefulRailwayLabel(
                    station,
                    route['properties']['name'] as String,
                  ),
                  true,
                );
              }
            }
            if (hint == 3) {
              expect(labels, isNotEmpty);
              for (final feature in labels) {
                final p = feature['properties'];
                final name = p['name:ja'] ?? p['name'];

                expect(isSafeHintLabel(station, name as String), true);
              }
            }
            await recordStage(state, hint, hintWatch.elapsedMilliseconds);
          }
          final chosen = question == 1
              ? game.choices.firstWhere((s) => s.id != station.id)
              : station;
          final option = find.byKey(ValueKey('choice-${chosen.id}'));
          await tester.ensureVisible(option);
          await tester.tap(option);
          await tester.pump(const Duration(milliseconds: 200));
          await tester.ensureVisible(find.text('この駅で回答する'));
          await tester.tap(find.text('この駅で回答する'));
          await tester.pump(const Duration(milliseconds: 600));
          await waitForMap();
          expect(find.text(question == 1 ? '残念！' : '正解！'), findsOneWidget);
          expect(find.text('${station.name}駅'), findsNWidgets(2));

          final next = find.text(question == 9 ? '結果を見る' : '次の問題へ');
          await tester.ensureVisible(next);
          initialWatch.reset();
          await tester.tap(next);
          await tester.pump(const Duration(milliseconds: 500));
        }
        for (final record in measurements.where(
          (r) => desired.contains(r['stationId']) && r['hint'] == 3,
        )) {
          expect(
            record['placeNames'],
            isNotEmpty,
            reason: "${record['stationName']} hint3 places",
          );
        }
        if (quick) {
          await tester.pumpWidget(const SizedBox());
          game.dispose();
          return;
        }
        expect(game.answers.map((a) => a.station.id).toSet().length, 10);
        expect(game.finished, true);
        expect(game.score, 90);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('result-difficulty')),
            matching: find.text(mode.label),
          ),
          findsOneWidget,
        );
        quality['gameScore'] = game.score;
        quality['correctCount'] = game.correctCount;
        await capture(
          phase4
              ? 'phase4/$runId/results-$batch'
              : phase3
              ? 'phase3/results-$batch'
              : 'phase2/results-$batch',
        );
        await tester.ensureVisible(find.text('もう一度遊ぶ'));
        await tester.tap(find.text('もう一度遊ぶ'));
        await tester.pump(const Duration(milliseconds: 500));
        await waitForMap();
        expect(game.questionCount, 10);
        expect(game.score, 0);
        expect(game.difficulty, mode);
        quality['replayReset'] = true;
        quality['completed'] = true;
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        game.dispose();
      } catch (error) {
        if (qualityMode) {
          (quality['failures'] as List).add({
            'stationId': verifyingStation,
            'hint': verifyingHint,
            'stage': verifyingStage,
            'error': error.toString(),
            'renderStatus': 'failed',
          });
        }
        rethrow;
      }
    });
  }
}
