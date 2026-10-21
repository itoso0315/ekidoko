import 'dart:convert';
import 'dart:math';

import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/game/station_choices.dart';
import 'package:ekidoko/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/catalog.dart';

Station candidate(
  String id, {
  String? name,
  String prefecture = '東京都',
  String region = '関東',
  bool enabled = true,
  bool hasHighSpeedRailway = false,
}) => Station(
  id: id,
  name: name ?? id,
  nameKana: id,
  latitude: 35,
  longitude: 139,
  prefecture: prefecture,
  region: region,
  difficulty: 1,
  enabled: enabled,
  hasHighSpeedRailway: hasHighSpeedRailway,
);

List<Station> options(List<Station> pool, {int seed = 0}) =>
    StationChoiceGenerator(
      stations: pool,
      random: Random(seed),
    ).generate(pool.first, difficulty: GameDifficulty.hard);

Set<String> ids(Iterable<Station> values) => values.map((s) => s.id).toSet();

StationCatalog expandedCatalog(int count, {bool sameName = false}) {
  const regions = ['北海道', '東北', '関東', '中部', '近畿', '中国', '四国', '九州'];
  // Synthetic unit-test metadata; never used by the app or native map tests.
  return StationCatalog.parse(
    jsonEncode([
      for (var i = 0; i < count; i++)
        {
          'id': 'test_$i',
          'name': sameName ? '同名' : '検証$i',
          'nameKana': 'けんしょう$i',
          'latitude': 30 + i * .01,
          'longitude': 135,
          'prefecture': '${regions[i % 8]}${(i ~/ 8) % 3}県',
          'region': regions[i % 8],
          'difficulty': 1,
          'enabled': true,
          'easyEligible': true,
          'hasHighSpeedRailway': false,
        },
    ]),
  );
}

