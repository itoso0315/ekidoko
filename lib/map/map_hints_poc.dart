import 'dart:convert';
import 'package:flutter/services.dart';
import '../data/station_catalog.dart';

// Deliberate rollout boundary. Facility and route additions are data changes.
const mapHintsPocStationIds = {'tokyo', 'ueno', 'kyoto'};
const facilityKinds = {
  'education',
  'hospital',
  'religion',
  'culture',
  'shopping',
  'stadium',
};

class MapHintsPoc {
  MapHintsPoc._(this.stationId, this.facilities, this.routes);
  final String stationId;
  final Map<String, dynamic> facilities;
  final Map<String, dynamic> routes;

  factory MapHintsPoc.parse(String source, Station station) {
    final data = jsonDecode(source) as Map<String, dynamic>;
    final row = data['stations'][station.id] as Map?;
    if (row == null ||
        row['latitude'] != station.latitude ||
        row['longitude'] != station.longitude) {
      throw const FormatException('PoC station coordinates missing/mismatched');
    }
    Map<String, dynamic> collection(String key, String type) {
      final value = Map<String, dynamic>.from(row[key] as Map);
      final features = value['features'] as List;
      if (value['type'] != 'FeatureCollection') {
        throw const FormatException('Invalid PoC feature collection');
      }
      for (final f in features) {
        if (f['type'] != 'Feature' || f['geometry']['type'] != type) {
          throw const FormatException('Invalid PoC geometry');
        }
        final coordinates = f['geometry']['coordinates'] as List;
        final points = type == 'Point' ? [coordinates] : coordinates;
        if (type == 'LineString' && points.length < 2) {
          throw const FormatException('Missing real route vertices');
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
            throw const FormatException('Invalid PoC position');
          }
        }
      }
      return value;
    }

    final facilities = collection('facilities', 'Point');
    if ((facilities['features'] as List).length > 5) {
      throw const FormatException('PoC permits at most five facility icons');
    }
    final ids = <String>{};
    final ranks = <int>{};
    for (final f in facilities['features']) {
      final p = f['properties'] as Map;
      if (!facilityKinds.contains(p['kind']) ||
          p['rank'] is! int ||
          p['rank'] < 0 ||
          !ranks.add(p['rank'] as int) ||
          !['node', 'way', 'relation'].contains(p['osm_type']) ||
          p['osm_id'] is! int ||
          p['osm_id'] <= 0 ||
          !ids.add('${p['osm_type']}/${p['osm_id']}') ||
          p.keys.any(
            (k) => !['kind', 'rank', 'osm_type', 'osm_id'].contains(k),
          )) {
        throw const FormatException('Unreviewed/duplicate/named facility icon');
      }
    }
    final routes = collection('routes', 'LineString');
    for (final f in routes['features']) {
      final p = f['properties'] as Map;
      final service = (data['services'] as Map)[p['serviceId']] as Map?;
      if (service == null ||
          p['color'] != service['color'] ||
          p['name'] != service['name'] ||
          !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(p['color'] as String) ||
          p['osm_way_ids'] is! List ||
          (p['osm_way_ids'] as List).isEmpty ||
          (p['osm_way_ids'] as List).any((id) => id is! int || id <= 0) ||
          p['osm_relation_ids'] is! List ||
          (p['osm_relation_ids'] as List).isEmpty ||
          (p['osm_relation_ids'] as List).any(
            (id) => !(service['relationIds'] as List).contains(id),
          ) ||
          p['lineOffset'] is! num ||
          !(p['lineOffset'] as num).isFinite ||
          (p['lineOffset'] as num).abs() > 10) {
        throw const FormatException('Unverified PoC route/colour/membership');
      }
    }
    return MapHintsPoc._(station.id, facilities, routes);
  }
}

Future<String>? _asset;
final _cache = <String, Future<MapHintsPoc>>{};

Future<MapHintsPoc?> loadMapHintsPoc(Station station) async {
  if (!mapHintsPocStationIds.contains(station.id)) return null;
  final key = '${station.id}:${station.latitude}:${station.longitude}';
  try {
    return await _cache.putIfAbsent(key, () async {
      final source = await (_asset ??= rootBundle.loadString(
        'assets/maps/map_hints_poc.json',
      ));
      return MapHintsPoc.parse(source, station);
    });
  } catch (_) {
    _asset = null;
    _cache.remove(key);
    rethrow; // Retry UI; never fill missing POIs or routes with guesses.
  }
}
