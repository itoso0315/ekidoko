import 'support/catalog.dart';
import 'dart:math';
import 'dart:ui' show SemanticsAction, Tristate;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ekidoko/game/game.dart';
import 'package:ekidoko/game/highest_rank_store.dart';
import 'package:ekidoko/map/home_map_preview.dart';
import 'package:ekidoko/screens/app_screen.dart';
import 'package:ekidoko/map/station_map.dart';

class _FakeHighestRankStore implements HighestRankStore {
  _FakeHighestRankStore();

  ResultRank? rank;

  @override
  Future<ResultRank?> load() async => rank;

  @override
  Future<ResultRank> record(ResultRank nextRank) async {
    if (rank == null || nextRank.minimumPoints > rank!.minimumPoints) {
      rank = nextRank;
    }
    return rank!;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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

  testWidgets('home to complete game and replay, including incorrect answer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = Game(catalog: catalog, random: Random(2));
    final highestRankStore = _FakeHighestRankStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: AppScreen(
          game: game,
          mapBuilder: mockMapBuilder,
          highestRankStore: highestRankStore,
        ),
      ),
    );
    expect(find.text('Ekidoko'), findsOneWidget);
    final homeMap = tester.getSize(find.byType(HomeMapPreview));
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
      final next = find.text(i == 9 ? 'ランクを見る' : '次の問題へ');
      await tester.ensureVisible(next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(find.byKey(const ValueKey('rank-reveal-popup')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rank-reveal-rank'))).data,
      'A',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rank-reveal-points')))
          .data,
      'ランクポイント 810 pt',
    );
    expect(highestRankStore.rank, ResultRank.a);
    await tester.tap(find.byKey(const ValueKey('rank-reveal-popup')));
    await tester.pumpAndSettle();
    expect(find.text('今回のリザルト'), findsNothing);
    expect(find.text('TOTAL SCORE'), findsOneWidget);
    expect(game.correctCount, 9);
    await tester.ensureVisible(find.text('もう一度遊ぶ'));
    await tester.tap(find.text('もう一度遊ぶ'));
    await tester.pumpAndSettle();
    expect(game.answers, isEmpty);
    expect(find.text('1 / 10'), findsOneWidget);
  });

  testWidgets('home uses rail-only Tokyo preview without loading a live map', (
    tester,
  ) async {
    var liveMapBuilds = 0;
    final game = Game(catalog: catalog, random: Random(31));

    await tester.pumpWidget(
      MaterialApp(
        home: AppScreen(
          game: game,
          mapBuilder: (station, hint, reveal) {
            liveMapBuilds++;
            return const ColoredBox(color: Color(0xffedf0ea));
          },
        ),
      ),
    );

    expect(find.byType(HomeMapPreview), findsOneWidget);
    expect(find.text('地図を読み込んでいます…'), findsNothing);
    expect(liveMapBuilds, 0);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-map-preview-image')), findsOneWidget);
    expect(find.text('線路プレビュー'), findsNothing);
    expect(find.text('↑ N'), findsOneWidget);

    await tester.ensureVisible(find.text('ゲームをはじめる'));
    await tester.tap(find.text('ゲームをはじめる'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeMapPreview), findsNothing);
    expect(liveMapBuilds, greaterThan(0));

    final buildsDuringGame = liveMapBuilds;
    game.home();
    await tester.pumpAndSettle();
    expect(find.text('Ekidoko'), findsOneWidget);
    expect(find.byType(HomeMapPreview), findsOneWidget);
    expect(find.text('地図を読み込んでいます…'), findsNothing);
    expect(liveMapBuilds, buildsDuringGame);
  });