void main() {
  test('enough same-prefecture distractors exclude every lower tier', () {
    final pool = [
      candidate('answer'),
      for (var i = 0; i < 5; i++) candidate('local_$i'),
      candidate('regional', prefecture: '神奈川県'),
      candidate('neighbor', prefecture: '愛知県', region: '中部'),
      candidate('national', prefecture: '福岡県', region: '九州'),
    ];
    final selectedSets = <String>{};
    for (var seed = 0; seed < 100; seed++) {
      final selected = options(pool, seed: seed);
      expect(selected, hasLength(4));
      expect(selected.every((s) => s.prefecture == '東京都'), true);
      final wrongIds = ids(selected)..remove('answer');
      selectedSets.add((wrongIds.toList()..sort()).join(','));
    }
    // Selection within the preferred tier is random as well as final ordering.
    expect(selectedSets.length, greaterThan(1));
  });

  test('same region fills only the shortage after same prefecture', () {
    final pool = [
      candidate('answer'),
      candidate('local'),
      for (var i = 0; i < 4; i++) candidate('regional_$i', prefecture: '神奈川県'),
      candidate('neighbor', prefecture: '愛知県', region: '中部'),
      candidate('national', prefecture: '福岡県', region: '九州'),
    ];
    for (var seed = 0; seed < 30; seed++) {
      final selected = options(pool, seed: seed);
      expect(ids(selected), containsAll(['answer', 'local']));
      expect(selected.where((s) => s.id.startsWith('regional_')), hasLength(2));
      expect(selected.every((s) => s.region == '関東'), true);
    }
  });

  test('Hard Shinkansen answers only use stations with verified Shinkansen track', () {
    final pool = [
      candidate('answer', hasHighSpeedRailway: true),
      candidate('local_shinkansen', hasHighSpeedRailway: true),
      candidate(
        'regional_shinkansen',
        prefecture: '神奈川県',
        hasHighSpeedRailway: true,
      ),
      candidate(
        'national_shinkansen',
        prefecture: '福岡県',
        region: '九州',
        hasHighSpeedRailway: true,
      ),
      for (var i = 0; i < 5; i++) candidate('ordinary_$i'),
    ];
    final generator = StationChoiceGenerator(
      stations: pool,
      random: Random(3),
    );

    for (var seed = 0; seed < 30; seed++) {
      final selected = generator.generate(
        pool.first,
        difficulty: GameDifficulty.hard,
      );
      expect(selected, hasLength(4));
      expect(selected.every((station) => station.hasHighSpeedRailway), true);
    }
  });

  test('adjacent regions fill only the shortage after the same region', () {
    final pool = [
      candidate('answer'),
      candidate('local'),
      candidate('regional', prefecture: '神奈川県'),
      candidate('neighbor_chubu', prefecture: '愛知県', region: '中部'),
      candidate('neighbor_tohoku', prefecture: '宮城県', region: '東北'),
      candidate('national', prefecture: '福岡県', region: '九州'),
    ];
    final neighborsUsed = <String>{};
    for (var seed = 0; seed < 30; seed++) {
      final selected = ids(options(pool, seed: seed));
      expect(selected, containsAll(['answer', 'local', 'regional']));
      expect(selected, isNot(contains('national')));
      neighborsUsed.addAll(selected.where((id) => id.startsWith('neighbor_')));
    }
    expect(neighborsUsed, {'neighbor_chubu', 'neighbor_tohoku'});
  });

  test('nationwide pool fills the shortage when nearby regions are sparse', () {
    final pool = [
      candidate('answer', prefecture: '北海道', region: '北海道'),
      candidate('neighbor', prefecture: '宮城県', region: '東北'),
      candidate('remote_kanto'),
      candidate('remote_kinki', prefecture: '大阪府', region: '近畿'),
      candidate('remote_kyushu', prefecture: '福岡県', region: '九州'),
    ];
    for (var seed = 0; seed < 30; seed++) {
      final selected = ids(options(pool, seed: seed));
      expect(selected, hasLength(4));
      expect(selected, containsAll(['answer', 'neighbor']));
      expect(selected.where((id) => id.startsWith('remote_')), hasLength(2));
    }
  });

  test(
    'region spelling variants share one tier without changing catalog data',
    () {
      final kinki = [
        candidate('answer', prefecture: '京都府', region: '近畿'),
        candidate('osaka', prefecture: '大阪府', region: '近畿'),
        candidate('shin_osaka', prefecture: '大阪府', region: '関西'),
        candidate('sannomiya', prefecture: '兵庫県', region: '関西'),
        candidate('neighbor', prefecture: '愛知県', region: '中部'),
      ];
      expect(ids(options(kinki)), {
        'answer',
        'osaka',
        'shin_osaka',
        'sannomiya',
      });
      final chubu = [
        candidate('answer', prefecture: '愛知県', region: '中部'),
        candidate('kanazawa', prefecture: '石川県', region: '中部・北陸'),
        candidate('shizuoka', prefecture: '静岡県', region: '中部'),
        candidate('neighbor_kansai', prefecture: '大阪府', region: '関西'),
        candidate('national', prefecture: '福岡県', region: '九州'),
      ];
      expect(ids(options(chubu)), {
        'answer',
        'kanazawa',
        'shizuoka',
        'neighbor_kansai',
      });
    },
  );

  test(
    'unknown region still generates four choices using nationwide fallback',
    () {
      final pool = [
        candidate('answer', prefecture: '新地方県', region: '未知の地方'),
        candidate('a'),
        candidate('b', prefecture: '大阪府', region: '近畿'),
        candidate('c', prefecture: '福岡県', region: '九州'),
      ];
      expect(ids(options(pool)), {'answer', 'a', 'b', 'c'});
    },
  );

  test('different ids never duplicate answer or distractor display names', () {
    final pool = [
      candidate('answer', name: '東京'),
      candidate('answer_copy', name: '東京'),
      candidate('answer_suffix', name: ' 東京 駅 '),
      candidate('ueno', name: '上野'),
      candidate('ueno_copy', name: '上野'),
      candidate('nagoya', name: '名古屋', prefecture: '愛知県', region: '中部'),
      candidate('kyoto', name: '京都', prefecture: '京都府', region: '近畿'),
    ];
    for (var seed = 0; seed < 50; seed++) {
      final selected = options(pool, seed: seed);
      expect(ids(selected), hasLength(4));
      expect(selected.map((s) => s.name).toSet(), {'東京', '上野', '名古屋', '京都'});
      expect(selected.where((s) => s.id == 'answer'), hasLength(1));
      expect(ids(selected), isNot(contains('answer_copy')));
      expect(ids(selected), isNot(contains('answer_suffix')));
    }
  });

  test('a remote duplicate name cannot displace a higher-priority station', () {
    final pool = [
      candidate('answer', name: '東京'),
      candidate('remote_copy', name: '上野', prefecture: '福岡県', region: '九州'),
      candidate('local_ueno', name: '上野'),
      candidate('shibuya', name: '渋谷'),
      candidate('shinjuku', name: '新宿'),
    ];
    for (var seed = 0; seed < 30; seed++) {
      expect(ids(options(pool, seed: seed)), {
        'answer',
        'local_ueno',
        'shibuya',
        'shinjuku',
      });
    }
  });

  test('disabled stations and duplicate ids cannot enter choices', () {
    final pool = [
      candidate('answer'),
      candidate('disabled', enabled: false),
      candidate('local'),
      candidate('local'),
      candidate('regional', prefecture: '神奈川県'),
      candidate('neighbor', prefecture: '愛知県', region: '中部'),
    ];
    expect(ids(options(pool)), {'answer', 'local', 'regional', 'neighbor'});
  });

  test(
    'fewer than four distinct enabled station names gives an actionable error',
    () {
      for (final pool in [
        <Station>[],
        [candidate('a'), candidate('b'), candidate('c')],
        [
          candidate('a'),
          candidate('b'),
          candidate('c'),
          candidate('disabled', enabled: false),
        ],
        [
          candidate('a', name: '同名'),
          candidate('b', name: '同名'),
          candidate('c'),
          candidate('d'),
        ],
      ]) {
        expect(
          () => StationChoiceGenerator(stations: pool),
          throwsA(
            isA<StationDataException>().having(
              (e) => e.toString(),
              'reason and data field',
              allOf(
                contains('4駅以上'),
                contains('enabled'),
                contains('name'),
                contains('現在:'),
              ),
            ),
          ),
        );
      }
    },
  );

  test('answer must belong to the currently available station pool', () {
    final generator = StationChoiceGenerator(
      stations: [
        candidate('a'),
        candidate('b'),
        candidate('c'),
        candidate('d'),
        candidate('disabled', enabled: false),
      ],
    );
    for (final answer in [
      candidate('outside'),
      candidate('disabled', enabled: false),
    ]) {
      expect(
        () => generator.generate(answer, difficulty: GameDifficulty.hard),
        throwsA(
          isA<StationDataException>().having(
            (e) => e.toString(),
            'answer id',
            contains(answer.id),
          ),
        ),
      );
    }
  });

  test('final order is random and correct choice occupies every position', () {
    final pool = [
      candidate('answer'),
      candidate('a'),
      candidate('b'),
      candidate('c'),
    ];
    final orders = <String>{};
    final correctPositions = <int>{};
    for (var seed = 0; seed < 100; seed++) {
      final selected = options(pool, seed: seed);
      orders.add(selected.map((s) => s.id).join(','));
      correctPositions.add(selected.indexWhere((s) => s.id == 'answer'));
      expect(selected.where((s) => s.id == 'answer'), hasLength(1));
      expect(ids(selected), hasLength(4));
    }
    expect(orders.length, greaterThan(1));
    expect(correctPositions, {0, 1, 2, 3});
    expect(options(pool, seed: 7), orderedEquals(options(pool, seed: 7)));
  });

  test(
    'adjacency setting has no self-links and all connections are symmetric',
    () {
      for (final entry in adjacentRegions.entries) {
        expect(entry.value, isNot(contains(entry.key)));
        expect(entry.value.toSet().length, entry.value.length);
        for (final neighbor in entry.value) {
          expect(adjacentRegions[neighbor], contains(entry.key));
        }
      }
    },
  );

  test('actual twenty-station examples use the whole available catalog', () {
    final generator = StationChoiceGenerator(
      stations: phase2Catalog.stations,
      random: Random(8),
    );
    Station station(String id) =>
        phase2Catalog.stations.firstWhere((s) => s.id == id);
    List<Station> generate(String id) =>
        generator.generate(station(id), difficulty: GameDifficulty.hard);
    for (final id in ['shin_osaka', 'kyoto', 'tokyo', 'nagoya', 'hakata']) {
      final answer = station(id);
      final selected = generate(id);
      expect(selected, contains(answer));
      expect(selected, hasLength(4));
      if (answer.hasHighSpeedRailway) {
        expect(selected.every((s) => s.hasHighSpeedRailway), true, reason: id);
      }
    }
    final tokyo = generate('tokyo');
    expect(tokyo.every((s) => s.hasHighSpeedRailway), true);
    final tokyoShinkansenStations = phase2Catalog.stations.where(
      (s) =>
          s.id != 'tokyo' &&
          s.prefecture == '東京都' &&
          s.hasHighSpeedRailway,
    );
    expect(tokyo, containsAll(tokyoShinkansenStations));
    final nagoya = generate('nagoya');
    expect(nagoya.every((s) => s.hasHighSpeedRailway), true);
    expect(nagoya.every((s) => s.region.isNotEmpty), true);
    expect(ids(generate('sapporo')), containsAll(['sapporo', 'sendai']));
    expect(ids(generate('hakata')), containsAll(['hakata', 'hiroshima']));
    var usedStationOutsideQuestions = false;
    for (var seed = 0; seed < 20; seed++) {
      final game = Game(catalog: catalog, random: Random(seed))..start();
      final questionIds = ids(game.questions);
      while (!game.finished) {
        usedStationOutsideQuestions |= game.choices.any(
          (s) => !questionIds.contains(s.id),
        );
        game.submitChoice(game.station);
        game.next();
      }
      game.dispose();
    }
    expect(usedStationOutsideQuestions, true);
  });

  for (final count in [20, 50, 100, 120]) {
    for (final difficulty in GameDifficulty.values) {
      test(
        '$count stations support ${difficulty.label} questions, scoring and replay',
        () {
          final source = count == 20
              ? phase2Catalog
              : count == 50
              ? catalog
              : expandedCatalog(count);
          for (var seed = 0; seed < 10; seed++) {
            final game = Game(catalog: source, random: Random(seed))
              ..selectDifficulty(difficulty)
              ..start();
            expect(game.questions, hasLength(10));
            expect(ids(game.questions), hasLength(10));
            var expectedScore = 0;
            for (var question = 0; question < 10; question++) {
              final choices = List<Station>.of(game.choices);
              expect(choices, hasLength(4));
              expect(ids(choices), hasLength(4));
              expect(choices.map((s) => s.name).toSet(), hasLength(4));
              expect(
                choices.where((s) => s.id == game.station.id),
                hasLength(1),
              );
              expect(choices.every((s) => source.select().contains(s)), true);
              final hint = question % 4;
              for (var i = 0; i < hint; i++) {
                game.revealHint();
              }
              expect(game.choices, orderedEquals(choices));
              final correct = question != 9;
              final choice = correct
                  ? game.station
                  : choices.firstWhere((s) => s.id != game.station.id);
              expect(game.submitChoice(choice), true);
              expectedScore += correct ? Game.points[hint] : 0;
              expect(game.submitChoice(game.station), false);
              game.revealHint();
              expect(game.hint, hint);
              game.next();
            }
            expect(game.finished, true);
            expect(game.score, expectedScore);
            expect(game.correctCount, 9);
            expect(game.difficulty, difficulty);
            game.start();
            expect(game.difficulty, difficulty);
            expect(game.index, 0);
            expect(game.score, 0);
            expect(game.answers, isEmpty);
            expect(game.hint, 0);
            expect(game.finished, false);
            expect(game.choices, hasLength(4));
            game.dispose();
          }
        },
      );
    }
  }

  testWidgets(
    'insufficient unique choice names use the existing error and retry UI',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CatalogScreen(
            loader: () async {
              return attempts++ == 0
                  ? expandedCatalog(10, sameName: true)
                  : catalog;
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text('駅データを読み込めませんでした'), findsOneWidget);
      expect(find.textContaining('4駅以上'), findsOneWidget);
      expect(find.textContaining('test_0: 同名'), findsOneWidget);
      expect(find.text('ゲームをはじめる'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('再読み込み'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Ekidoko'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
