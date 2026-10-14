import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../data/station_catalog.dart';
import 'quiz_map_style.dart';

/// Bundled OSM hints for reviewed stations; generic read-only retrieval for a
/// newly registered station. Production should bundle data via the prep tool.
class MapHints {
  const MapHints(this.railways, this.labels);
  final Map<String, dynamic> railways;
  final Map<String, dynamic> labels;
}

Future<Map<String, dynamic>>? _asset;
final _cache = <String, Future<MapHints>>{};
const _endpoint = 'https://overpass-api.de/api/interpreter';
DateTime? _retryAfter;

Future<MapHints> loadMapHints(Station station) {
  final key = '${station.id}:${station.latitude}:${station.longitude}';
  return _cache.putIfAbsent(key, () async {
    try {
      final data = await (_asset ??= rootBundle
          .loadString('assets/maps/station_hints.json')
          .then((value) => jsonDecode(value) as Map<String, dynamic>));
      final row = data[station.id];
      if (row is Map &&
          row['latitude'] == station.latitude &&
          row['longitude'] == station.longitude) {
        return MapHints(
          Map<String, dynamic>.from(row['railways'] as Map),
          Map<String, dynamic>.from(row['labels'] as Map),
        );
      }
      if (!const bool.fromEnvironment(
        'EKIDOKO_ALLOW_OSM_HINT_FETCH',
        defaultValue: kDebugMode,
      )) {
        throw const FormatException('Prepare bundled OSM hints before release');
      }
      return await fetchMapHints(station);
    } catch (_) {
      _cache.remove(key); // Retry can recover from a transient network failure.
      rethrow;
    }
  });
}

String osmHintQuery(Station station) {
  final point = '${station.latitude},${station.longitude}';
  return '[out:json][timeout:15][maxsize:67108864];'
      'way[railway~"^(rail|subway|light_rail|tram)\$"][name](around:8000,$point);out tags geom;('
      'node[name][place~"^(suburb|quarter|neighbourhood|city|town)\$"](around:4000,$point);'
      'nwr[name][leisure=park](around:4000,$point);'
      'nwr[name][tourism~"^(museum|attraction|gallery)\$"](around:4000,$point);'
      'nwr[name][amenity~"^(townhall|university|place_of_worship)\$"](around:4000,$point);'
      ');out tags center;';
}

Future<MapHints> fetchMapHints(Station station) async {
  if (_retryAfter != null && DateTime.now().isBefore(_retryAfter!)) {
    throw const HttpException('OSM hint retry cooldown');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final uri = Uri.parse(
      _endpoint,
    ).replace(queryParameters: {'data': osmHintQuery(station)});
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 8));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'ekidoko/1.0 (station-map prototype)',
    );
    final response = await request.close().timeout(const Duration(seconds: 18));
    if (response.statusCode == 429 || response.statusCode == 406) {
      _retryAfter = DateTime.now().add(const Duration(seconds: 30));
    }
    if (response.statusCode != 200) {
      throw const HttpException('OSM hints unavailable');
    }
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 18));
    return mapHintsFromOsm(station, jsonDecode(body) as Map<String, dynamic>);
  } finally {
    client.close(force: true);
  }
}

