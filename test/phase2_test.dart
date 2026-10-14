import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/map/quiz_map_style.dart';
import 'support/catalog.dart';

const addedIds = {
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
};
void main() {
  test('verified OSM coordinates match the ten new catalog rows exactly', () {
    final sources =
        jsonDecode(
              File('docs/station-coordinate-sources.json').readAsStringSync(),
            )
            as Map;
    final nodes = {
      for (final node in sources['stations'] as List) node['id']: node,
    };
    expect(stations.take(20).map((s) => s.id).toSet().length, 20);
    expect(catalog.select().length, greaterThanOrEqualTo(20));
    expect(stations.skip(10).take(10).map((s) => s.id).toSet(), addedIds);
    for (final s in stations.skip(10).take(10)) {
      final node = nodes[s.osmNodeId];
      expect(node, isNotNull, reason: s.id);
      expect(s.name, node['tags']['name']);
      expect(node['tags']['railway'], 'station');
      expect(s.latitude, node['lat']);
      expect(s.longitude, node['lon']);
    }
    final takamatsu = stations.singleWhere((s) => s.id == 'takamatsu');
    expect(takamatsu.prefecture, '香川県');
    expect(takamatsu.latitude, inInclusiveRange(34.3, 34.4));
    expect(stations.singleWhere((s) => s.id == 'sannomiya').name, '三ノ宮');
  });
  test(
    'all catalog stations occur over repeated random games; choices and scores stay valid',
    () {
      final seen = <String>{};
      for (var seed = 0; seed < 50; seed++) {
        final game = Game(catalog: catalog, random: Random(seed))
          ..selectDifficulty(GameDifficulty.hard)
          ..start();
        expect(game.questionCount, 10);
        expect(game.maxScore, 1000);
        expect(game.questions.map((s) => s.id).toSet().length, 10);
        var expectedScore = 0;
        for (var i = 0; i < 10; i++) {
          seen.add(game.station.id);
          final choices = List<Station>.of(game.choices);
          expect(choices.length, 4);
          expect(choices.map((s) => s.id).toSet().length, 4);
          expect(choices.where((s) => s.id == game.station.id).length, 1);
          expect(choices.every((s) => catalog.select().contains(s)), true);
          final hint = i % 4;
          for (var j = 0; j < hint; j++) {
            game.revealHint();
          }
          expect(game.choices, orderedEquals(choices));
          final correct = i % 5 != 0;
          final choice = correct
              ? game.station
              : choices.firstWhere((s) => s.id != game.station.id);
          expect(game.submitChoice(choice), true);
          expect(game.submitChoice(choices.first), false);
          game.revealHint();
          expect(game.hint, hint);
          expectedScore += correct ? Game.points[hint] : 0;
          game.next();
        }
        expect(game.finished, true);
        expect(game.score, expectedScore);
        game.start();
        expect(game.answers, isEmpty);
        expect(game.score, 0);
        expect(game.hint, 0);
        expect(game.index, 0);
        game.dispose();
      }
      expect(seen, stations.map((s) => s.id).toSet());
    },
  );
  test('all catalog hints are real, safe, and geolocated', () {
    final data =
        jsonDecode(File('assets/maps/station_hints.json').readAsStringSync())
            as Map;
    expect(
      data.keys.where((s) => !s.toString().startsWith('_')).length,
      stations.length,
    );
    for (final s in stations) {
      final row = data[s.id];
      expect(row, isNotNull, reason: s.id);
      expect(row['latitude'], s.latitude);
      expect(row['longitude'], s.longitude);
      final rails = row['railways']['features'] as List;
      final labels = row['labels']['features'] as List;
      expect(rails, isNotEmpty, reason: s.id);
      expect(labels, isNotEmpty, reason: s.id);
      expect(labels.length, lessThanOrEqualTo(36));
      for (final rail in rails) {
        expect(
          isUsefulRailwayLabel(s, rail['properties']['name'] as String),
          true,
          reason: s.id,
        );
        expect(rail['properties']['osm_way_ids'], isNotEmpty);
        expect(rail['geometry']['type'], 'LineString');
        expect(
          (rail['geometry']['coordinates'] as List).length,
          greaterThanOrEqualTo(2),
        );
      }
      for (final label in labels) {
        expect(
          isSafeHintLabel(s, label['properties']['name'] as String),
          true,
          reason: s.id,
        );
        expect(label['properties']['osm_id'], isPositive);
        expect(
          label['properties']['osm_type'],
          isIn(['node', 'way', 'relation']),
        );
        expect(label['geometry']['type'], 'Point');
      }
    }
    final sapporo = stations.singleWhere((s) => s.id == 'sapporo');
    expect(isUsefulRailwayLabel(sapporo, '札沼線'), true);
    expect(isSafeHintLabel(sapporo, '札駅前公園'), false);
    expect(isSafeHintLabel(sapporo, 'サツエキイーストパーク'), false);
    final hakata = stations.singleWhere((s) => s.id == 'hakata');
    expect(isSafeHintLabel(hakata, '博多駅前ビル'), false);
    expect(isSafeHintLabel(hakata, 'Hakata Station'), false);
    expect(isSafeHintLabel(hakata, '博多区'), true);
    final kobe = stations.singleWhere((s) => s.id == 'sannomiya');
    expect(isSafeHintLabel(kobe, '三宮駅前ビル'), false);
  });
}
