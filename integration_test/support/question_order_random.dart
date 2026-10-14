import 'dart:math';

/// Test-only Fisher-Yates values force a catalog half into a ten-question game.
/// Choices and subsequent replays still use a seeded random generator.
class QuestionOrderRandom implements Random {
  QuestionOrderRandom(List<String> catalogIds, List<String> questionIds) {
    final target = [
      ...questionIds,
      ...catalogIds.where((id) => !questionIds.contains(id)),
    ];
    final current = List<String>.of(catalogIds);
    for (var end = current.length - 1; end > 0; end--) {
      final index = current.indexOf(target[end]);
      _indices.add(index);
      final previous = current[end];
      current[end] = current[index];
      current[index] = previous;
    }
  }
  final _indices = <int>[];
  final _random = Random(1);
  int _offset = 0;
  @override
  int nextInt(int max) {
    if (_offset < _indices.length) return _indices[_offset++];
    return _random.nextInt(max);
  }

  @override
  bool nextBool() => _random.nextBool();
  @override
  double nextDouble() => _random.nextDouble();
}
