import 'package:shared_preferences/shared_preferences.dart';

import 'result_rating.dart';

abstract interface class HighestRankStore {
  Future<ResultRank?> load();
  Future<ResultRank> record(ResultRank rank);
}

class PreferencesHighestRankStore implements HighestRankStore {
  const PreferencesHighestRankStore();

  static const _storageKey = 'ekidoko.highestRank.minimumPoints';
  static const _rankThresholds = {0, 300, 500, 700, 850, 1050};

  Future<SharedPreferences> get _preferences => SharedPreferences.getInstance();

  @override
  Future<ResultRank?> load() async {
    final stored = (await _preferences).getInt(_storageKey);
    if (stored == null) return null;
    if (!_rankThresholds.contains(stored)) {
      throw FormatException('Invalid saved highest rank: $stored');
    }
    return ResultRank.fromPoints(stored);
  }

  @override
  Future<ResultRank> record(ResultRank rank) async {
    final preferences = await _preferences;
    final current = await load();
    final highest =
        current == null || rank.minimumPoints > current.minimumPoints
        ? rank
        : current;
    if (highest != current) {
      final saved = await preferences.setInt(
        _storageKey,
        highest.minimumPoints,
      );
      if (!saved) throw StateError('Could not save the highest rank');
    }
    return highest;
  }
}
