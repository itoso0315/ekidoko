import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/station_catalog.dart';

const facilityKinds = {
  'education',
  'hospital',
  'religion',
  'culture',
  'shopping',
  'stadium',
};

String _mapHintLabelKey(String value) => value.runes
    .map((r) {
      if (r >= 0xff01 && r <= 0xff5e) return String.fromCharCode(r - 0xfee0);
      return String.fromCharCode(r >= 0x30a1 && r <= 0x30f6 ? r - 0x60 : r);
    })
    .join()
    .toLowerCase()
    .replaceAll(RegExp(r'''[\s　_\-‐‑‒–—―・･.,，。()（）\[\]【】「」『』:：/／'’"]'''), '');

/// Reject answer names and aliases in Japanese, kana, or Latin script.
bool isSafeMapHintLabel(Station station, String label) {
  final name = _mapHintLabelKey(label);
  if (name.isEmpty ||
      station.blockedLabels.any(
        (blocked) => name.contains(_mapHintLabelKey(blocked)),
      )) {
    return false;
  }
  final aliases = [
    station.name,
    station.kana,
    ...station.answerAliases,
  ].map(_mapHintLabelKey);
  if (aliases.any(
    (key) =>
        name == key ||
        name.contains('$key駅') ||
        name.contains('${key}station') ||
        name.contains('$key${_mapHintLabelKey('ステーション')}') ||
        name.contains('${key}stn'),
  )) {
    return false;
  }
  if (aliases.any((key) => key.isNotEmpty && name.contains(key))) {
    return false;
  }
  if (station.allowedLabels.any(
    (allowed) => _mapHintLabelKey(allowed) == name,
  )) {
    return true;
  }
  return true;
}

class MapHintsPoc {
  MapHintsPoc._(
    this.stationId,
    this.facilities,
    this.routes,
    this.highSpeedRailways,
    this.representativeFacilities,
  );

  final String stationId;
  final Map<String, dynamic> facilities;
  final Map<String, dynamic> routes;
  final Map<String, dynamic> highSpeedRailways;
  final Map<String, dynamic> representativeFacilities;

  bool get hasFacilities => _features(facilities).isNotEmpty;
  bool get hasRoutes => _features(routes).isNotEmpty;
  bool get hasHighSpeedRailways => _features(highSpeedRailways).isNotEmpty;
  bool get hasRepresentativeFacilities =>
      _features(representativeFacilities).isNotEmpty;

  static List<dynamic> _features(Map<String, dynamic> collection) =>
      collection['features'] as List<dynamic>;

