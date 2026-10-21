import 'support/catalog.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/map/home_map_preview.dart';
import 'package:ekidoko/map/real_station_map.dart';
import 'package:ekidoko/screens/app_screen.dart';
import 'package:ekidoko/map/station_map.dart';

void main() {
  test(
    'four choices include the correct station once and stay stable through hints',
    () {
      for (final seed in [17, 29]) {
        final game = Game(catalog: catalog, random: Random(seed))..start();
        while (!game.finished) {
          final choices = List<Station>.of(game.choices);
          expect(choices.length, 4);
          expect(choices.map((s) => s.id).toSet().length, 4);
          expect(choices.where((s) => s.id == game.station.id).length, 1);
          final excluded = stations.firstWhere((s) => !choices.contains(s));
          expect(game.submitChoice(excluded), false);
          game.revealHint();
          expect(game.choices, orderedEquals(choices));
          expect(game.submitChoice(game.station), true);
          expect(game.submitChoice(choices.first), false);
          game.next();
        }
        expect(game.score, game.questionCount * 70);
      }
    },
  );

  test('10 unique stations, hints, locked answers, score and restart', () {
    final game = Game(catalog: catalog, random: Random(42));
    game.start();
    expect(game.questions.map((s) => s.id).toSet().length, 10);
    for (var i = 0; i < 10; i++) {
      final hints = i % 4;
      for (var j = 0; j < hints; j++) {
        game.revealHint();
      }
      final correct = i != 9;
      expect(game.submit(correct ? '${game.station.kana}駅' : '存在しない駅'), true);
      final hint = game.hint;
      game.revealHint();
      expect(game.hint, hint);
      expect(game.submit(game.station.name), false);
      game.next();
    }
    expect(game.finished, true);
    expect(game.score, 540);
    expect(game.correctCount, 9);
    expect(game.noHintCount, 3);
    game.start();
    expect(game.score, 0);
    expect(game.answers, isEmpty);
    expect(game.hint, 0);
    expect(game.finished, false);
  });

  test('normalization and hint cap', () {
    expect(normalizeAnswer('シンジュク駅'), 'しんじゅく');
    final game = Game(catalog: catalog)..start();
    expect(game.submit('  '), false);
    for (var i = 0; i < 8; i++) {
      game.revealHint();
    }
    expect(game.hint, 3);
    expect(Game.points[game.hint], 10);
    expect(game.submit(' ${game.station.kana} 駅 '), true);
    expect(game.score, 10);
  });

  testWidgets('default home map preview uses bundled data without map tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScreen(game: Game(catalog: catalog)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(HomeMapPreview), findsOneWidget);
    expect(find.byType(RealStationMap), findsNothing);
    expect(find.text('地図を読み込んでいます…'), findsNothing);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
  });

  testWidgets('home to complete game and replay, including incorrect answer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = Game(catalog: catalog, random: Random(2));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AppScreen(game: game, mapBuilder: mockMapBuilder),
      ),
    );
    expect(find.text('Ekidoko'), findsOneWidget);
    expect(find.text('10問'), findsNothing);
    expect(find.text('4択クイズ'), findsNothing);
    expect(find.textContaining('4択'), findsNothing);
    expect(find.text('登録不要'), findsNothing);
    final homeMap = tester.getSize(find.byType(StationMap));
    expect(homeMap.width, homeMap.height);
    expect(homeMap.height, greaterThan(235));
    expect(find.text('最大1,000点'), findsNothing);
    expect(find.text('この駅、\nどこ駅？'), findsNothing);
    await tester.tap(find.text('ゲームをはじめる'));
    await tester.pumpAndSettle();
    expect(find.text('この駅、どこ駅？'), findsNothing);
    for (var i = 0; i < 10; i++) {
      if (i == 0) {
        for (var j = 0; j < 3; j++) {
          await tester.ensureVisible(find.text('ヒントを見る'));
          await tester.tap(find.text('ヒントを見る'));
          await tester.pumpAndSettle();
        }
        expect(find.text('すべて開示済み'), findsOneWidget);
      }
      final choice = i == 1
          ? game.choices.firstWhere((s) => s.id != game.station.id)
          : game.station;
      final option = find.byKey(ValueKey('choice-${choice.id}'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('この駅で回答する'));
      await tester.tap(find.text('この駅で回答する'));
      await tester.pumpAndSettle();
      expect(find.text(i == 1 ? '残念！' : '正解！'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      final next = find.text(i == 9 ? '結果を見る' : '次の問題へ');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('今回のリザルト'), findsNothing);
    expect(find.text('TOTAL SCORE'), findsOneWidget);
    expect(find.text('Ekidoko'), findsOneWidget);
    expect(game.correctCount, 9);
    await tester.ensureVisible(find.text('もう一度遊ぶ'));
    await tester.tap(find.text('もう一度遊ぶ'));
    await tester.pumpAndSettle();
    expect(game.answers, isEmpty);
    expect(find.text('1 / 10'), findsOneWidget);
  });

  testWidgets('small display and large text render without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: AppScreen(
          game: Game(catalog: catalog),
          mapBuilder: mockMapBuilder,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('ゲームをはじめる'));
    await tester.tap(find.text('ゲームをはじめる'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(OutlinedButton), findsNWidgets(4));
    final option = find.byType(OutlinedButton).first;
    await tester.ensureVisible(option);
    await tester.tap(option);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('この駅で回答する'));
    expect(tester.takeException(), isNull);
  });
}
