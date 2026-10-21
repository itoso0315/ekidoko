import 'package:ekidoko/game/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ResultRank', () {
    const boundaries = {
      0: ResultRank.d,
      299: ResultRank.d,
      300: ResultRank.c,
      499: ResultRank.c,
      500: ResultRank.b,
      699: ResultRank.b,
      700: ResultRank.a,
      849: ResultRank.a,
      850: ResultRank.s,
      1049: ResultRank.s,
      1050: ResultRank.ss,
      1100: ResultRank.ss,
    };

    test('negative points stay at the lowest rank', () {
      expect(ResultRank.fromPoints(-1), ResultRank.d);
    });

    for (final entry in boundaries.entries) {
      test('${entry.key} points is rank ${entry.value.label}', () {
        expect(ResultRank.fromPoints(entry.key), entry.value);
      });
    }
  });

  test('Easy and Hard perfect scores have different common ranks', () {
    final easy = ResultRating.fromScore(
      score: 1000,
      maxScore: 1000,
      difficulty: GameDifficulty.easy,
    );
    final hard = ResultRating.fromScore(
      score: 1000,
      maxScore: 1000,
      difficulty: GameDifficulty.hard,
    );

    expect(easy.points, 1000);
    expect(easy.rank, ResultRank.s);
    expect(easy.multiplierLabel, '1.00');
    expect(hard.points, 1100);
    expect(hard.rank, ResultRank.ss);
    expect(hard.multiplierLabel, '1.10');
  });

  test('rating normalizes games with a different maximum score', () {
    final rating = ResultRating.fromScore(
      score: 8,
      maxScore: 10,
      difficulty: GameDifficulty.hard,
    );

    expect(rating.points, 880);
    expect(rating.rank, ResultRank.s);
  });

  test('mode conversion crosses shared rank boundaries as specified', () {
    ResultRating easy(int score) => ResultRating.fromScore(
      score: score,
      maxScore: 1000,
      difficulty: GameDifficulty.easy,
    );
    ResultRating hard(int score) => ResultRating.fromScore(
      score: score,
      maxScore: 1000,
      difficulty: GameDifficulty.hard,
    );

    expect(easy(840).rank, ResultRank.a);
    expect(easy(850).rank, ResultRank.s);
    expect(hard(770).rank, ResultRank.a);
    expect(hard(780).rank, ResultRank.s);
    expect(hard(940).rank, ResultRank.s);
    expect(hard(970).rank, ResultRank.ss);
  });

  test('normalization and difficulty adjustment round only once', () {
    final rating = ResultRating.fromScore(
      score: 890,
      maxScore: 1400,
      difficulty: GameDifficulty.hard,
    );

    expect(rating.points, 699);
    expect(rating.rank, ResultRank.b);
  });

  test('score input is bounded and a positive maximum is required', () {
    final belowMinimum = ResultRating.fromScore(
      score: -10,
      maxScore: 1000,
      difficulty: GameDifficulty.easy,
    );
    final aboveMaximum = ResultRating.fromScore(
      score: 1010,
      maxScore: 1000,
      difficulty: GameDifficulty.hard,
    );

    expect(belowMinimum.points, 0);
    expect(belowMinimum.rank, ResultRank.d);
    expect(aboveMaximum.points, 1100);
    expect(aboveMaximum.rank, ResultRank.ss);
    expect(
      () => ResultRating.fromScore(
        score: 0,
        maxScore: 0,
        difficulty: GameDifficulty.easy,
      ),
      throwsArgumentError,
    );
  });
}
