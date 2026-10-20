import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/main.dart';
import 'package:ekidoko/map/map_hint_data.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'support/catalog.dart';

void main() {
  final source =
      jsonDecode(File('assets/data/stations.json').readAsStringSync()) as List;
  test(
    'all fifty actual coordinates and independent station metadata are present',
    () {
      expect(stations.length, 50);
      for (final s in stations) {
        expect(s.latitude, inInclusiveRange(24, 46));
        expect(s.longitude, inInclusiveRange(122, 146));
        expect(s.osmNodeId, isPositive);
        expect(s.routes, isNotEmpty);
        expect(s.enabled, true);
      }
      expect(phase2Catalog.select(region: '近畿').map((s) => s.name).toSet(), {
        '大阪',
        '京都',
      });
      expect(
        phase2Catalog.select(prefecture: '愛知県', difficulty: 1).single.id,
        'nagoya',
      );
    },
  );
  test('invalid catalog identifies row and id for every required field', () {
    for (final field in [
      'id',
      'name',
      'nameKana',
      'latitude',
      'longitude',
      'prefecture',
      'region',
      'difficulty',
      'enabled',
      'easyEligible',
    ]) {
      final row = Map<String, dynamic>.from(source.first as Map)..remove(field);
      expect(
        () => StationCatalog.parse(jsonEncode([row])),
        throwsA(
          isA<StationDataException>().having(
            (e) => e.toString(),
            'field and row',
            allOf(contains(field), contains('1件目')),
          ),
        ),
      );
    }
    for (final values in [
      {'name': ' '},
      {'latitude': 91},
      {'longitude': 181},
      {'enabled': 'true'},
      {'easyEligible': 'true'},
      {'difficulty': 0},
    ]) {
      expect(
        () => StationCatalog.parse(
          jsonEncode([
            {...source.first as Map, ...values},
          ]),
        ),
        throwsA(isA<StationDataException>()),
      );
    }
    expect(
      () => StationCatalog.parse('{'),
      throwsA(isA<StationDataException>()),
    );
    expect(
      () => StationCatalog.parse(jsonEncode([source.first, source.first])),
      throwsA(
        isA<StationDataException>().having(
          (e) => e.toString(),
          'duplicate',
          contains('重複'),
        ),
      ),
    );
    expect(
      () => StationCatalog.parse(
        jsonEncode([
          source.first,
          {...source.first as Map, 'id': 'tokyo_copy'},
        ]),
      ),
      throwsA(
        isA<StationDataException>().having(
          (e) => e.toString(),
          'same station',
          contains('同じ駅'),
        ),
      ),
    );
  });
  test(
    '120 data-only stations yield ten unique questions and four stable choices',
    () {
      final rows = [
        for (var i = 0; i < 120; i++)
          {
            ...source.first as Map,
            'id': 'station_$i',
            'name': '駅名$i',
            'nameKana': 'よみ$i',
            'enabled': i != 119,
            'latitude': 30 + i * .01,
            'osmNodeId': 10000000 + i,
          },
      ];
      final expanded = StationCatalog.parse(jsonEncode(rows));
      final game = Game(catalog: expanded, random: Random(10))..start();
      expect(expanded.select().length, 119);
      expect(game.questions.length, 10);
      expect(game.questions.map((s) => s.id).toSet().length, 10);
      expect(game.questions.any((s) => !s.enabled), false);
      while (!game.finished) {
        expect(game.choices.map((s) => s.id).toSet().length, 4);
        expect(game.submitChoice(game.station), true);
        game.next();
      }
      expect(game.score, 1000);
      game.start();
      expect(game.answers, isEmpty);
    },
  );
  test('labels containing station names are rejected, including landmarks', () {
    final nagoya = stations.firstWhere((s) => s.id == 'nagoya');
    expect(isSafeHintLabel(nagoya, '名古屋駅前ビル'), false);
    expect(isSafeHintLabel(nagoya, 'Nagoya Station'), false);
    expect(isSafeHintLabel(nagoya, '名古屋城'), false);
    expect(isSafeHintLabel(nagoya, '名古屋ステーションギャラリー'), false);
    expect(isSafeHintLabel(nagoya, '名古屋キャラクターストリート'), false);
    final kyoto = stations.firstWhere((s) => s.id == 'kyoto');
    expect(isSafeHintLabel(kyoto, '京都タワー'), false);
    expect(isSafeHintLabel(kyoto, 'キョウト駅'), false);
    final hakata = stations.firstWhere((s) => s.id == 'hakata');
    expect(isSafeHintLabel(hakata, '博多区'), false);
    expect(isUsefulRailwayLabel(kyoto, '貨物線'), false);
  });
  test(
    'generic OSM importer uses source geometry and rejects incomplete data',
    () {
      final s = stations.first;
      final hints = mapHintsFromOsm(s, {
        'elements': [
          {
            'type': 'way',
            'id': 123,
            'tags': {'railway': 'rail', 'name': '中央本線'},
            'geometry': [
              {'lon': 139.76, 'lat': 35.68},
              {'lon': 139.77, 'lat': 35.69},
            ],
          },
          {
            'type': 'way',
            'id': 124,
            'tags': {'railway': 'rail', 'name': '貨物線'},
            'geometry': [],
          },
          {
            'type': 'node',
            'id': 456,
            'lon': 139.75,
            'lat': 35.68,
            'tags': {'name': '日比谷公園', 'leisure': 'park'},
          },
          {
            'type': 'node',
            'id': 457,
            'lon': 139.76,
            'lat': 35.68,
            'tags': {'name': '東京駅前公園', 'leisure': 'park'},
          },
        ],
      });
      expect(
        (hints.railways['features'] as List)
            .single['properties']['osm_way_ids'],
        [123],
      );
      expect(
        (hints.labels['features'] as List).single['properties']['name'],
        '日比谷公園',
      );
      expect(osmHintQuery(s), contains('${s.latitude},${s.longitude}'));
      expect(
        () => mapHintsFromOsm(s, {'remark': 'timed out', 'elements': []}),
        throwsFormatException,
      );
    },
  );
  testWidgets('catalog failure shows identified error and retry recovers', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CatalogScreen(
          loader: () async {
            if (attempts++ == 0) {
              throw const StationDataException([
                'stations.json 2件目 [broken]: latitude が不正です',
              ]);
            }
            return catalog;
          },
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('[broken]'), findsOneWidget);
    await tester.tap(find.text('再読み込み'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Ekidoko'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