  testWidgets('home preview attribution stays visible at tablet width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 800,
              child: HomeMapPreview(
                station: stations.firstWhere((s) => s.id == 'tokyo'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey('home-map-attribution'))).height,
      closeTo(30, .1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('home shows saved best rank and explains rank points', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ekidoko.highestRank.minimumPoints': ResultRank.a.minimumPoints,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppScreen(
          game: Game(catalog: catalog),
          mapBuilder: mockMapBuilder,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('過去最高ランク'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-best-rank')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('home-best-rank'))).data,
      'A',
    );

    await tester.tap(find.byKey(const ValueKey('rank-points-help')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rank-points-guide')), findsOneWidget);
    expect(find.text('ランクポイントの目安'), findsOneWidget);
    expect(find.byKey(const ValueKey('rank-points-formula')), findsOneWidget);
    expect(find.text('1,050 pt以上'), findsOneWidget);
    expect(find.text('0–299 pt'), findsOneWidget);
  });

  testWidgets('rank reveal opens detailed results and reads as one button', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final textScale = ValueNotifier(1.0);
    addTearDown(textScale.dispose);
    final game = Game(catalog: catalog, random: Random(23))
      ..selectDifficulty(GameDifficulty.hard)
      ..start();
    for (var question = 0; question < 9; question++) {
      game.submitChoice(game.station);
      game.next();
    }
    game.submitChoice(game.station);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => ValueListenableBuilder<double>(
          valueListenable: textScale,
          child: child,
          builder: (context, scale, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: AppScreen(game: game, mapBuilder: mockMapBuilder),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('ランクを見る'));
    await tester.tap(find.text('ランクを見る'));
    await tester.pumpAndSettle();
    textScale.value = 2;
    await tester.pumpAndSettle();

    final popup = find.byKey(const ValueKey('rank-reveal-popup'));
    expect(popup, findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('rank-reveal-rank'))).data,
      'SS',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('rank-reveal-points')))
          .data,
      'ランクポイント 1,100 pt',
    );
    final semantics = tester.getSemantics(popup);
    expect(
      semantics.label,
      'あなたのEkidokoランクはSSです。ランクポイントは1,100点です。'
      'Hardは合計点を1.10倍して評価します。',
    );
    expect(semantics.hint, 'タップして詳しい結果を表示します');
    expect(semantics.getSemanticsData().hasAction(SemanticsAction.tap), true);
    expect(find.bySemanticsLabel('ランク発表'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(popup, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popup, findsOneWidget);

    textScale.value = 1;
    await tester.pumpAndSettle();
    final cardTap = tester
        .widget<InkWell>(
          find.descendant(of: popup, matching: find.byType(InkWell)),
        )
        .onTap!;
    cardTap();
    cardTap();
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(find.byType(AppScreen), findsOneWidget);
    expect(find.text('Ekidoko'), findsOneWidget);
    expect(find.text('ekidoko'), findsNothing);
    expect(find.text('TOTAL SCORE'), findsOneWidget);
    expect(find.byKey(const ValueKey('result-rating')), findsOneWidget);
    final focusedRating = tester.getSemantics(
      find.byKey(const ValueKey('result-rating-focus')),
    );
    expect(
      Focus.of(
        tester.element(find.byKey(const ValueKey('result-rating'))),
      ).hasPrimaryFocus,
      true,
    );
    expect(focusedRating.label, 'ランクSS、ランクポイント1,100点。Hardは合計点を1.10倍して評価');
    expect(focusedRating.flagsCollection.isFocused, Tristate.isTrue);
    expect(tester.takeException(), isNull);
    semanticsHandle.dispose();
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

  testWidgets('Hard result rank fits a small display with large text', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = Game(catalog: catalog, random: Random(19))
      ..selectDifficulty(GameDifficulty.hard)
      ..start();
    while (!game.finished) {
      game.submitChoice(game.station);
      game.next();
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.4)),
          child: child!,
        ),
        home: AppScreen(game: game, mapBuilder: mockMapBuilder),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('result-rank'))).data,
      'SS',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('result-rank-points')))
          .data,
      '1,100 pt',
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('result-rating'))).label,
      'ランクSS、ランクポイント1,100点。Hardは合計点を1.10倍して評価',
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('もう一度遊ぶ'));
    await tester.tap(find.text('もう一度遊ぶ'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('result-rating')), findsNothing);
    expect(find.text('1 / 10'), findsOneWidget);
    semanticsHandle.dispose();
  });
}
