import 'package:flutter/foundation.dart';

import 'game_difficulty.dart';

/// A shared rank scale for comparing results across game modes.
enum ResultRank {
  ss('SS', 1050),
  s('S', 850),
  a('A', 700),
  b('B', 500),
  c('C', 300),
  d('D', 0);

  const ResultRank(this.label, this.minimumPoints);

  final String label;
  final int minimumPoints;

  static ResultRank fromPoints(int points) => values.firstWhere(
    (rank) => points >= rank.minimumPoints,
    orElse: () => ResultRank.d,
  );
}

@immutable
class ResultRating {
  const ResultRating({
    required this.points,
    required this.rank,
    required this.multiplierPercent,
  });

  static const int baseMaximum = 1000;

  final int points;
  final ResultRank rank;
  final int multiplierPercent;

  String get multiplierLabel => (multiplierPercent / 100).toStringAsFixed(2);

  factory ResultRating.fromScore({
    required int score,
    required int maxScore,
    required GameDifficulty difficulty,
  }) {
    if (maxScore <= 0) {
      throw ArgumentError.value(maxScore, 'maxScore', 'must be greater than 0');
    }

    final boundedScore = score.clamp(0, maxScore);
    final multiplierPercent = switch (difficulty) {
      GameDifficulty.easy => 100,
      GameDifficulty.hard => 110,
    };
    final points =
        (boundedScore * baseMaximum * multiplierPercent / (maxScore * 100))
            .round();

    return ResultRating(
      points: points,
      rank: ResultRank.fromPoints(points),
      multiplierPercent: multiplierPercent,
    );
  }
}
