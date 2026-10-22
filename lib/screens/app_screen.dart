import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/game.dart';
import '../game/highest_rank_store.dart';
import '../main.dart';
import '../map/home_map_preview.dart';
import '../map/station_map.dart';
import '../map/map_availability.dart';
import 'package:url_launcher/url_launcher.dart';

const _privacyPolicyUrl =
    'https://itoso0315.github.io/ekidoko-pages/privacy-policy.html';
const _supportUrl = 'https://itoso0315.github.io/ekidoko-pages/support.html';

class AppScreen extends StatefulWidget {
  const AppScreen({
    super.key,
    required this.game,
    this.mapBuilder = hybridMapBuilder,
    this.highestRankStore = const PreferencesHighestRankStore(),
  });
  final Game game;
  final StationMapBuilder mapBuilder;
  final HighestRankStore highestRankStore;
  @override
  State<AppScreen> createState() => _AppScreenState();
}

class _AppScreenState extends State<AppScreen> {
  late final Game game = widget.game;
  final resultRatingFocusNode = FocusNode(debugLabel: 'result-rating');
  late final Future<void> highestRankLoaded;
  ResultRank? highestRank;
  Object? highestRankError;
  bool isLoadingHighestRank = true;
  Station? selectedStation;
  final mapAvailable = MapAvailability(false);

  @override
  void initState() {
    super.initState();
    highestRankLoaded = loadHighestRank();
  }

  Future<void> loadHighestRank() async {
    try {
      final rank = await widget.highestRankStore.load();
      if (!mounted) return;
      setState(() {
        highestRank = rank;
        highestRankError = null;
        isLoadingHighestRank = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        highestRankError = error;
        isLoadingHighestRank = false;
      });
    }
  }

