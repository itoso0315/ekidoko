import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/game/station_choices.dart';
import 'package:ekidoko/map/map_hint_data.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/catalog.dart';

const phase3Names = {
  'hakodate': ['函館', 'はこだて'],
  'asahikawa': ['旭川', 'あさひかわ'],
  'morioka': ['盛岡', 'もりおか'],
  'kita_senju': ['北千住', 'きたせんじゅ'],
  'akihabara': ['秋葉原', 'あきはばら'],
  'tachikawa': ['立川', 'たちかわ'],
  'kawasaki': ['川崎', 'かわさき'],
  'chiba': ['千葉', 'ちば'],
  'funabashi': ['船橋', 'ふなばし'],
  'kashiwa': ['柏', 'かしわ'],
  'kanayama': ['金山', 'かなやま'],
  'chikusa': ['千種', 'ちくさ'],
  'gifu': ['岐阜', 'ぎふ'],
  'hamamatsu': ['浜松', 'はままつ'],
  'nagano': ['長野', 'ながの'],
  'niigata': ['新潟', 'にいがた'],
  'tennoji': ['天王寺', 'てんのうじ'],
  'kyobashi_osaka': ['京橋', 'きょうばし'],
  'namba_nankai': ['難波', 'なんば'],
  'nara': ['奈良', 'なら'],
  'kobe_jr': ['神戸', 'こうべ'],
  'okayama': ['岡山', 'おかやま'],
  'fukuyama': ['福山', 'ふくやま'],
  'matsue': ['松江', 'まつえ'],
  'tokushima': ['徳島', 'とくしま'],
  'kochi': ['高知', 'こうち'],
  'kokura': ['小倉', 'こくら'],
  'kumamoto': ['熊本', 'くまもと'],
  'kagoshima_chuo': ['鹿児島中央', 'かごしまちゅうおう'],
  'kurume': ['久留米', 'くるめ'],
};

