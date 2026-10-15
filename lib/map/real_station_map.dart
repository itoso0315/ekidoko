import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../game/game.dart';
import 'map_availability.dart';
import 'quiz_map_style.dart';
import 'map_hint_data.dart';
import 'map_hints_poc.dart';
import 'facility_icons.dart';

/// Loaded via HTTPS on each new map / retry; no bulk tile downloads.
Future<Map<String, dynamic>> loadTileJson() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client
        .getUrl(Uri.parse(tileJsonUrl))
        .timeout(const Duration(seconds: 8));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'ekidoko/1.0 (iOS map prototype)',
    );
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw const HttpException('Tile source unavailable');
    }
    final content = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 8));
    final json = jsonDecode(content) as Map<String, dynamic>;
    final tiles = json['tiles'];
    if (tiles is! List ||
        tiles.isEmpty ||
        tiles.any((t) => t is! String || !t.startsWith('https://'))) {
      throw const FormatException('Invalid tile source');
    }
    final layers =
        (json['vector_layers'] as List?)?.map((l) => l['id']).toSet() ?? {};
    if (!layers.containsAll([
      'transportation',
      'building',
      'water',
      'place',
      'poi',
    ])) {
      throw const FormatException('Unsupported vector schema');
    }
    return json;
  } finally {
    client.close(force: true);
  }
}

class RealStationMap extends StatefulWidget {
  const RealStationMap({
    super.key,
    required this.station,
    required this.hint,
    required this.reveal,
    this.tileLoader = loadTileJson,
    this.loadTimeout = const Duration(seconds: 25),
  });
  final Station station;
  final int hint;
  final bool reveal;
  final Future<Map<String, dynamic>> Function() tileLoader;
  final Duration loadTimeout;
  @override
  State<RealStationMap> createState() => RealStationMapState();
}

class RealStationMapState extends State<RealStationMap> {
  MapLibreMapController? _controller;
  String? _style;
  String? _error;
  bool _ready = false;
  bool _styleLoaded = false;
  bool _nativeIdle = false;
  bool _applying = false;
  bool _checking = false;
  int _idleEvent = 0;
  MapHintsPoc? _pocHints;
  int _generation = 0;
  int _revision = 0;
  Timer? _timer;
  Size _size = Size.zero;
  MapAvailabilityScope? _availability;

