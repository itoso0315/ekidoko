import 'dart:math';
import 'dart:io';
import 'package:ekidoko/map/map_hint_data.dart';
import 'support/question_order_random.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/main.dart';
import 'package:ekidoko/map/real_station_map.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:ekidoko/screens/app_screen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final measurements = <Map<String, dynamic>>[];
  const quick = bool.fromEnvironment('EKIDOKO_QUICK_STYLE_CHECK');
  const phase3 = bool.fromEnvironment('EKIDOKO_PHASE3');
  const diagnoseLabels = bool.fromEnvironment('EKIDOKO_DIAG_LABELS');
  const requestedBatch = int.fromEnvironment('EKIDOKO_MAP_BATCH');
  const saveScreenshots = bool.fromEnvironment(
    'EKIDOKO_CAPTURE',
    defaultValue: true,
  );
  for (final batch
      in phase3 ? [requestedBatch] : List.generate(quick ? 1 : 2, (i) => i)) {
    testWidgets('map batch $batch: ten real stations, four stages and full game', (
      tester,
    ) async {
      String? verifyingStation;
      var verifyingHint = 0;
      final quality = <String, dynamic>{
        'batch': batch,
        'records': measurements,
        'failures': <Map<String, dynamic>>[],
        'completed': false,
      };
      final setupWatch = Stopwatch()..start();
      if (phase3) {
        binding.reportData ??= <String, dynamic>{};
        binding.reportData!['phase3Quality'] = quality;
      }
      try {
        final catalogWatch = Stopwatch()..start();
        final catalog = await loadStationCatalog();
        final catalogLoadMs = catalogWatch.elapsedMilliseconds;
        final hintsWatch = Stopwatch()..start();
        await loadMapHints(catalog.stations.first);
        final hintAssetLoadMs = hintsWatch.elapsedMilliseconds;
        final mode = phase3 && batch != 0
            ? GameDifficulty.hard
            : GameDifficulty.easy;
        quality['difficulty'] = mode.label;
        final desired = phase3
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
          if (!phase3) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
          await tester.pump(const Duration(milliseconds: 100));
          final bytes = await binding.takeScreenshot(name);
          if (phase3) {
            // Persist in the app's temporary container. Do not retain 200 PNGs
            // in the VM report; the host driver copies/compresses each batch.
            final root =
                '${Directory.systemTemp.path}/ekidoko-quality/batch-$batch';
            final file = File('$root/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes);
            binding.reportData!.remove('screenshots');
            quality['screenshotRoot'] = root;
          }
        }

        for (var i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final map = tester.state<RealStationMapState>(
            find.byType(RealStationMap),
          );
          if (map.error != null) fail(map.error!);
          if (map.ready) break;
        }
        expect(find.text('Ekidoko'), findsOneWidget);
        quality['testSetupToHomeMapMs'] = setupWatch.elapsedMilliseconds;
        final homeMap = tester.getSize(find.byType(RealStationMap));
        expect(homeMap.width, closeTo(homeMap.height, 0.1));
        if (batch == 0) await capture(phase3 ? 'phase3/home' : 'phase2/home');
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
        Future<void> recordStage(
          RealStationMapState state,
          int hint,
          int elapsedMs,
        ) async {
          final station = game.station;
          final controller = state.controller!;
          final camera = controller.cameraPosition!;
          final rect =
              Offset.zero & tester.getSize(find.byType(RealStationMap));
          Future<List> features(String layer) async =>
              controller.queryRenderedFeaturesInRect(rect, [layer], null);
          final places = await features('hint-places');
          final facilities = await features('hint-facilities');
          final routes = await features('railway-labels');
          expect(routes, hint < 2 ? isEmpty : isNotEmpty);
          if (hint < 3) {
            expect(places, isEmpty);
            expect(facilities, isEmpty);
          }
          final names = [
            ...places,
            ...facilities,
          ].map((f) => f['properties']['name']).toSet().toList();
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
            'waterCount': (await features('water')).length,
            'parkCount': (await features('parks')).length,
            'routeNames': routes
                .map((f) => f['properties']['name'])
                .toSet()
                .toList(),
            'placeNames': places
                .map((f) => f['properties']['name'])
                .toSet()
                .toList(),
            'facilityNames': facilities
                .map((f) => f['properties']['name'])
                .toSet()
                .toList(),
            'labelNames': names,
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
          if (!phase3) binding.reportData!['phase2Quality'] = measurements;
          final stage = ['initial', 'hint1', 'hint2', 'hint3'][hint];
          final screenshot = phase3
              ? 'stations/${station.id}/$stage'
              : 'phase2/${station.id}-stage$hint';
          await capture(screenshot);
          record['screenshot'] = saveScreenshots
              ? '$screenshot.${phase3 ? 'jpg' : 'png'}'
              : null;
        }

        for (var question = 0; question < (quick ? 2 : 10); question++) {
          final station = game.station;
          verifyingStation = station.id;
          verifyingHint = 0;
          debugPrint('VERIFY ${station.id}: initial and hints 1/2/3');
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
              // Named tracks must also exist outside the old central snapshot.
              if (['tokyo', 'shinjuku', 'shibuya'].contains(station.id)) {
                final outerTracks = await controller
                    .queryRenderedFeaturesInRect(
                      Rect.fromLTWH(0, 0, mapSize.width, mapSize.height * .2),
                      ['named-railway-colors'],
                      null,
                    );
                expect(outerTracks, isNotEmpty);
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
          expect(
            record['facilityNames'],
            isNotEmpty,
            reason: "${record['stationName']} hint3 facilities",
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
          phase3 ? 'phase3/results-$batch' : 'phase2/results-$batch',
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
        if (phase3) {
          (quality['failures'] as List).add({
            'stationId': verifyingStation,
            'hint': verifyingHint,
            'error': error.toString(),
            'renderStatus': 'failed',
          });
        }
        rethrow;
      }
    });
  }
}
