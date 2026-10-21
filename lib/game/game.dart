import 'dart:math';
import 'package:flutter/foundation.dart';

import '../data/station_catalog.dart';
import 'game_difficulty.dart';
import 'result_rating.dart';
import 'station_choices.dart';
export '../data/station_catalog.dart';
export 'game_difficulty.dart';
export 'result_rating.dart';

String normalizeAnswer(String value) {
  final converted = value
      .trim()
      .replaceAll(RegExp(r'\s+'), '')
      .runes
      .map(
        (r) => String.fromCharCode(r >= 0x30a1 && r <= 0x30f6 ? r - 0x60 : r),
      )
      .join();
  return converted.endsWith('駅')
      ? converted.substring(0, converted.length - 1)
      : converted;
}

@immutable
class Answer {
  const Answer(this.station, this.input, this.hint, this.correct);
  final Station station;
  final String input;
  final int hint;
  final bool correct;
  int get points => correct ? Game.points[hint] : 0;
}

class Game extends ChangeNotifier {
  Game({required this.catalog, Random? random}) : _random = random ?? Random() {
    // Startup validation reaches the existing retryable catalog error screen.
    for (final difficulty in GameDifficulty.values) {
      final pool = stationsFor(difficulty);
      if (pool.length < 10) {
        throw StationDataException([
          '${difficulty.label}には出題可能な駅が10駅以上必要です（現在${pool.length}駅）。'
              'enabledとeasyEligibleを確認してください。',
        ]);
      }
      _choiceGenerators[difficulty] = StationChoiceGenerator(
        stations: pool,
        random: _random,
      );
    }
  }
  final StationCatalog catalog;
  List<Station> get stations => catalog.select();
  List<Station> stationsFor(GameDifficulty difficulty) => stations
      .where(
        (station) => difficulty == GameDifficulty.hard || station.easyEligible,
      )
      .toList();
  final Random _random;
  final _choiceGenerators = <GameDifficulty, StationChoiceGenerator>{};
  GameDifficulty _difficulty = GameDifficulty.easy;
  GameDifficulty get difficulty => _difficulty;
  static const points = [100, 70, 40, 10];
  static const ranges = ['500 m', '1 km', '3 km', '5 km'];
  List<Station> questions = [];
  final List<Answer> _answers = [];
  List<List<Station>> _choices = [];
  List<Station> get choices =>
      !started || finished ? const [] : _choices[index];
  List<Answer> get answers => List.unmodifiable(_answers);
  int index = 0;
  int hint = 0;
  bool started = false;
  bool get finished =>
      started &&
      _answers.length == questions.length &&
      index == questions.length;
  Station get station => questions[index];
  Answer? get currentAnswer => _answers.length > index ? _answers[index] : null;
  int get score => _answers.fold(0, (sum, a) => sum + a.points);
  int get correctCount => _answers.where((a) => a.correct).length;
  int get noHintCount => _answers.where((a) => a.correct && a.hint == 0).length;

  int get questionCount => questions.length;
  int get maxScore => questionCount * 100;
  ResultRating? get resultRating => finished
      ? ResultRating.fromScore(
          score: score,
          maxScore: maxScore,
          difficulty: difficulty,
        )
      : null;

  bool selectDifficulty(GameDifficulty difficulty) {
    if (started) return false;
    if (_difficulty != difficulty) {
      _difficulty = difficulty;
      notifyListeners();
    }
    return true;
  }

  void start() {
    final nextQuestions = stationsFor(_difficulty)..shuffle(_random);
    if (nextQuestions.length < 10) {
      throw const StationDataException(['ゲーム開始には有効な駅が10駅以上必要です']);
    }
    final selectedQuestions = nextQuestions.take(10).toList();
    final nextChoices = selectedQuestions
        .map(
          (station) => _choiceGenerators[_difficulty]!.generate(
            station,
            difficulty: _difficulty,
          ),
        )
        .toList();
    questions = selectedQuestions;
    _choices = nextChoices;
    _answers.clear();
    index = 0;
    hint = 0;
    started = true;
    notifyListeners();
  }

  void revealHint() {
    if (!started || finished || currentAnswer != null || hint == 3) return;
    hint++;
    notifyListeners();
  }

  bool submitChoice(Station choice) {
    if (!choices.any((s) => s.id == choice.id)) return false;
    if (!started || finished || currentAnswer != null) return false;
    _answers.add(Answer(station, choice.name, hint, choice.id == station.id));
    notifyListeners();
    return true;
  }

  bool submit(String input) {
    if (!started ||
        finished ||
        currentAnswer != null ||
        normalizeAnswer(input).isEmpty) {
      return false;
    }
    final normalized = normalizeAnswer(input);
    _answers.add(
      Answer(
        station,
        input.trim(),
        hint,
        [
          station.name,
          station.kana,
          ...station.answerAliases,
        ].any((name) => normalizeAnswer(name) == normalized),
      ),
    );
    notifyListeners();
    return true;
  }

  void next() {
    if (!started || finished || currentAnswer == null) return;
    index++;
    hint = 0;
    notifyListeners();
  }

  void home() {
    started = false;
    notifyListeners();
  }
}
