import 'dart:math';
import '../game/game.dart';
import 'map_hints_poc.dart';

const tileJsonUrl = String.fromEnvironment(
  'EKIDOKO_TILEJSON_URL',
  defaultValue: 'https://tiles.openfreemap.org/planet',
);
const glyphsUrl = 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';
const mapSpans = [500.0, 1000.0, 3000.0, 5000.0];
const highSpeedRailMaxDistanceMeters = 500.0;

/// Span of the shorter viewport side, using Web Mercator / 512px tiles.
double quizZoom(double latitude, double shorterSide, int hint) =>
    (log(
              40075016.68557849 *
                  cos(latitude * pi / 180) *
                  shorterSide /
                  (512 * mapSpans[hint]),
            ) /
            ln2)
        .clamp(0.0, 20.0);

// Labels are not answers: keep the final 駅 in exclusion phrases such as 札駅.
String _labelKey(String value) => value.runes
    .map((r) => String.fromCharCode(r >= 0x30a1 && r <= 0x30f6 ? r - 0x60 : r))
    .join()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s　_\-]'), '');

/// Hide station POIs and direct station-name references, while preserving
/// useful city landmarks (e.g. 名古屋城 and 京都タワー).
bool isSafeHintLabel(Station station, String label) {
  final name = _labelKey(label);
  if (name.isEmpty ||
      station.blockedLabels.any((s) => name.contains(_labelKey(s)))) {
    return false;
  }
  final aliases = [
    station.name,
    station.kana,
    ...station.answerAliases,
  ].map(_labelKey);
  // Direct station references always win, even over an allow-list mistake.
  if (aliases.any(
    (key) =>
        name == key ||
        name.contains('$key駅') ||
        name.contains('${key}station') ||
        name.contains('$keyステーション') ||
        name.contains('${key}stn'),
  )) {
    return false;
  }
  if (station.allowedLabels.any((s) => _labelKey(s) == name)) return true;
  return !aliases.any(name.contains);
}

bool isUsefulRailwayLabel(Station station, String label) =>
    !label.contains('貨物') &&
    !label.toLowerCase().contains('freight') &&
    isSafeHintLabel(station, label) &&
    ![
      station.name,
      station.kana,
      ...station.answerAliases,
    ].any((alias) => _labelKey(label).contains(_labelKey(alias)));

const _reviewedHighSpeedRailwayNames = {
  'tokyo': {'東海道新幹線', '東北新幹線'},
  'ueno': {'東北新幹線'},
  'kyoto': {'東海道新幹線'},
};

bool isHighSpeedRailwayLabel(Station station, String label) {
  final key = _labelKey(label);
  return (_reviewedHighSpeedRailwayNames[station.id] ?? const <String>{})
          .map(_labelKey)
          .contains(key) &&
      isUsefulRailwayLabel(station, label);
}

bool _highSpeedRailwayPassesNearStation(Station station, dynamic feature) {
  final points = feature['geometry']['coordinates'] as List;
  for (final point in points) {
    final dx =
        ((point[0] as num) - station.longitude) *
        cos(station.latitude * pi / 180) *
        111320;
    final dy = ((point[1] as num) - station.latitude) * 111320;
    if (sqrt(dx * dx + dy * dy) <= highSpeedRailMaxDistanceMeters) {
      return true;
    }
  }
  return false;
}