  // Exposed for the device integration test and diagnostic inspection only.
  MapLibreMapController? get controller => _controller;
  bool get ready => _ready;
  String? get error => _error;
  Map<String, int> renderedFeatureCounts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _availability = MapAvailabilityScope.of(context);
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }

  void _notifyAvailability(bool ready) {
    final gate = _availability;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && gate == _availability) {
        gate?.notifier?.report(gate.request, ready);
      }
    });
  }

  void _waiting() {
    _ready = false;
    _notifyAvailability(false);
    _timer?.cancel();
    final generation = _generation;
    _timer = Timer(widget.loadTimeout, () {
      if (mounted && generation == _generation && !_ready) {
        _fail('地図の読み込みに時間がかかっています。\n通信環境を確認して再試行してください。');
      }
    });
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _controller = null;
    _styleLoaded = false;
    _nativeIdle = false;
    _style = null;
    _pocHints = null;
    _error = null;
    _waiting();
    if (mounted) setState(() {});
    try {
      final tileJson = await widget.tileLoader();
      if (!mounted || generation != _generation) return;
      final hints = await loadMapHints(widget.station);
      final poc = await loadMapHintsPoc(widget.station);
      final style = jsonEncode(
        quizMapStyle(
          widget.station,
          tileJson,
          hint: widget.hint,
          railways: hints.railways,
          hintLabels: hints.labels,
          poc: poc,
        ),
      );
      if (!mounted || generation != _generation || _error != null) return;
      setState(() {
        _pocHints = poc;
        _style = style;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        _fail('地図を取得できませんでした。\n通信環境を確認して再試行してください。');
      }
    }
  }

  void _fail(String message) {
    _timer?.cancel();
    if (!mounted) return;
    setState(() {
      _error = message;
      _ready = false;
    });
    _notifyAvailability(false);
  }

  CameraPosition get _camera => CameraPosition(
    target: LatLng(widget.station.latitude, widget.station.longitude),
    zoom: quizZoom(
      widget.station.latitude,
      min(_size.width, _size.height),
      widget.hint,
    ),
    bearing: 0,
    tilt: 0,
  );

  @override
  void didUpdateWidget(covariant RealStationMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.station.id != oldWidget.station.id) {
      _load();
      return;
    }
    if (widget.hint != oldWidget.hint) {
      _waiting();
      _revision++;
      _nativeIdle = false;
      _applyCameraAndLabels();
    }
  }

  Future<void> _applyCameraAndLabels() async {
    if (!_styleLoaded ||
        _controller == null ||
        _applying ||
        _error != null ||
        _size.isEmpty) {
      return;
    }
    _applying = true;
    final generation = _generation;
    final controller = _controller!;
    try {
      int revision;
      do {
        revision = _revision;
        await controller.setLayerVisibility(
          'named-railway-colors',
          widget.hint >= (_pocHints != null ? 1 : 2),
        );
        await controller.setLayerVisibility('railway-labels', widget.hint >= 2);
        await controller.setLayerVisibility('hint-places', widget.hint >= 3);
        if (_pocHints == null) {
          await controller.setLayerVisibility(
            'hint-facility-markers',
            widget.hint >= 3,
          );
        } else {
          // At 5 km, unnamed category icons become ambiguous. Leave only the
          // curated, named representative facilities shown by the text layer.
          await controller.setLayerVisibility(
            'poc-facility-icons',
            widget.hint < 3,
          );
        }
        await controller.setLayerVisibility(
          'hint-facilities',
          widget.hint >= 3,
        );
        await controller.animateCamera(
          CameraUpdate.newCameraPosition(_camera),
          duration: const Duration(milliseconds: 650),
        );
      } while (mounted && generation == _generation && revision != _revision);
    } catch (_) {
      if (mounted && generation == _generation) {
        _fail('地図の表示を更新できませんでした。\n再試行してください。');
      }
    } finally {
      _applying = false;
      if (mounted && generation == _generation && _nativeIdle) {
        _checkRenderedMap();
      }
    }
  }

  void _onIdle() {
    _idleEvent++;
    _nativeIdle = true;
    _checkRenderedMap();
  }

  Future<void> _onStyleLoaded(int generation) async {
    if (generation != _generation || !mounted || _error != null) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      if (_pocHints != null) {
        final images = await facilityIconImages();
        for (final entry in images.entries) {
          if (!mounted || generation != _generation || _error != null) return;
          await controller.addImage(entry.key, entry.value);
        }
        if (!mounted || generation != _generation || _error != null) return;
      }
      if (!mounted || generation != _generation || _error != null) return;
      _styleLoaded = true;
      await _applyCameraAndLabels();
    } catch (_) {
      if (mounted && generation == _generation) {
        _fail('地図のアイコンを準備できませんでした。\n再試行してください。');
      }
    }
  }

  /// Style-loaded alone does not prove tiles are visible. Require native idle
  /// plus rendered geometry (and hint labels) before enabling an answer.
  /// Wide-area tiles omit buildings below their source minzoom of 13.
  Future<void> _checkRenderedMap() async {
    if (_checking ||
        _applying ||
        !_styleLoaded ||
        !_nativeIdle ||
        _controller == null ||
        _ready ||
        _error != null) {
      return;
    }
    _checking = true;
    final generation = _generation;
    final revision = _revision;
    final idleEvent = _idleEvent;
    final controller = _controller!;
    try {
      final rect = Offset.zero & _size;
      final roads = await controller.queryRenderedFeaturesInRect(rect, [
        'roads',
      ], null);
      final rails = await controller.queryRenderedFeaturesInRect(rect, [
        'railways',
      ], null);
      final buildings = await controller.queryRenderedFeaturesInRect(rect, [
        'buildings',
      ], null);
      final routeLabels = widget.hint >= 2
          ? await controller.queryRenderedFeaturesInRect(rect, [
              'railway-labels',
            ], null)
          : null;
      final labels = widget.hint >= 3
          ? await controller.queryRenderedFeaturesInRect(rect, [
              'hint-places',
              'hint-facilities',
            ], null)
          : null;
      final icons = _pocHints != null && widget.hint < 3
          ? await controller.queryRenderedFeaturesInRect(rect, [
              'poc-facility-icons',
            ], null)
          : null;
      var expectsIcon = false;
      if (_pocHints != null && widget.hint < 3) {
        final bounds = await controller.getVisibleRegion();
        expectsIcon = (_pocHints!.facilities['features'] as List).any((f) {
          final point = f['geometry']['coordinates'] as List;
          return point[0] >= bounds.southwest.longitude &&
              point[0] <= bounds.northeast.longitude &&
              point[1] >= bounds.southwest.latitude &&
              point[1] <= bounds.northeast.latitude;
        });
      }
      final routeColors = _pocHints != null && widget.hint >= 1
          ? await controller.queryRenderedFeaturesInRect(rect, [
              'named-railway-colors',
            ], null)
          : null;
      if (!mounted ||
          generation != _generation ||
          revision != _revision ||
          _error != null) {
        return;
      }
      renderedFeatureCounts = {
        'roads': roads.length,
        'rails': rails.length,
        'buildings': buildings.length,
        'labels': labels?.length ?? 0,
        'routeLabels': routeLabels?.length ?? 0,
        if (icons != null) 'facilityIcons': icons.length,
        if (routeColors != null) 'routeColors': routeColors.length,
      };
      if (roads.isNotEmpty &&
          rails.isNotEmpty &&
          (widget.hint >= 2 || buildings.isNotEmpty) &&
          (labels == null || labels.isNotEmpty) &&
          (routeLabels == null || routeLabels.isNotEmpty) &&
          (!expectsIcon || icons!.isNotEmpty) &&
          (routeColors == null || routeColors.isNotEmpty)) {
        _timer?.cancel();
        setState(() {
          _ready = true;
        });
        _notifyAvailability(true);
      }
      // If blank or incomplete, the deadline produces the retry UI.
    } catch (_) {
      if (mounted && generation == _generation) {
        _fail('地図の描画を確認できませんでした。\n再試行してください。');
      }
    } finally {
      _checking = false;
      // A hint update or native idle can arrive while the previous native
      // feature queries are in flight. Re-run the check that was coalesced by
      // _checking instead of waiting until the 25-second deadline.
      if (mounted &&
          generation == _generation &&
          !_ready &&
          _error == null &&
          _nativeIdle &&
          !_applying &&
          (revision != _revision || idleEvent != _idleEvent)) {
        _checkRenderedMap();
      }
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(26),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _size) {
          _size = size;
          if (_styleLoaded) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _waiting();
                _revision++;
                _nativeIdle = false;
              });
              _applyCameraAndLabels();
            });
          }
        }
        final generation = _generation;
        return Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xffedf1eb)),
            if (_style != null && _error == null)
              IgnorePointer(
                key: const ValueKey('locked-real-map'),
                child: ExcludeSemantics(
                  child: MapLibreMap(
                    key: ValueKey('map-$_generation'),
                    styleString: _style!,
                    initialCameraPosition: _camera,
                    // We use style layers and Flutter overlays, not annotation
                    // managers. Avoid their asynchronous setup during disposal.
                    annotationOrder: const [],
                    trackCameraPosition: true,
                    scrollGesturesEnabled: false,
                    zoomGesturesEnabled: false,
                    rotateGesturesEnabled: false,
                    tiltGesturesEnabled: false,
                    doubleClickZoomEnabled: false,
                    dragEnabled: false,
                    compassEnabled: false,
                    myLocationEnabled: false,
                    attributionButtonPosition: null,
                    onMapCreated: (controller) {
                      if (generation == _generation) _controller = controller;
                    },
                    onStyleLoadedCallback: () => _onStyleLoaded(generation),
                    onMapIdle: () {
                      if (generation == _generation && mounted) _onIdle();
                    },
                  ),
                ),
              ),
            if (widget.reveal && _ready)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.location_on_rounded,
                      color: Color(0xff187864),
                      size: 34,
                    ),
                    MapChip('${widget.station.name}駅'),
                  ],
                ),
              ),
            if (_error == null) ...[
              const Positioned(top: 12, left: 12, child: MapChip('実地図')),
              const Positioned(top: 12, right: 12, child: MapChip('↑ N')),
              if (widget.hint >= 3)
                Positioned(
                  bottom: 36,
                  right: 12,
                  child: MapChip(
                    _pocHints == null ? '● 施設' : '代表施設名',
                    color: const Color(0xffa45e29),
                    backgroundColor: const Color(0xfffff1e3),
                  ),
                ),
              Positioned(
                bottom: 36,
                left: 12,
                child: MapChip('範囲 約${Game.ranges[widget.hint]}'),
              ),
            ],
            if (!_ready && _error == null)
              IgnorePointer(
                child: ColoredBox(
                  color: const Color(
                    0xfff4f7f1,
                  ).withValues(alpha: _styleLoaded ? .40 : 1),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xff187864),
                        ),
                        SizedBox(height: 14),
                        MapChip('地図を読み込んでいます…'),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              ColoredBox(
                color: const Color(0xffedf1eb),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.wifi_off_rounded,
                          color: Color(0xff63786e),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, height: 1.6),
                        ),
                        TextButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh_rounded, size: 18),
                          label: const Text('再試行'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Material(
                color: Colors.white.withValues(alpha: .95),
                child: InkWell(
                  onTap: () => showMapAttribution(context),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    child: Text(
                      '© OpenMapTiles · © OpenStreetMap contributors',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 9, color: Color(0xff52645f)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class MapChip extends StatelessWidget {
  const MapChip(
    this.text, {
    super.key,
    this.color = const Color(0xff52645f),
    this.backgroundColor = Colors.white,
  });
  final String text;
  final Color color;
  final Color backgroundColor;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: backgroundColor.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
    ),
  );
}

void showMapAttribution(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '地図の出典・ライセンス',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            '地図データ：OpenStreetMap（ODbL）\nスキーマ：OpenMapTiles（CC BY 4.0）\n配信：OpenFreeMap · フォント：Noto Sans（OFL）',
            style: TextStyle(fontSize: 13, height: 1.8),
          ),
          ...{
            '© OpenStreetMap contributors / ODbL':
                'https://www.openstreetmap.org/copyright',
            '© OpenMapTiles': 'https://openmaptiles.org/',
            'OpenFreeMap / 利用条件': 'https://openfreemap.org/tos/',
            'フォントを含むライセンス':
                'https://github.com/hyperknot/openfreemap/blob/main/LICENSE.md',
          }.entries.map(
            (entry) => TextButton(
              onPressed: () async {
                final opened = await launchUrl(
                  Uri.parse(entry.value),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && context.mounted) {
                  showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('リンク'),
                      content: SelectableText(entry.value),
                    ),
                  );
                }
              },
              child: Text(entry.key),
            ),
          ),
        ],
      ),
    ),
  ),
);