  Future<void> openPublicPage(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('ページを開けませんでした'),
            content: SelectableText(url),
          ),
        );
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('ページを開けませんでした'),
          content: SelectableText('$url\n\n$error'),
        ),
      );
    }
  }

  Future<void> recordHighestRank(ResultRank rank) async {
    await highestRankLoaded;
    try {
      final savedRank = await widget.highestRankStore.record(rank);
      if (!mounted) return;
      setState(() {
        highestRank = savedRank;
        highestRankError = null;
        isLoadingHighestRank = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        highestRankError = error;
        isLoadingHighestRank = false;
      });
    }
  }

  void resetAvailability() {
    mapAvailable.begin(
      widget.mapBuilder != hybridMapBuilder || !game.station.hasRealMap,
    );
  }

  @override
  void dispose() {
    mapAvailable.dispose();
    resultRatingFocusNode.dispose();

    super.dispose();
  }

  void start() {
    selectedStation = null;
    game.start();
    resetAvailability();
  }

  void submit() {
    final selected = selectedStation;
    if (mapAvailable.value && selected != null && game.submitChoice(selected)) {
      HapticFeedback.lightImpact();
    }
  }

  Future<void> next() async {
    final wasFinished = game.finished;
    selectedStation = null;
    game.next();
    if (!wasFinished && game.finished) {
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      final rating = game.resultRating!;
      await recordHighestRank(rating.rank);
      if (!mounted) return;
      await showRankReveal(rating);
      if (mounted && highestRankError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('過去最高ランクを保存できませんでした')));
      }
      if (mounted && game.finished) {
        resultRatingFocusNode.requestFocus();
      }
    } else if (!game.finished) {
      resetAvailability();
    }
  }

  Future<void> showRankReveal(ResultRating rating) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: const Color(0xeef8faf7),
    builder: (dialogContext) => rankRevealDialog(dialogContext, rating),
  );

  Future<void> showRankPointsGuide() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('rank-points-guide'),
      title: const Text('ランクポイントの目安'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ランクポイントは合計点を難易度係数で換算します。\n'
              'Easy ×1.00 ／ Hard ×1.10',
              key: ValueKey('rank-points-formula'),
            ),
            const SizedBox(height: 16),
            for (var index = 0; index < ResultRank.values.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        ResultRank.values[index].label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        rankPointRange(index),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );

  String rankPointRange(int index) {
    final rank = ResultRank.values[index];
    if (index == 0) return '${formatPoints(rank.minimumPoints)} pt以上';
    final upperBound = ResultRank.values[index - 1].minimumPoints - 1;
    return '${formatPoints(rank.minimumPoints)}–${formatPoints(upperBound)} pt';
  }

  Future<void> leave() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ゲームを終了しますか？'),
        content: const Text('今回のスコアは保存されません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('続ける'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('終了する'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      game.home();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: game,
    builder: (context, _) {
      final key = !game.started
          ? 'home'
          : game.finished
          ? 'results'
          : 'question-${game.index}';
      return Scaffold(
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: SizedBox(
              key: ValueKey(key),
              width: double.infinity,
              child: !game.started
                  ? home()
                  : game.finished
                  ? results()
                  : quiz(),
            ),
          ),
        ),
      );
    },
  );

  Widget home() => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Row(
                        children: [
                          Icon(Icons.route_rounded, color: accent, size: 24),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Ekidoko',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 90,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text(
                            '過去最高ランク',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xff74847b),
                            ),
                          ),
                          if (isLoadingHighestRank)
                            const SizedBox(
                              key: ValueKey('home-best-rank-loading'),
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else if (highestRankError != null)
                            IconButton(
                              key: const ValueKey('home-best-rank-error'),
                              tooltip: '過去最高ランクを読み込めません。タップして再試行',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 30,
                                minHeight: 30,
                              ),
                              onPressed: loadHighestRank,
                              icon: const Icon(
                                Icons.error_outline_rounded,
                                color: Color(0xffb64c42),
                                size: 20,
                              ),
                            )
                          else
                            Text(
                              highestRank?.label ?? '—',
                              key: const ValueKey('home-best-rank'),
                              style: const TextStyle(
                                fontSize: 20,
                                height: 1.1,
                                fontWeight: FontWeight.w800,
                                color: accent,
                              ),
                            ),
                          IconButton(
                            key: const ValueKey('rank-points-help'),
                            tooltip: 'ランクポイントの解説',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            onPressed: showRankPointsGuide,
                            icon: const Icon(
                              Icons.help_outline_rounded,
                              size: 19,
                              color: Color(0xff74847b),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'いつもの駅も、\nちがって見える。',
                        style: TextStyle(
                          fontSize: 15,
                          color: Color(0xff74847b),
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 16),
                      AspectRatio(
                        aspectRatio: 1,
                        child: HomeMapPreview(
                          station: game.stations.firstWhere(
                            (station) => station.id == 'tokyo',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        '線路のかたち。街の余白。\n地図の手がかりから、駅を見つけよう。',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: Color(0xff63786e),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Column(
              children: [
                difficultySelector(),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => start(),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('ゲームをはじめる'),
                      SizedBox(width: 12),
                      Icon(Icons.arrow_forward_rounded, size: 20),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${game.stations.length}駅すべて実地図',
                  style: TextStyle(fontSize: 11, color: Color(0xff74847b)),
                ),
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton(
                      key: const ValueKey('privacy-policy-link'),
                      onPressed: () => openPublicPage(_privacyPolicyUrl),
                      child: const Text('プライバシーポリシー'),
                    ),
                    TextButton(
                      key: const ValueKey('support-page-link'),
                      onPressed: () => openPublicPage(_supportUrl),
                      child: const Text('サポート'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget difficultySelector() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '難易度を選択',
        style: TextStyle(fontSize: 12, color: Color(0xff63786e)),
      ),
      const SizedBox(height: 8),
      SegmentedButton<GameDifficulty>(
        key: const ValueKey('difficulty-selector'),
        segments: const [
          ButtonSegment(
            value: GameDifficulty.easy,
            label: Text('Easy'),
            icon: Icon(Icons.circle, size: 9, color: accent),
          ),
          ButtonSegment(
            value: GameDifficulty.hard,
            label: Text('Hard'),
            icon: Icon(Icons.circle, size: 9, color: Color(0xffc65348)),
          ),
        ],
        selected: {game.difficulty},
        onSelectionChanged: (selected) {
          HapticFeedback.selectionClick();
          game.selectDifficulty(selected.single);
        },
      ),
      const SizedBox(height: 8),
      Text(
        game.difficulty == GameDifficulty.easy
            ? '有名な駅から出題！全国ランダム'
            : '全国の駅に挑戦！近隣エリア中心',
        style: const TextStyle(fontSize: 11, color: Color(0xff74847b)),
      ),
    ],
  );

  Widget quiz() {
    final answer = game.currentAnswer;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Scroll on small screens or with large accessibility text.
        final mapHeight = (constraints.maxHeight - (answer == null ? 425 : 355))
            .clamp(200.0, 560.0);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'ゲームを終了',
                    onPressed: leave,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                  Expanded(
                    child: Text(
                      game.difficulty.label,
                      key: const ValueKey('quiz-difficulty'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                        color: Color(0xff73867a),
                      ),
                    ),
                  ),
                  Text(
                    '${game.index + 1} / ${game.questionCount}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Tag('${game.score} pt'),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: (game.index + 1) / game.questionCount,
                  minHeight: 3,
                  backgroundColor: const Color(0xffe5ebe4),
                  color: accent,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: mapHeight,
                child: MapAvailabilityScope(
                  availability: mapAvailable,
                  child: widget.mapBuilder(
                    game.station,
                    game.hint,
                    answer != null,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: answer == null
                    ? ValueListenableBuilder<bool>(
                        valueListenable: mapAvailable,
                        builder: (context, ready, _) => controls(ready),
                      )
                    : feedback(answer),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget controls(bool ready) => Column(
    key: const ValueKey('controls'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          ...List.generate(
            3,
            (i) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Semantics(
                label: 'ヒント${i + 1} ${game.hint > i ? "使用済み" : "未使用"}',
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: game.hint > i ? accent : const Color(0xffd9e2d8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              '${game.hint} / 3 · ${Game.points[game.hint]} pt',
              style: const TextStyle(fontSize: 12, color: Color(0xff63786e)),
            ),
          ),
          TextButton.icon(
            onPressed: ready && game.hint < 3
                ? () {
                    HapticFeedback.selectionClick();
                    if (widget.mapBuilder == hybridMapBuilder &&
                        game.station.hasRealMap) {
                      mapAvailable.begin(false);
                    }
                    game.revealHint();
                  }
                : null,
            icon: const Icon(Icons.lightbulb_outline_rounded, size: 18),
            label: Text(game.hint < 3 ? 'ヒントを見る' : 'すべて開示済み'),
          ),
        ],
      ),
      Text(
        [
          'まずは、地図のかたちだけで。',
          '範囲が広がりました。街の形に注目。',
          '路線名が見えるようになりました。',
          '周辺施設・地名を開示しました。',
        ][game.hint],
        style: const TextStyle(fontSize: 11, color: Color(0xff74847b)),
      ),
      const SizedBox(height: 14),
      const Text(
        '4つの駅から選んでください',
        style: TextStyle(fontSize: 12, color: Color(0xff63786e)),
      ),
      const SizedBox(height: 10),
      LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: 10,
          runSpacing: 10,
          children: game.choices.map((station) {
            final selected = selectedStation?.id == station.id;
            return SizedBox(
              width: (constraints.maxWidth - 10) / 2,
              child: Semantics(
                selected: selected,
                child: OutlinedButton(
                  key: ValueKey('choice-${station.id}'),
                  onPressed: ready
                      ? () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            selectedStation = station;
                          });
                        }
                      : null,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 58),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    backgroundColor: selected
                        ? const Color(0xffe4f1e8)
                        : Colors.white,
                    foregroundColor: ink,
                    side: BorderSide(
                      color: selected ? accent : const Color(0xffdfe6df),
                      width: selected ? 1.5 : 1,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 19,
                        color: selected ? accent : const Color(0xffb7c4ba),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${station.name}駅',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: !ready || selectedStation == null ? null : submit,
        child: const Text('この駅で回答する'),
      ),
    ],
  );

  Widget feedback(Answer answer) {
    final resultColor = answer.correct
        ? const Color(0xffc65348)
        : const Color(0xff3c77aa);
    return Column(
      key: ValueKey('answer-${game.index}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: .85, end: 1),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          builder: (context, value, child) =>
              Transform.scale(scale: value, child: child),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: answer.correct
                  ? const Color(0xffffe9e4)
                  : const Color(0xffe5f0fc),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: resultColor.withValues(alpha: .15)),
            ),
            child: Row(
              children: [
                Icon(
                  answer.correct
                      ? Icons.check_circle_rounded
                      : Icons.explore_outlined,
                  color: resultColor,
                  size: 36,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        answer.correct ? '正解！' : '残念！',
                        style: TextStyle(
                          color: resultColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${answer.station.name}駅',
                        style: const TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (!answer.correct)
                        Text(
                          'あなたの回答：${answer.input}',
                          style: const TextStyle(fontSize: 11),
                        ),
                    ],
                  ),
                ),
                Text(
                  '+${answer.points}',
                  style: TextStyle(
                    fontSize: 26,
                    color: resultColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          game.station.hasRealMap && widget.mapBuilder == hybridMapBuilder
              ? '中央の印は出題駅の位置です。'
              : '中央の印は模式地図上の出題位置です。',
          style: TextStyle(fontSize: 11, color: Color(0xff74847b)),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: next,
          child: Text(
            game.index == game.questionCount - 1 ? 'ランクを見る' : '次の問題へ',
          ),
        ),
      ],
    );
  }

  Widget results() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Ekidoko',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
            TextButton(onPressed: game.home, child: const Text('ホームへ')),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tag(
              game.difficulty.label,
              key: const ValueKey('result-difficulty'),
            ),
            Text(
              '${game.questionCount}駅の旅、おつかれさま。',
              style: TextStyle(fontSize: 14, color: Color(0xff63786e)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: [
              const Text(
                'TOTAL SCORE',
                style: TextStyle(
                  color: Color(0xffb8dccb),
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${game.score}',
                style: const TextStyle(
                  fontSize: 64,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              Text(
                '/ ${game.maxScore == 1000 ? '1,000' : game.maxScore} pt',
                style: TextStyle(color: Color(0xffb8dccb), fontSize: 12),
              ),
              const SizedBox(height: 18),
              Focus(
                key: const ValueKey('result-rating-focus'),
                focusNode: resultRatingFocusNode,
                child: resultRating(),
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 28,
                runSpacing: 14,
                children: [
                  stat('正解数', '${game.correctCount} / ${game.questionCount}'),
                  stat('ノーヒント正解', '${game.noHintCount} 駅'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        const Text(
          '駅めぐりの記録',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        ...game.answers.asMap().entries.map((entry) {
          final a = entry.value;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 25,
                  child: Text(
                    '${entry.key + 1}'.padLeft(2, '0'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff819087),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  a.correct
                      ? Icons.check_circle_rounded
                      : Icons.remove_circle_outline,
                  color: a.correct ? accent : const Color(0xff9aa59d),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a.station.name}駅',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        a.correct
                            ? (a.hint == 0 ? 'ノーヒントで正解' : 'ヒント${a.hint}で正解')
                            : '回答：${a.input}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xff74847b),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${a.points} pt',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 18),
        FilledButton(onPressed: () => start(), child: const Text('もう一度遊ぶ')),
        const SizedBox(height: 14),
        const Center(
          child: Text(
            '記録はこのゲーム中のみ保持されます',
            style: TextStyle(fontSize: 11, color: Color(0xff74847b)),
          ),
        ),
      ],
    ),
  );

  Widget rankRevealDialog(BuildContext dialogContext, ResultRating rating) {
    final formattedPoints = formatPoints(rating.points);
    var closing = false;
    void showDetails() {
      if (closing) return;
      closing = true;
      HapticFeedback.selectionClick();
      Navigator.of(dialogContext).pop();
    }

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Semantics(
          key: const ValueKey('rank-reveal-popup'),
          container: true,
          button: true,
          label:
              'あなたのEkidokoランクは${rating.rank.label}です。'
              'ランクポイントは$formattedPoints点です。'
              '${game.difficulty.label}は合計点を${rating.multiplierLabel}倍して評価します。',
          hint: 'タップして詳しい結果を表示します',
          onTap: showDetails,
          child: ExcludeSemantics(
            child: Material(
              color: accent,
              borderRadius: BorderRadius.circular(30),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                autofocus: true,
                onTap: showDetails,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.route_rounded,
                        color: Colors.white,
                        size: 34,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${game.questionCount}駅の旅、おつかれさま。',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'あなたのEkidokoランクは',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        rating.rank.label,
                        key: const ValueKey('rank-reveal-rank'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 88,
                          height: 1,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'ランクポイント $formattedPoints pt',
                        key: const ValueKey('rank-reveal-points'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        '${game.difficulty.label}・合計点 ×${rating.multiplierLabel}',
                        key: const ValueKey('rank-reveal-mode'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Divider(color: Colors.white.withValues(alpha: .35)),
                      const SizedBox(height: 12),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              'タップして詳しい結果を見る',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(width: 7),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget resultRating() {
    final rating = game.resultRating!;
    final formattedPoints = formatPoints(rating.points);
    final semanticsLabel =
        'ランク${rating.rank.label}、ランクポイント$formattedPoints点。'
        '${game.difficulty.label}は合計点を${rating.multiplierLabel}倍して評価';
    return Semantics(
      key: const ValueKey('result-rating'),
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .09),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: .12)),
          ),
          child: Column(
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                spacing: 28,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 70,
                    child: Column(
                      children: [
                        const Text(
                          'RANK',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          rating.rank.label,
                          key: const ValueKey('result-rank'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 36,
                            height: 1.05,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    children: [
                      const Text(
                        'ランクポイント',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          letterSpacing: .7,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '$formattedPoints pt',
                        key: const ValueKey('result-rank-points'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          height: 1.45,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                'ランクポイント = 合計点 ×${rating.multiplierLabel}',
                key: const ValueKey('result-rank-rule'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String formatPoints(int points) => points >= 1000
      ? '${points ~/ 1000},${(points % 1000).toString().padLeft(3, '0')}'
      : '$points';

  Widget stat(String label, String value) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 5),
      Text(
        label,
        style: const TextStyle(color: Color(0xffb8dccb), fontSize: 11),
      ),
    ],
  );
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: const Color(0xffeaf0e8),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xff527263),
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
