import 'support/catalog.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/map/map_availability.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:ekidoko/map/real_station_map.dart';
import 'package:ekidoko/map/station_map.dart';
import 'package:ekidoko/screens/app_screen.dart';

const testTiles = <String, dynamic>{
  'tiles': ['https://tiles.openfreemap.org/planet/test/{z}/{x}/{y}.pbf'],
  'minzoom': 0,
  'maxzoom': 14,
  'attribution': 'OpenStreetMap',
};

void main() {
  test('stale map readiness cannot enable a newer question or hint', () {
    final ready = MapAvailability(false);
    ready.begin(false);
    final oldRequest = ready.request;
    ready.begin(false);
    ready.report(oldRequest, true);
    expect(ready.value, false);
    ready.report(ready.request, true);
    expect(ready.value, true);
    ready.dispose();
  });
  test('fifty-station pool uses real maps and reset on replay', () {
    final game = Game(catalog: catalog, random: Random(3))..start();
    expect(game.questions.map((s) => s.id).toSet().length, 10);
    for (var i = 0; i < 10; i++) {
      expect(game.station.hasRealMap, true);
      game.submitChoice(game.station);
      game.next();
    }
    expect(game.finished, true);
    expect(game.score, 1000);
    game.start();
    expect(game.questions.length, 10);
    expect(game.score, 0);
  });

  test(
    'passenger railway data covers the widest viewport without local clipping',
    () {
      final data =
          jsonDecode(File('assets/maps/station_hints.json').readAsStringSync())
              as Map<String, dynamic>;
      for (final station in stations.where((s) => s.hasRealMap)) {
        final features = data[station.id]['railways']['features'] as List;
        expect(features, isNotEmpty);
        expect(
          features.every(
            (f) => isUsefulRailwayLabel(
              station,
              f['properties']['name'] as String,
            ),
          ),
          true,
        );
        if (!['tokyo', 'shinjuku', 'shibuya'].contains(station.id)) continue;
        final yamanote = features.where(
          (f) => f['properties']['name'] == '山手線',
        );
        // The same real track path must extend from the station vicinity well
        // beyond the old 1.6km snapshot, rather than end inside the 5km view.
        expect(
          yamanote.any((f) {
            final distances = (f['geometry']['coordinates'] as List).map((p) {
              final dx =
                  ((p[0] as num) - station.longitude) *
                  cos(station.latitude * pi / 180) *
                  111320;
              final dy = ((p[1] as num) - station.latitude) * 111320;
              return sqrt(dx * dx + dy * dy);
            }).toList();
            return distances.reduce(min) < 1000 && distances.reduce(max) > 6000;
          }),
          true,
        );
      }
      expect(isUsefulRailwayLabel(stations[0], '山手貨物線'), false);
      expect(isUsefulRailwayLabel(stations[0], 'Freight line'), false);
    },
  );

  test('zoom spans follow viewport size and geographic latitude', () {
    final initial = quizZoom(35.68, 350, 0);
    expect(initial - quizZoom(35.68, 350, 1), closeTo(1, 0.00001));
    expect(initial - quizZoom(35.68, 350, 2), closeTo(log(6) / ln2, 0.00001));
    expect(initial - quizZoom(35.68, 350, 3), closeTo(log(10) / ln2, 0.00001));
    expect(quizZoom(35.68, 700, 0) - initial, closeTo(1, 0.00001));
  });

  test('style contains only geometry and reviewed safe label layers', () {
    for (final station in stations.where((s) => s.hasRealMap)) {
      for (var hint = 0; hint < 4; hint++) {
        final style = quizMapStyle(station, testTiles, hint: hint);
        final layers = style['layers'] as List;
        final symbols = layers.where((l) => l['type'] == 'symbol').toList();
        expect(symbols.map((l) => l['id']), [
          'hint-places',
          'railway-labels',
          'hint-facilities',
        ]);
        expect(
          symbols.every(
            (l) =>
                l['layout']['visibility'] ==
                ((l['id'] == 'railway-labels' ? hint >= 2 : hint >= 3)
                    ? 'visible'
                    : 'none'),
          ),
          true,
        );
        // H3 landmark labels are drawn after route labels to retain priority.
        expect(symbols.last['id'], 'hint-facilities');
        expect(
          symbols[symbols.length - 2]['layout']['text-allow-overlap'] ?? false,
          false,
        );
        final markers = layers.singleWhere(
          (l) => l['id'] == 'hint-facility-markers',
        );
        expect(markers['layout']['visibility'], hint >= 3 ? 'visible' : 'none');
        expect(style.containsKey('sprite'), false);
        expect(layers.any((l) => l['id'] == 'railways'), true);
        expect(layers.any((l) => l['id'] == 'buildings'), true);
        expect(isSafeHintLabel(station, '${station.name}駅前広場'), false);
        for (final alias in station.answerAliases) {
          expect(isSafeHintLabel(station, '$alias Station Tower'), false);
        }
      }
    }
    expect(isUsefulRailwayLabel(stations[1], '湘南新宿ライン'), false);
    expect(isUsefulRailwayLabel(stations[0], '東京メトロ丸ノ内線'), false);
  });

  testWidgets('failed source offers retry and never reports ready', (
    tester,
  ) async {
    var attempts = 0;
    final ready = MapAvailability(false);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 300,
          child: MapAvailabilityScope(
            availability: ready,
            child: RealStationMap(
              station: stations[0],
              hint: 0,
              reveal: false,
              tileLoader: () async {
                attempts++;
                throw StateError('offline');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(ready.value, false);
    expect(find.text('再試行'), findsOneWidget);
    await tester.tap(find.text('再試行'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(ready.value, false);
    expect(find.text('再試行'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    ready.dispose();
  });

  testWidgets(
    'slow source times out with retry instead of blocking indefinitely',
    (tester) async {
      final source = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            height: 300,
            child: RealStationMap(
              station: stations[0],
              hint: 0,
              reveal: false,
              loadTimeout: const Duration(seconds: 1),
              tileLoader: () => source.future,
            ),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('再試行'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      source.complete(testTiles);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ten-question UI reaches result and replays', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = Game(catalog: catalog, random: Random(1));
    await tester.pumpWidget(
      MaterialApp(
        home: AppScreen(game: game, mapBuilder: mockMapBuilder),
      ),
    );
    await tester.ensureVisible(find.text('ゲームをはじめる'));
    await tester.tap(find.text('ゲームをはじめる'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 10'), findsOneWidget);
    for (var i = 0; i < 10; i++) {
      final option = find.byKey(ValueKey('choice-${game.station.id}'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('この駅で回答する'));
      await tester.tap(find.text('この駅で回答する'));
      await tester.pumpAndSettle();
      final next = find.text(i == 9 ? '結果を見る' : '次の問題へ');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(find.text('/ 1,000 pt'), findsOneWidget);
    await tester.ensureVisible(find.text('もう一度遊ぶ'));
    await tester.tap(find.text('もう一度遊ぶ'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 10'), findsOneWidget);
  });
}
