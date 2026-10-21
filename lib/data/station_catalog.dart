import 'dart:convert';

/// Map-SDK-independent station data. All production stations are geolocated.
class Station {
  const Station({
    required this.id,
    required this.name,
    required this.nameKana,
    required this.latitude,
    required this.longitude,
    required this.prefecture,
    required this.region,
    required this.difficulty,
    required this.enabled,
    this.easyEligible = true,
    this.hasHighSpeedRailway = false,
    this.osmNodeId,
    this.routes = const [],
    this.answerAliases = const [],
    this.blockedLabels = const [],
    this.allowedLabels = const [],
  });
  final String id;
  final String name;
  final String nameKana;
  final double latitude;
  final double longitude;
  final String prefecture;
  final String region;
  final int difficulty;
  final bool enabled;
  final bool easyEligible;
  final bool hasHighSpeedRailway;
  final int? osmNodeId;
  final List<String> routes;
  final List<String> answerAliases;
  final List<String> blockedLabels;
  final List<String> allowedLabels;
  String get kana => nameKana;
  String get lines => routes.join('・');
  List<String> get landmarks => const [];
  bool get hasRealMap => true;
}

class StationDataException implements Exception {
  const StationDataException(this.errors);
  final List<String> errors;
  @override
  String toString() => errors.join('\n');
}

class StationCatalog {
  StationCatalog._(List<Station> stations)
    : stations = List.unmodifiable(stations);
  final List<Station> stations;

  List<Station> select({String? region, String? prefecture, int? difficulty}) =>
      stations
          .where(
            (s) =>
                s.enabled &&
                (region == null || s.region == region) &&
                (prefecture == null || s.prefecture == prefecture) &&
                (difficulty == null || s.difficulty == difficulty),
          )
          .toList();

  factory StationCatalog.parse(String source) {
    dynamic decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw StationDataException([
        'stations.json: JSON形式が不正です (${error.message})',
      ]);
    }
    if (decoded is! List || decoded.isEmpty) {
      throw const StationDataException(['stations.json: 駅の配列が必要です']);
    }
    final errors = <String>[];
    final stations = <Station>[];
    final ids = <String>{};
    for (var i = 0; i < decoded.length; i++) {
      final row = decoded[i];
      final location =
          'stations.json ${i + 1}件目 [${row is Map ? row['id'] ?? 'IDなし' : 'IDなし'}]';
      if (row is! Map<String, dynamic>) {
        errors.add('$location: 駅情報はオブジェクトにしてください');
        continue;
      }
      final before = errors.length;
      String string(String key) {
        final value = row[key];
        if (value is! String || value.trim().isEmpty) {
          errors.add('$location: $key は空欄にできません');
          return '';
        }
        return value.trim();
      }

      double coordinate(String key, double limit) {
        final value = row[key];
        if (value is! num || !value.isFinite || value.abs() > limit) {
          errors.add('$location: $key は -$limit ～ $limit の数値が必要です');
          return 0;
        }
        return value.toDouble();
      }

      List<String> strings(String key) {
        if (!row.containsKey(key)) return const [];
        final value = row[key];
        if (value is! List ||
            value.any((e) => e is! String || e.trim().isEmpty)) {
          errors.add('$location: $key は空欄のない文字列配列にしてください');
          return const [];
        }
        return List.unmodifiable(value.cast<String>().map((e) => e.trim()));
      }

      final id = string('id');
      if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
        errors.add('$location: id は英小文字・数字・_・-を使用してください');
      }
      if (!ids.add(id)) errors.add('$location: id「$id」が重複しています');
      final name = string('name');
      final kana = string('nameKana');
      final lat = coordinate('latitude', 90);
      final lon = coordinate('longitude', 180);
      final prefecture = string('prefecture');
      final region = string('region');
      final difficulty = row['difficulty'];
      if (difficulty is! int || difficulty < 1) {
        errors.add('$location: difficulty は1以上の整数が必要です');
      }
      if (row['enabled'] is! bool) {
        errors.add('$location: enabled はtrue/falseが必要です');
      }
      if (row['easyEligible'] is! bool) {
        errors.add('$location: easyEligible はtrue/falseが必要です');
      }
      if (row['hasHighSpeedRailway'] is! bool) {
        errors.add('$location: hasHighSpeedRailway はtrue/falseが必要です');
      }
      final node = row['osmNodeId'];
      if (node != null && (node is! int || node <= 0)) {
        errors.add('$location: osmNodeId は正の整数が必要です');
      }
      final routes = strings('routes');
      final aliases = strings('answerAliases');
      final blocked = strings('blockedLabels');
      final allowed = strings('allowedLabels');
      final duplicate = stations.where(
        (s) =>
            (node != null && s.osmNodeId == node) ||
            ((s.latitude - lat).abs() < .00004 &&
                (s.longitude - lon).abs() < .00004) ||
            (s.nameKana == kana &&
                (s.latitude - lat).abs() < .0008 &&
                (s.longitude - lon).abs() < .0008),
      );
      if (duplicate.isNotEmpty) {
        errors.add('$location: 同じ駅が登録されています (${duplicate.first.id})');
      }
      if (errors.length != before) continue;
      stations.add(
        Station(
          id: id,
          name: name,
          nameKana: kana,
          latitude: lat,
          longitude: lon,
          prefecture: prefecture,
          region: region,
          difficulty: difficulty as int,
          enabled: row['enabled'] as bool,
          easyEligible: row['easyEligible'] as bool,
          hasHighSpeedRailway: row['hasHighSpeedRailway'] as bool,
          osmNodeId: node as int?,
          routes: routes,
          answerAliases: aliases,
          blockedLabels: blocked,
          allowedLabels: allowed,
        ),
      );
    }
    if (errors.isNotEmpty) {
      throw StationDataException(List.unmodifiable(errors));
    }
    return StationCatalog._(stations);
  }
}
