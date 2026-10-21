import 'dart:math';

import '../data/station_catalog.dart';
import 'game_difficulty.dart';

// Existing catalog spellings share the same choice-generation region.
const _regionAliases = {
  '関西': '近畿',
  '中部・北陸': '中部',
  '北陸': '中部',
  '東海': '中部',
  '九州・沖縄': '九州',
};

/// Game configuration: nearby macro-regions, including sea connections.
/// Keep connections symmetric. Unknown regions fall back to nationwide choices.
const adjacentRegions = <String, List<String>>{
  '北海道': ['東北'],
  '東北': ['北海道', '関東', '中部'],
  '関東': ['東北', '中部'],
  '中部': ['東北', '関東', '近畿'],
  '近畿': ['中部', '中国', '四国'],
  '中国': ['近畿', '四国', '九州'],
  '四国': ['近畿', '中国', '九州'],
  '九州': ['中国', '四国'],
};

String _regionKey(String value) => _regionAliases[value.trim()] ?? value.trim();

// Catalog names omit 「駅」. Also guard against spacing/suffix variations.
String _nameKey(Station station) =>
    station.name.replaceAll(RegExp(r'\s+'), '').replaceFirst(RegExp(r'駅$'), '');

/// Four unique choices from the currently available, enabled station pool.
/// This class has no dependency on maps, scoring, or UI.
class StationChoiceGenerator {
  StationChoiceGenerator({required Iterable<Station> stations, Random? random})
    : _random = random ?? Random() {
    final ids = <String>{};
    _stations = List.unmodifiable(
      stations.where((s) => s.enabled && ids.add(s.id)),
    );
    final names = _stations.map(_nameKey).toSet();
    if (names.length < 4) {
      throw StationDataException([
        '4択には表示駅名の異なる有効な駅が4駅以上必要です。'
            'stations.jsonのenabledとnameを確認してください。',
        '現在: ${_stations.length}駅 / 駅名${names.length}種類'
            '（${_stations.map((s) => '${s.id}: ${s.name}').join('、')}）',
      ]);
    }
  }

  late final List<Station> _stations;
  final Random _random;

  List<Station> generate(Station answer, {required GameDifficulty difficulty}) {
    var available = difficulty == GameDifficulty.easy
        ? _stations.where((s) => s.easyEligible).toList()
        : _stations;
    if (!available.any((s) => s.id == answer.id)) {
      throw StationDataException([
        '[${answer.id}] ${answer.name}: 正解駅が出題可能な駅に含まれていません',
      ]);
    }
    if (difficulty == GameDifficulty.hard && answer.hasHighSpeedRailway) {
      available = available.where((s) => s.hasHighSpeedRailway).toList();
    }
    if (available.map(_nameKey).toSet().length < 4) {
      throw StationDataException([
        answer.hasHighSpeedRailway && difficulty == GameDifficulty.hard
            ? '新幹線が通る駅を正解とするHardの4択には、新幹線が通る駅名の異なる有効な駅が4駅以上必要です。'
            : '${difficulty.label}の4択には表示駅名の異なる有効な駅が4駅以上必要です。easyEligibleを確認してください。',
      ]);
    }
    final region = _regionKey(answer.region);
    final neighbors = adjacentRegions[region] ?? const <String>[];
    final choices = <Station>[answer];
    final ids = <String>{answer.id};
    final names = <String>{_nameKey(answer)};

    void fillFrom(bool Function(Station) matches) {
      if (choices.length == 4) return;
      final candidates =
          available
              .where(
                (s) =>
                    matches(s) &&
                    !ids.contains(s.id) &&
                    !names.contains(_nameKey(s)),
              )
              .toList()
            ..shuffle(_random);
      for (final candidate in candidates) {
        // Same-name stations can still coexist in this tier's candidate list.
        if (ids.contains(candidate.id) || names.contains(_nameKey(candidate))) {
          continue;
        }
        choices.add(candidate);
        ids.add(candidate.id);
        names.add(_nameKey(candidate));
        if (choices.length == 4) return;
      }
    }

    if (difficulty == GameDifficulty.hard) {
      fillFrom((s) => s.prefecture.trim() == answer.prefecture.trim());
      fillFrom((s) => _regionKey(s.region) == region);
      fillFrom((s) => neighbors.contains(_regionKey(s.region)));
    }
    fillFrom((s) => true);
    choices.shuffle(_random);
    return List.unmodifiable(choices);
  }
}