  factory MapHintsPoc.parse(String source, Station station) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid map hints document');
    }
    return MapHintsPoc.fromDecoded(decoded, station);
  }

  factory MapHintsPoc.fromDecoded(
    Map<String, dynamic> decoded,
    Station station,
  ) {
    if (decoded['schemaVersion'] != 2) {
      throw const FormatException('Unsupported map hints schema');
    }
    final stations = decoded['stations'];
    final row = stations is Map ? stations[station.id] : null;
    if (row is! Map ||
        row['latitude'] is! num ||
        row['longitude'] is! num ||
        (row['latitude'] as num).toDouble() != station.latitude ||
        (row['longitude'] as num).toDouble() != station.longitude) {
      throw const FormatException('Station map hints missing/mismatched');
    }

    Map<String, dynamic> collection(String key, String geometryType) {
      final raw = row[key];
      if (raw is! Map ||
          raw['type'] != 'FeatureCollection' ||
          raw['features'] is! List) {
        throw FormatException('Invalid $key feature collection');
      }
      final value = Map<String, dynamic>.from(raw);
      for (final rawFeature in value['features'] as List) {
        if (rawFeature is! Map ||
            rawFeature['type'] != 'Feature' ||
            rawFeature['geometry'] is! Map ||
            rawFeature['properties'] is! Map) {
          throw FormatException('Invalid $key feature');
        }
        final geometry = rawFeature['geometry'] as Map;
        if (geometry['type'] != geometryType ||
            geometry['coordinates'] is! List) {
          throw FormatException('Invalid $key geometry');
        }
        final coordinates = geometry['coordinates'] as List;
        final points = geometryType == 'Point' ? [coordinates] : coordinates;
        if (geometryType == 'LineString' && points.length < 2) {
          throw FormatException('Missing $key route vertices');
        }
        for (final point in points) {
          if (point is! List ||
              point.length != 2 ||
              point[0] is! num ||
              point[1] is! num ||
              !(point[0] as num).isFinite ||
              !(point[1] as num).isFinite ||
              (point[0] as num).abs() > 180 ||
              (point[1] as num).abs() > 90) {
            throw FormatException('Invalid $key position');
          }
        }
      }
      return value;
    }

    bool hasOnlyKeys(Map properties, Set<String> keys) =>
        properties.keys.toSet().difference(keys).isEmpty &&
        keys.difference(properties.keys.toSet()).isEmpty;

    final facilities = collection('facilities', 'Point');
    if (_features(facilities).length > 5) {
      throw const FormatException('At most five facility icons are allowed');
    }
    final facilityIds = <String>{};
    final facilityRanks = <int>{};
    for (final feature in _features(facilities)) {
      final properties = feature['properties'] as Map;
      if (!hasOnlyKeys(properties, {'kind', 'rank', 'osm_type', 'osm_id'}) ||
          !facilityKinds.contains(properties['kind']) ||
          properties['rank'] is! int ||
          properties['rank'] < 0 ||
          !facilityRanks.add(properties['rank'] as int) ||
          !['node', 'way', 'relation'].contains(properties['osm_type']) ||
          properties['osm_id'] is! int ||
          properties['osm_id'] <= 0 ||
          !facilityIds.add(
            '${properties['osm_type']}/${properties['osm_id']}',
          )) {
        throw const FormatException('Invalid anonymous facility icon');
      }
    }

    final services = decoded['services'];
    if (services is! Map) {
      throw const FormatException('Missing verified route services');
    }
    for (final entry in services.entries) {
      final service = entry.value;
      if (entry.key is! String ||
          (entry.key as String).trim().isEmpty ||
          service is! Map ||
          !hasOnlyKeys(service, {'name', 'color', 'relationIds'}) ||
          service['name'] is! String ||
          (service['name'] as String).trim().isEmpty ||
          service['color'] is! String ||
          !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(service['color'] as String) ||
          service['relationIds'] is! List ||
          (service['relationIds'] as List).isEmpty ||
          (service['relationIds'] as List).any((id) => id is! int || id <= 0) ||
          (service['relationIds'] as List).toSet().length !=
              (service['relationIds'] as List).length) {
        throw const FormatException('Invalid verified route service');
      }
    }
    final routes = collection('routes', 'LineString');
    for (final feature in _features(routes)) {
      final properties = feature['properties'] as Map;
      final service = services[properties['serviceId']];
      if (!hasOnlyKeys(properties, {
            'name',
            'color',
            'serviceId',
            'lineOffset',
            'osm_way_ids',
            'osm_relation_ids',
          }) ||
          service is! Map ||
          properties['name'] is! String ||
          (properties['name'] as String).trim().isEmpty ||
          properties['color'] != service['color'] ||
          properties['name'] != service['name'] ||
          properties['color'] is! String ||
          !RegExp(
            r'^#[0-9A-Fa-f]{6}$',
          ).hasMatch(properties['color'] as String) ||
          properties['osm_way_ids'] is! List ||
          (properties['osm_way_ids'] as List).isEmpty ||
          (properties['osm_way_ids'] as List).any(
            (id) => id is! int || id <= 0,
          ) ||
          properties['osm_relation_ids'] is! List ||
          (properties['osm_relation_ids'] as List).isEmpty ||
          service['relationIds'] is! List ||
          (properties['osm_relation_ids'] as List).any(
            (id) => !(service['relationIds'] as List).contains(id),
          ) ||
          properties['lineOffset'] is! num ||
          !(properties['lineOffset'] as num).isFinite ||
          (properties['lineOffset'] as num).abs() > 10) {
        throw const FormatException('Unverified route colour/membership');
      }
    }

    final highSpeedRailways = collection('highSpeedRailways', 'LineString');
    for (final feature in _features(highSpeedRailways)) {
      final properties = feature['properties'] as Map;
      if (!hasOnlyKeys(properties, {'railType', 'osm_way_ids'}) ||
          properties['railType'] != 'highSpeed' ||
          properties['osm_way_ids'] is! List ||
          (properties['osm_way_ids'] as List).isEmpty ||
          (properties['osm_way_ids'] as List).any(
            (id) => id is! int || id <= 0,
          )) {
        throw const FormatException('Invalid name-free high-speed railway');
      }
    }

    final representativeFacilities = collection(
      'representativeFacilities',
      'Point',
    );
    if (_features(representativeFacilities).length > 3) {
      throw const FormatException(
        'At most three representative facilities are allowed',
      );
    }
    final representativeIds = <String>{};
    final representativeRanks = <int>{};
    for (final feature in _features(representativeFacilities)) {
      final properties = feature['properties'] as Map;
      if (!hasOnlyKeys(properties, {
            'kind',
            'name',
            'rank',
            'osm_type',
            'osm_id',
          }) ||
          properties['kind'] != 'facility' ||
          properties['name'] is! String ||
          (properties['name'] as String).trim().isEmpty ||
          !isSafeMapHintLabel(station, properties['name'] as String) ||
          properties['rank'] is! int ||
          properties['rank'] < 0 ||
          !representativeRanks.add(properties['rank'] as int) ||
          !['node', 'way', 'relation'].contains(properties['osm_type']) ||
          properties['osm_id'] is! int ||
          properties['osm_id'] <= 0 ||
          !representativeIds.add(
            '${properties['osm_type']}/${properties['osm_id']}',
          )) {
        throw const FormatException('Invalid representative facility');
      }
    }

    return MapHintsPoc._(
      station.id,
      facilities,
      routes,
      highSpeedRailways,
      representativeFacilities,
    );
  }
}

Future<Map<String, dynamic>>? _asset;
final _cache = <String, Future<MapHintsPoc>>{};

Future<MapHintsPoc> loadMapHintsPoc(Station station) async {
  final key = '${station.id}:${station.latitude}:${station.longitude}';
  try {
    return await _cache.putIfAbsent(key, () async {
      final decoded = await (_asset ??= () async {
        final source = await rootBundle.loadString(
          'assets/maps/map_hints_poc.json',
        );
        final value = jsonDecode(source);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('Invalid map hints document');
        }
        return value;
      }());
      return MapHintsPoc.fromDecoded(decoded, station);
    });
  } catch (_) {
    _asset = null;
    _cache.remove(key);
    rethrow; // Retry UI; never fill missing reviewed data with guesses.
  }
}