/// OSM way names/vertices only. No inference of route names from positions.
MapHints mapHintsFromOsm(Station station, Map<String, dynamic> data) {
  if (data['remark'] != null || data['elements'] is! List) {
    throw const FormatException('Incomplete OSM hint response');
  }
  final railways = <dynamic>[];
  final labels = <dynamic>[];
  for (final item in data['elements'] as List) {
    final tags = item['tags'] as Map? ?? const {};
    var name = (tags['name:ja'] ?? tags['name'] ?? '') as String;
    if (tags['railway'] != null) {
      if (item['type'] != 'way' ||
          !['rail', 'subway', 'light_rail', 'tram'].contains(tags['railway']) ||
          tags['railway:traffic_mode'] == 'freight' ||
          ['yard', 'siding', 'spur'].contains(tags['service'])) {
        continue;
      }
      for (final prefix in ['東京メトロ', '都営地下鉄', '京王電鉄', 'JR', '東急']) {
        if (name.startsWith(prefix)) name = name.substring(prefix.length);
      }
      if (tags['railway'] == 'tram') {
        name = name.replaceFirst(RegExp(r'^.+?市電(?=.+線)'), '');
      }
      name = name.split(';').first.replaceFirst(RegExp(r'\s+\([^)]*\)$'), '');
      if (name == '東海道本線（横須賀線）') name = '横須賀線';
      if (!isUsefulRailwayLabel(station, name)) continue;
      final points = [
        for (final p in item['geometry'] as List? ?? [])
          if (p != null) [p['lon'], p['lat']],
      ];
      if (points.length < 2) continue;
      railways.add({
        'type': 'Feature',
        'geometry': {'type': 'LineString', 'coordinates': points},
        'properties': {
          'name': name,
          'color': '#718e86',
          'osm_way_ids': [item['id']],
        },
      });
      continue;
    }
    if (tags['public_transport'] != null || !isSafeHintLabel(station, name)) {
      continue;
    }
    final place = [
      'suburb',
      'quarter',
      'neighbourhood',
      'city',
      'town',
    ].contains(tags['place']);
    final facility =
        tags['leisure'] == 'park' ||
        ['museum', 'attraction', 'gallery'].contains(tags['tourism']) ||
        [
          'townhall',
          'university',
          'place_of_worship',
        ].contains(tags['amenity']);
    if (!place && !facility) continue;
    final allowed = station.allowedLabels.contains(name);
    if (tags['tourism'] == 'attraction' &&
        !allowed &&
        tags['historic'] == null &&
        tags['man_made'] != 'tower' &&
        tags['leisure'] != 'park') {
      continue;
    }
    final rank = place
        ? (name.contains('丁目') ? 2 : 0)
        : (allowed
              ? 0
              : (tags['leisure'] == 'park' ||
                        tags['tourism'] == 'museum' ||
                        ['townhall', 'university'].contains(tags['amenity'])
                    ? 1
                    : 2));
    final point = item['lat'] != null ? item : item['center'];
    if (point == null) continue;
    labels.add({
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [point['lon'], point['lat']],
      },
      'properties': {
        'name': name,
        'kind': place ? 'place' : 'facility',
        'rank': rank,
        'osm_type': item['type'],
        'osm_id': item['id'],
      },
    });
  }
  if (railways.isEmpty || labels.isEmpty) {
    throw const FormatException('OSM railway/landmark hints missing');
  }
  return MapHints(
    {'type': 'FeatureCollection', 'features': railways},
    {
      'type': 'FeatureCollection',
      'features': selectHintLabels(station, labels),
    },
  );
}

/// Two small groups keep nearby markers from covering the rail geometry.
List<dynamic> selectHintLabels(Station station, List<dynamic> labels) {
  double distanceSquared(List a, List b) {
    final dx =
        ((a[0] as num) - (b[0] as num)) *
        cos(station.latitude * pi / 180) *
        111320;
    final dy = ((a[1] as num) - (b[1] as num)) * 111320;
    return dx * dx + dy * dy;
  }

  final center = [station.longitude, station.latitude];
  labels.sort((a, b) {
    final rank = (a['properties']['rank'] as int).compareTo(
      b['properties']['rank'] as int,
    );
    return rank != 0
        ? rank
        : distanceSquared(
            a['geometry']['coordinates'] as List,
            center,
          ).compareTo(
            distanceSquared(b['geometry']['coordinates'] as List, center),
          );
  });
  final selected = <dynamic>[];
  final counts = {'place': 0, 'facility': 0};
  for (final feature in labels) {
    final kind = feature['properties']['kind'] as String;
    if (counts[kind]! >= 18) continue;
    if (selected.any(
      (other) =>
          other['properties']['name'] == feature['properties']['name'] &&
          distanceSquared(
                other['geometry']['coordinates'] as List,
                feature['geometry']['coordinates'] as List,
              ) <
              250000,
    )) {
      continue;
    }
    selected.add(feature);
    counts[kind] = counts[kind]! + 1;
  }
  return selected;
}
