import 'dart:math';

import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/game/station_choices.dart';
import 'package:ekidoko/map/station_map.dart';
import 'package:ekidoko/screens/app_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/catalog.dart';

Station copyStation(
  Station station, {
  String? id,
  String? name,
  String? prefecture,
  String? region,
  bool? enabled,
}) => Station(
  id: id ?? station.id,
  name: name ?? station.name,
  nameKana: station.nameKana,
  latitude: station.latitude,
  longitude: station.longitude,
  prefecture: prefecture ?? station.prefecture,
  region: region ?? station.region,
  difficulty: station.difficulty,
  enabled: enabled ?? station.enabled,
  easyEligible: station.easyEligible,
  hasHighSpeedRailway: station.hasHighSpeedRailway,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Easy is initially selected and samples the entire Easy-eligible pool',
    () {
      final game = Game(catalog: catalog);
      expect(game.difficulty, GameDifficulty.easy);
      game.dispose();
      final answer = stations.firstWhere((s) => s.id == 'shinjuku');
      final seen = <String>{};
      for (var seed = 0; seed < 200; seed++) {
        final options = StationChoiceGenerator(
          stations: stations,
          random: Random(seed),
        ).generate(answer, difficulty: GameDifficulty.easy);
        seen.addAll(options.where((s) => s.id != answer.id).map((s) => s.id));
      }
      expect(
        seen,
        stations
            .where((s) => s.easyEligible && s.id != answer.id)
            .map((s) => s.id)
            .toSet(),
      );
    },
  );

  test('Easy choices do not depend on prefecture or region metadata', () {
    final changedRegions = [
      for (final s in stations)
        copyStation(s, prefecture: '全駅同じ県', region: '全駅同じ地方'),
    ];
    for (var seed = 0; seed < 30; seed++) {
      final original = StationChoiceGenerator(
        stations: stations,
        random: Random(seed),
      ).generate(stations.first, difficulty: GameDifficulty.easy);
      final changed = StationChoiceGenerator(
        stations: changedRegions,
        random: Random(seed),
      ).generate(changedRegions.first, difficulty: GameDifficulty.easy);
      expect(
        original.map((s) => s.id),
        orderedEquals(changed.map((s) => s.id)),
      );
    }
  });

  test(
    'Easy uses eligible major stations and Hard keeps the complete station pool',
    () {
      final easy = Game(catalog: catalog, random: Random(17))..start();
      final hard = Game(catalog: catalog, random: Random(17))
        ..selectDifficulty(GameDifficulty.hard)
        ..start();
      expect(easy.questions.every((s) => s.easyEligible), true);
      expect(
        easy.stationsFor(GameDifficulty.easy).every((s) => s.easyEligible),
        true,
      );
      expect(hard.stationsFor(GameDifficulty.hard), orderedEquals(stations));
      var changedChoices = false;
      while (!easy.finished) {
        final easyIds = easy.choices.map((s) => s.id).toSet();
        final hardIds = hard.choices.map((s) => s.id).toSet();
        changedChoices |= !easyIds.containsAll(hardIds);
        if (hard.station.prefecture == '東京都') {
          expect(hard.choices.every((s) => s.prefecture == '東京都'), true);
        }
        easy.submitChoice(easy.station);
        hard.submitChoice(hard.station);
        easy.next();
        hard.next();
      }
      expect(changedChoices, true);
      expect(easy.score, 1000);
      expect(hard.score, 1000);
      easy.dispose();
      hard.dispose();
    },
  );

  test('result rating is available only after a game is completed', () {
    final game = Game(catalog: catalog, random: Random(31));
    expect(game.resultRating, isNull);
    game.selectDifficulty(GameDifficulty.hard);
    game.start();
    expect(game.resultRating, isNull);

    while (!game.finished) {
      game.submitChoice(game.station);
      game.next();
    }

    expect(game.resultRating?.points, 1100);
    expect(game.resultRating?.rank, ResultRank.ss);
    game.home();
    expect(game.resultRating, isNull);
    game.dispose();
  });

  for (final difficulty in GameDifficulty.values) {
    test(
      '${difficulty.label} excludes disabled stations and duplicate display names',
      () {
        final answer = stations.first;
        final pool = [
          ...stations,
          copyStation(answer, id: 'answer_duplicate'),
          copyStation(stations[1], id: 'distractor_duplicate'),
          copyStation(answer, id: 'disabled', name: '無効な駅', enabled: false),
        ];
        for (var seed = 0; seed < 50; seed++) {
          final options = StationChoiceGenerator(
            stations: pool,
            random: Random(seed),
          ).generate(answer, difficulty: difficulty);
          expect(options, hasLength(4));
          expect(options.map((s) => s.id).toSet(), hasLength(4));
          expect(options.map((s) => s.name).toSet(), hasLength(4));
          expect(options.where((s) => s.id == answer.id), hasLength(1));
          expect(options.any((s) => s.id == 'answer_duplicate'), false);
          expect(options.every((s) => s.enabled), true);
        }
      },
    );

    test(
      '${difficulty.label} is locked through play/results and retained on replay',
      () {
        final game = Game(catalog: catalog, random: Random(8))
          ..selectDifficulty(difficulty)
          ..start();
        final other = difficulty == GameDifficulty.easy
            ? GameDifficulty.hard
            : GameDifficulty.easy;
        for (var question = 0; question < 10; question++) {
          expect(game.selectDifficulty(other), false);
          expect(game.difficulty, difficulty);
          final choices = List<Station>.of(game.choices);
          for (var hint = 0; hint < 3; hint++) {
            game.revealHint();
            expect(game.selectDifficulty(other), false);
            expect(game.choices, orderedEquals(choices));
          }
          game.submitChoice(game.station);
          expect(game.selectDifficulty(other), false);
          game.next();
        }
        expect(game.finished, true);
        expect(game.score, 100);
        expect(game.selectDifficulty(other), false);
        game.start();
        expect(game.difficulty, difficulty);
        expect(game.answers, isEmpty);
        expect(game.score, 0);
        expect(game.hint, 0);
        game.home();
        expect(game.selectDifficulty(other), true);
        game.start();
        expect(game.difficulty, other);
        game.dispose();
      },
    );

    testWidgets(
      '${difficulty.label} home selection, quiz/results label, replay and return home',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        final game = Game(catalog: catalog, random: Random(17));
        await tester.pumpWidget(
          MaterialApp(
            home: AppScreen(game: game, mapBuilder: mockMapBuilder),
          ),
        );
        final selector = find.byKey(const ValueKey('difficulty-selector'));
        final startButton = find.ancestor(
          of: find.text('ゲームをはじめる'),
          matching: find.byType(FilledButton),
        );
        expect(tester.getRect(selector).bottom, lessThanOrEqualTo(810));
        expect(tester.getRect(startButton).bottom, lessThanOrEqualTo(810));
        expect(
          tester.widget<SegmentedButton<GameDifficulty>>(selector).selected,
          {GameDifficulty.easy},
        );
        final option = find.descendant(
          of: selector,
          matching: find.text(difficulty.label),
        );
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(
          tester.widget<SegmentedButton<GameDifficulty>>(selector).selected,
          {difficulty},
        );
        expect(game.difficulty, difficulty);
        await tester.ensureVisible(find.text('ゲームをはじめる'));
        await tester.tap(find.text('ゲームをはじめる'));
        await tester.pumpAndSettle();
        final quizLabel = find.byKey(const ValueKey('quiz-difficulty'));
        expect(tester.widget<Text>(quizLabel).data, difficulty.label);
        expect(selector, findsNothing);
        for (var question = 0; question < 10; question++) {
          final choice = question == 1
              ? game.choices.firstWhere((s) => s.id != game.station.id)
              : game.station;
          final option = find.byKey(ValueKey('choice-${choice.id}'));
          await tester.ensureVisible(option);
          await tester.tap(option);
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('この駅で回答する'));
          await tester.tap(find.text('この駅で回答する'));
          await tester.pumpAndSettle();
          final next = find.text(question == 9 ? 'ランクを見る' : '次の問題へ');
          await tester.ensureVisible(next);
          await tester.tap(next);
          await tester.pumpAndSettle();
          expect(game.difficulty, difficulty);
        }
        expect(game.score, 900);
        expect(game.correctCount, 9);
        final expectedRankPoints = difficulty == GameDifficulty.easy
            ? '900 pt'
            : '990 pt';
        expect(find.byKey(const ValueKey('rank-reveal-popup')), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('rank-reveal-points')))
              .data,
          'ランクポイント $expectedRankPoints',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('rank-reveal-rank')))
              .data,
          'S',
        );
        await tester.tap(find.byKey(const ValueKey('rank-reveal-popup')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('result-rank-points')))
              .data,
          expectedRankPoints,
        );
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('result-rank'))).data,
          'S',
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('result-difficulty')),
            matching: find.text(difficulty.label),
          ),
          findsOneWidget,
        );
        await tester.ensureVisible(find.text('もう一度遊ぶ'));
        await tester.tap(find.text('もう一度遊ぶ'));
        await tester.pumpAndSettle();
        expect(tester.widget<Text>(quizLabel).data, difficulty.label);
        expect(game.answers, isEmpty);
        expect(game.score, 0);
        await tester.ensureVisible(find.byTooltip('ゲームを終了'));
        await tester.tap(find.byTooltip('ゲームを終了'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('終了する'));
        await tester.pumpAndSettle();
        final other = difficulty == GameDifficulty.easy
            ? GameDifficulty.hard
            : GameDifficulty.easy;
        final otherOption = find.descendant(
          of: selector,
          matching: find.text(other.label),
        );
        await tester.ensureVisible(otherOption);
        await tester.tap(otherOption);
        await tester.pumpAndSettle();
        expect(game.difficulty, other);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        game.dispose();
      },
    );
  }
}