void main() {
  test(
    'municipal tram hints keep real branch names and unchanged source vertices',
    () {
      final source =
          jsonDecode(
                File('test/fixtures/hakodate_tram.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final station = stations.singleWhere((s) => s.id == 'hakodate');
      final hints = mapHintsFromOsm(station, source);
      final railways = hints.railways['features'] as List;
      expect(railways, hasLength(2));
      for (final feature in railways) {
        expect(feature['properties']['name'], '大森線');
        expect(
          isUsefulRailwayLabel(station, feature['properties']['name']),
          true,
        );
        final id = (feature['properties']['osm_way_ids'] as List).single;
        final original = (source['elements'] as List).singleWhere(
          (row) => row['id'] == id,
        );
        expect(
          feature['geometry']['coordinates'],
          (original['geometry'] as List)
              .map((p) => [p['lon'], p['lat']])
              .toList(),
        );
      }
      expect(isSafeHintLabel(station, '函館駅前ビル'), false);
    },
  );
  test(
    'exactly fifty enabled stations preserve every original twenty field',
    () {
      final actual =
          jsonDecode(File('assets/data/stations.json').readAsStringSync())
              as List;
      final original =
          jsonDecode(
                File('test/fixtures/stations_phase2.json').readAsStringSync(),
              )
              as List;
      expect(actual, hasLength(50));
      expect(
        actual
            .take(20)
            .map((row) => Map.of(row as Map)..remove('easyEligible'))
            .toList(),
        original,
      );
      expect(catalog.select(), hasLength(50));
      expect(stations.map((s) => s.id).toSet(), hasLength(50));
      expect(stations.map((s) => s.osmNodeId).toSet(), hasLength(50));
      expect(
        stations.skip(20).map((s) => s.id).toSet(),
        phase3Names.keys.toSet(),
      );
      for (final s in stations.skip(20)) {
        expect([s.name, s.nameKana], phase3Names[s.id]);
        expect(s.region, isIn(adjacentRegions.keys));
        expect(s.prefecture, isNotEmpty);
        expect(
          s.difficulty,
          1,
        ); // Provisional station difficulty; not a mode filter.
        expect(s.enabled, true);
      }
    },
  );

  test(
    'Easy eligibility is explicit, includes the original ten and key nationwide stations',
    () {
      final rows =
          jsonDecode(File('assets/data/stations.json').readAsStringSync())
              as List;
      expect(rows.every((row) => row['easyEligible'] is bool), true);
      expect(stations.take(10).every((s) => s.easyEligible), true);
      expect(
        stations.where((s) => s.easyEligible).length,
        greaterThanOrEqualTo(10),
      );
      expect(
        stations
            .where(
              (s) =>
                  ['sapporo', 'sendai', 'hiroshima', 'hakata'].contains(s.id),
            )
            .every((s) => s.easyEligible),
        true,
      );
      expect(stations.any((s) => !s.easyEligible), true);
    },
  );

  test(
    'too few Easy stations stops startup with an identified eligibility error',
    () {
      final rows =
          jsonDecode(File('assets/data/stations.json').readAsStringSync())
              as List;
      final limited = StationCatalog.parse(
        jsonEncode([
          for (var i = 0; i < rows.length; i++)
            {...rows[i] as Map, 'easyEligible': i < 9},
        ]),
      );
      expect(
        () => Game(catalog: limited),
        throwsA(
          isA<StationDataException>().having(
            (e) => e.toString(),
            'Easy reason',
            allOf(
              contains('Easy'),
              contains('10駅以上'),
              contains('easyEligible'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'new coordinates equal source nodes and ambiguous stations select the intended operator',
    () {
      final data =
          jsonDecode(
                File('docs/station-coordinate-sources.json').readAsStringSync(),
              )
              as Map;
      final nodes = {
        for (final node in data['stations'] as List) node['id']: node,
      };
      final selections = {
        for (final row in data['stationSelections'] as List)
          row['stationId']: row,
      };
      for (final s in stations.skip(20)) {
        final node = nodes[s.osmNodeId];
        expect(node, isNotNull, reason: s.id);
        expect(node['tags']['railway'], 'station');
        expect(node['tags']['name'], s.name);
        expect(s.latitude, node['lat']);
        expect(s.longitude, node['lon']);
        expect(selections[s.id]['osmNodeId'], s.osmNodeId);
        expect(selections[s.id]['selectionReason'], isNotEmpty);
      }
      Station station(String id) => stations.singleWhere((s) => s.id == id);
      final namba = nodes[station('namba_nankai').osmNodeId];
      expect(namba['tags']['operator'], '南海電気鉄道');
      expect(namba['tags']['ref'], 'NK01');
      final kobe = station('kobe_jr');
      expect(kobe.prefecture, '兵庫県');
      expect(nodes[kobe.osmNodeId]['tags']['wikipedia'], 'ja:神戸駅 (兵庫県)');
      final kyobashi = station('kyobashi_osaka');
      expect(kyobashi.prefecture, '大阪府');
      expect(nodes[kyobashi.osmNodeId]['tags']['ref'], 'JR-H41;JR-O08');
      final kokura = station('kokura');
      expect(kokura.prefecture, '福岡県');
      expect(nodes[kokura.osmNodeId]['tags']['operator'], '九州旅客鉄道');
    },
  );

  test(
    'Hard fifty-station choices preserve same-prefecture priority for every station',
    () {
      for (final answer in stations) {
        final local = stations
            .where(
              (s) =>
                  s.id != answer.id &&
                  s.prefecture == answer.prefecture &&
                  (!answer.hasHighSpeedRailway || s.hasHighSpeedRailway),
            )
            .toList();
        for (var seed = 0; seed < 30; seed++) {
          final choices = StationChoiceGenerator(
            stations: stations,
            random: Random(seed),
          ).generate(answer, difficulty: GameDifficulty.hard);
          final wrong = choices.where((s) => s.id != answer.id).toList();
          if (answer.hasHighSpeedRailway) {
            expect(
              choices.every((s) => s.hasHighSpeedRailway),
              true,
              reason: answer.id,
            );
          }
          if (local.length >= 3) {
            expect(
              wrong.every((s) => s.prefecture == answer.prefecture),
              true,
              reason: answer.id,
            );
          } else {
            expect(
              wrong.map((s) => s.id),
              containsAll(local.map((s) => s.id)),
              reason: answer.id,
            );
          }
          expect(choices.map((s) => s.id).toSet(), hasLength(4));
          expect(choices.map((s) => s.name).toSet(), hasLength(4));
          expect(choices.where((s) => s.id == answer.id), hasLength(1));
        }
      }
    },
  );

  test(
    'Hard supplements Hokkaido from Tohoku and Aichi from Chubu at fifty stations',
    () {
      final generator = StationChoiceGenerator(
        stations: stations,
        random: Random(27),
      );
      for (final id in ['sapporo', 'hakodate', 'asahikawa']) {
        final answer = stations.singleWhere((s) => s.id == id);
        final choices = generator.generate(
          answer,
          difficulty: GameDifficulty.hard,
        );
        expect(choices.where((s) => s.prefecture == '北海道'), hasLength(3));
        expect(choices.where((s) => s.region == '東北'), hasLength(1));
      }
      for (final id in ['nagoya', 'kanayama', 'chikusa']) {
        final answer = stations.singleWhere((s) => s.id == id);
        final choices = generator.generate(
          answer,
          difficulty: GameDifficulty.hard,
        );
        if (answer.hasHighSpeedRailway) {
          expect(choices.every((s) => s.hasHighSpeedRailway), true);
        } else {
          expect(choices.where((s) => s.prefecture == '愛知県'), hasLength(3));
        }
        expect(choices.every((s) => ['中部', '中部・北陸'].contains(s.region)), true);
      }
    },
  );

  for (final difficulty in GameDifficulty.values) {
    test(
      '${difficulty.label} covers its eligible pool, ten-question scoring, lock and replay',
      () {
        final seen = <String>{};
        for (var seed = 0; seed < 100; seed++) {
          final game = Game(catalog: catalog, random: Random(seed))
            ..selectDifficulty(difficulty)
            ..start();
          expect(game.questions, hasLength(10));
          expect(game.questions.map((s) => s.id).toSet(), hasLength(10));
          var expected = 0;
          while (!game.finished) {
            seen.add(game.station.id);
            if (difficulty == GameDifficulty.easy) {
              expect(game.station.easyEligible, true);
              expect(game.choices.every((s) => s.easyEligible), true);
            }
            final choices = List<Station>.of(game.choices);
            expect(choices, hasLength(4));
            expect(choices.map((s) => s.id).toSet(), hasLength(4));
            expect(choices.map((s) => s.name).toSet(), hasLength(4));
            expect(choices.where((s) => s.id == game.station.id), hasLength(1));
            expect(choices.every((s) => catalog.select().contains(s)), true);
            for (var h = 0; h < game.index % 4; h++) {
              game.revealHint();
            }
            expect(game.choices, orderedEquals(choices));
            final correct = game.index != 9;
            final choice = correct
                ? game.station
                : choices.firstWhere((s) => s.id != game.station.id);
            expected += correct ? Game.points[game.hint] : 0;
            expect(game.submitChoice(choice), true);
            expect(game.submitChoice(game.station), false);
            game.next();
          }
          expect(game.score, expected);
          expect(game.correctCount, 9);
          game.start();
          expect(game.difficulty, difficulty);
          expect(game.score, 0);
          expect(game.answers, isEmpty);
          expect(game.hint, 0);
          game.dispose();
        }
        final expectedPool = stations.where(
          (s) => difficulty == GameDifficulty.hard || s.easyEligible,
        );
        expect(seen, expectedPool.map((s) => s.id).toSet());
      },
    );
  }
}