/// Own style: no external default style, sprites, station/road/water labels.
/// Only exact reviewed names from the actual vector data are permitted.
Map<String, dynamic> quizMapStyle(
  Station station,
  Map<String, dynamic> tileJson, {
  int hint = 0,
  Map<String, dynamic>? railways,
  Map<String, dynamic>? hintLabels,
  MapHintsPoc? poc,
}) {
  if (poc != null && poc.stationId != station.id) {
    throw ArgumentError('PoC data belongs to a different station');
  }
  final routeData = poc?.routes ?? railways;
  final highSpeedRailways = <Map<String, dynamic>>[
    if (poc != null)
      for (final feature in railways?['features'] as List? ?? <dynamic>[])
        if (isHighSpeedRailwayLabel(
              station,
              feature['properties']['name'] as String,
            ) &&
            _highSpeedRailwayPassesNearStation(station, feature))
          {
            'type': 'Feature',
            'geometry': feature['geometry'],
            // The initial clue exposes only a rail category, never its name.
            'properties': {'railType': 'highSpeed'},
          },
  ];
  final name = [
    'coalesce',
    ['get', 'name:ja'],
    ['get', 'name'],
    '',
  ];
  final safeHints = <dynamic>[
    for (final feature in hintLabels?['features'] as List? ?? <dynamic>[])
      if (isSafeHintLabel(station, feature['properties']['name'] as String))
        feature,
  ];
  if (poc != null) {
    final representativeIds =
        mapHintsPocRepresentativeFacilityIds[station.id] ?? const <String>{};
    safeHints.removeWhere((feature) {
      final properties = feature['properties'];
      return properties['kind'] == 'facility' &&
          !representativeIds.contains(
            '${properties['osm_type']}/${properties['osm_id']}',
          );
    });
  }
  Map<String, dynamic> layer(
    String id,
    String type,
    String sourceLayer,
    Map<String, dynamic> paint, {
    List<Object>? filter,
    Map<String, dynamic>? layout,
  }) => {
    'id': id,
    'type': type,
    'source': 'openmaptiles',
    'source-layer': sourceLayer,
    'paint': paint,
    'filter': ?filter,
    'layout': ?layout,
  };
  final rail = [
    'in',
    ['get', 'class'],
    [
      'literal',
      ['rail', 'transit'],
    ],
  ];
  final labels = <String, dynamic>{
    'visibility': hint >= 3 ? 'visible' : 'none',
    'text-field': name,
    'text-font': ['Noto Sans Regular'],
    'text-size': 12,
    'text-padding': 8,
    'symbol-sort-key': [
      'coalesce',
      ['get', 'rank'],
      0,
    ],
    'text-max-width': 8,
  };
  return {
    'version': 8,
    'name': 'ekidoko quiz',
    'glyphs': glyphsUrl,
    'sources': {
      'named-railways': {
        'type': 'geojson',
        'buffer': 256,
        'tolerance': 0.25,
        'data': {
          'type': 'FeatureCollection',
          'features': [
            for (final feature
                in routeData?['features'] as List? ?? <dynamic>[])
              if (isUsefulRailwayLabel(
                station,
                feature['properties']['name'] as String,
              ))
                feature,
          ],
        },
      },
      'reviewed-hints': {
        'type': 'geojson',
        'data': {'type': 'FeatureCollection', 'features': safeHints},
      },
      'openmaptiles': {
        'type': 'vector',
        'tiles': tileJson['tiles'],
        'minzoom': tileJson['minzoom'] ?? 0,
        'maxzoom': tileJson['maxzoom'] ?? 14,
        'attribution': tileJson['attribution'],
      },
      if (poc != null)
        'poc-facilities': {'type': 'geojson', 'data': poc.facilities},
      if (poc != null)
        'high-speed-railways': {
          'type': 'geojson',
          'data': {'type': 'FeatureCollection', 'features': highSpeedRailways},
        },
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': '#f1f3ef'},
      },
      layer(
        'parks',
        'fill',
        'landcover',
        {'fill-color': '#d4e6cb'},
        filter: [
          'in',
          ['get', 'class'],
          [
            'literal',
            ['wood', 'grass'],
          ],
        ],
      ),
      layer(
        'green-landuse',
        'fill',
        'landuse',
        {'fill-color': '#d4e6cb'},
        filter: [
          'in',
          ['get', 'class'],
          [
            'literal',
            ['park', 'cemetery', 'recreation_ground'],
          ],
        ],
      ),
      layer('water', 'fill', 'water', {'fill-color': '#b9dce8'}),
      layer('waterways', 'line', 'waterway', {
        'line-color': '#b9dce8',
        'line-width': 2,
      }),
      layer('buildings', 'fill', 'building', {
        'fill-color': '#e0e4df',
        'fill-outline-color': '#d0d7ce',
      }),
      layer(
        'road-areas',
        'fill',
        'transportation',
        {'fill-color': '#ffffff'},
        filter: [
          '==',
          ['geometry-type'],
          'Polygon',
        ],
      ),
      layer(
        'road-casing',
        'line',
        'transportation',
        {
          'line-color': '#dfe3dd',
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            2,
            18,
            14,
          ],
        },
        filter: [
          'all',
          [
            '==',
            ['geometry-type'],
            'LineString',
          ],
          ['!', rail],
        ],
      ),
      layer(
        'roads',
        'line',
        'transportation',
        {
          'line-color': '#ffffff',
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            1,
            18,
            10,
          ],
        },
        filter: [
          'all',
          [
            '==',
            ['geometry-type'],
            'LineString',
          ],
          ['!', rail],
        ],
      ),
      layer(
        'railways',
        'line',
        'transportation',
        {
          // Actual OpenMapTiles classes, not guessed branded route colors.
          'line-color': [
            'match',
            ['get', 'class'],
            'transit',
            '#547fa9',
            '#247965',
          ],
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            1.5,
            18,
            3.4,
          ],
        },
        filter: rail,
        layout: {'line-cap': 'round', 'line-join': 'round'},
      ),
      layer('rail-sleepers', 'line', 'transportation', {
        'line-color': [
          'match',
          ['get', 'class'],
          'transit',
          '#acc6dd',
          '#9ec7b4',
        ],
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          12,
          1.5,
          18,
          5,
        ],
        'line-dasharray': [0.2, 3],
      }, filter: rail),
      if (poc != null) ...[
        {
          'id': 'high-speed-rail-casing',
          'type': 'line',
          'source': 'high-speed-railways',
          'layout': {'line-cap': 'round', 'line-join': 'round'},
          'paint': {
            'line-color': '#f7f3fa',
            'line-width': [
              'interpolate',
              ['linear'],
              ['zoom'],
              12,
              2.8,
              18,
              5.4,
            ],
          },
        },
        {
          'id': 'high-speed-rail',
          'type': 'line',
          'source': 'high-speed-railways',
          'layout': {'line-cap': 'round', 'line-join': 'round'},
          'paint': {
            // Neutral category colour, not an operator or service brand colour.
            'line-color': '#6f6686',
            'line-width': [
              'interpolate',
              ['linear'],
              ['zoom'],
              12,
              1.6,
              18,
              3.4,
            ],
          },
        },
      ],
      {
        'id': 'named-railway-colors',
        'type': 'line',
        'source': 'named-railways',
        'layout': {
          'visibility': hint >= (poc != null ? 1 : 2) ? 'visible' : 'none',
          'line-cap': 'round',
          'line-join': 'round',
        },
        'paint': {
          'line-color': ['get', 'color'],
          if (poc != null) 'line-offset': ['get', 'lineOffset'],
          'line-width': [
            'interpolate',
            ['linear'],
            ['zoom'],
            12,
            2.2,
            18,
            4,
          ],
        },
      },
      if (poc == null)
        {
          'id': 'hint-facility-markers',
          'type': 'circle',
          'source': 'reviewed-hints',
          'filter': [
            '==',
            ['get', 'kind'],
            'facility',
          ],
          'layout': {'visibility': hint >= 3 ? 'visible' : 'none'},
          'paint': {
            'circle-radius': 3.5,
            'circle-color': '#c47a3f',
            'circle-stroke-color': '#fff7ed',
            'circle-stroke-width': 2.5,
          },
        },
      for (final entry in {
        'hint-places': 'place',
        'hint-facilities': 'facility',
      }.entries)
        {
          'id': entry.key,
          'type': 'symbol',
          'source': 'reviewed-hints',
          'filter': [
            '==',
            ['get', 'kind'],
            entry.value,
          ],
          'layout': {
            ...labels,
            if (entry.value == 'place') ...{
              'text-variable-anchor': [
                'center',
                'top',
                'bottom',
                'left',
                'right',
              ],
              'text-radial-offset': 0.5,
              'text-padding': 2,
              'text-max-width': 6,
            },
            if (entry.value == 'facility') ...{
              'text-size': 13,
              'text-anchor': 'top',
              'text-offset': [0, 0.8],
            },
          },
          'paint': {
            'text-color': entry.value == 'facility' ? '#a45e29' : '#65766b',
            'text-halo-color': '#ffffff',
            'text-halo-width': 2,
          },
        },
      // Later symbol layers win collision placement. Keep route names
      // visible at hint 3 without allowing overlapping text.
      {
        'id': 'railway-labels',
        'type': 'symbol',
        'source': 'named-railways',
        'layout': {
          'visibility': hint >= 2 ? 'visible' : 'none',
          'symbol-placement': 'line',
          'symbol-spacing': 180,
          'text-field': ['get', 'name'],
          'text-font': ['Noto Sans Bold'],
          'text-size': 13,
          'text-padding': 4,
          'text-max-angle': 35,
          'text-keep-upright': true,
          'text-rotation-alignment': 'map',
        },
        'paint': {
          'text-color': ['get', 'color'],
          'text-halo-color': '#ffffff',
          'text-halo-width': 2.5,
        },
      },
      if (poc != null)
        {
          'id': 'poc-facility-icons',
          'type': 'symbol',
          'source': 'poc-facilities',
          'layout': {
            // Register the six vector-derived images before making this layer visible.
            'visibility': 'none',
            'icon-image': [
              'concat',
              'facility-',
              ['get', 'kind'],
            ],
            // iOS decodes the 48px sprite at the device scale (16pt on 3x).
            // Keep the close-range clue near 24pt, then reduce overlap as the
            // camera reveals more route labels through hint 2.
            'icon-size': [
              'interpolate',
              ['linear'],
              ['zoom'],
              12,
              1.0,
              15.5,
              1.5,
            ],
            'icon-padding': 3,
            // At most five reviewed icons are present. Keep them visible
            // through hint 2 without suppressing route labels. At hint 3 the
            // widget hides this anonymous layer in favour of named landmarks.
            'icon-allow-overlap': true,
            'icon-ignore-placement': true,
            'symbol-sort-key': ['get', 'rank'],
          },
        },
    ],
  };
}
