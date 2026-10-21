import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../game/game.dart';
import '../main.dart';
import '../map/station_map.dart';
import '../map/map_availability.dart';

class AppScreen extends StatefulWidget {
  const AppScreen({
    super.key,
    required this.game,
    this.mapBuilder = hybridMapBuilder,
  });
  final Game game;
  final StationMapBuilder mapBuilder;
  @override
  State<AppScreen> createState() => _AppScreenState();
}

class _AppScreenState extends State<AppScreen> {
  late final Game game = widget.game;
  Station? selectedStation;
  final mapAvailable = MapAvailability(false);
  void resetAvailability() {
    mapAvailable.begin(
      widget.mapBuilder != hybridMapBuilder || !game.station.hasRealMap,
    );
  }

  @override
  void dispose() {
    mapAvailable.dispose();

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

  void next() {
    selectedStation = null;
    game.next();
    if (!game.finished) resetAvailability();
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
                const Row(
                  children: [
                    Icon(Icons.route_rounded, color: accent, size: 24),
                    SizedBox(width: 8),
                    Text(
                      'Ekidoko',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
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
                        child: widget.mapBuilder(game.stations.first, 0, false),
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
            ? '有名な駅から出題！全国ランダム4択'
            : '全国の駅に挑戦！近隣エリア中心の4択',
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
          child: Text(game.index == game.questionCount - 1 ? '結果を見る' : '次の問題へ'),
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
            const Text(
              'ekidoko',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
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
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
