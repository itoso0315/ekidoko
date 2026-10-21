import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/station_catalog.dart';
import 'map_hints_poc.dart';

class HomeMapPreview extends StatefulWidget {
  const HomeMapPreview({super.key, required this.station});

  final Station station;

  @override
  State<HomeMapPreview> createState() => _HomeMapPreviewState();
}

class _HomeMapPreviewState extends State<HomeMapPreview> {
  late Future<MapHintsPoc> _hints = loadMapHintsPoc(widget.station);

  @override
  void didUpdateWidget(covariant HomeMapPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.station != widget.station) {
      _hints = loadMapHintsPoc(widget.station);
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(26),
    child: Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<MapHintsPoc>(
          future: _hints,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('地図プレビューを表示できません'));
            }
            return CustomPaint(
              painter: _HomeMapPainter(widget.station, snapshot.data),
            );
          },
        ),
        const Positioned(
          top: 16,
          left: 16,
          child: _PreviewChip('東京駅周辺 · 線路プレビュー'),
        ),
        const Positioned(top: 16, right: 16, child: _PreviewChip('↑ N')),
        const Positioned(bottom: 16, left: 16, child: _PreviewChip('約500 m')),
        const Positioned(
          bottom: 16,
          right: 16,
          child: _PreviewChip('© OpenStreetMap contributors'),
        ),
      ],
    ),
  );
}

class _PreviewChip extends StatelessWidget {
  const _PreviewChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xff52645f),
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

class _HomeMapPainter extends CustomPainter {
  const _HomeMapPainter(this.station, this.hints);

  final Station station;
  final MapHintsPoc? hints;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xffedf1ed), BlendMode.src);
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final longitudeScale = math.cos(station.latitude * math.pi / 180) * 111320;
    Offset project(List<dynamic> coordinates) {
      final longitude = (coordinates[0] as num).toDouble();
      final latitude = (coordinates[1] as num).toDouble();
      return Offset(
        size.width / 2 +
            (longitude - station.longitude) * longitudeScale * size.width / 900,
        size.height / 2 +
            (station.latitude - latitude) * 111320 * size.height / 900,
      );
    }

    void drawLines(Map<String, dynamic> collection, Color color, double width) {
      final features = collection['features'] as List<dynamic>;
      for (final feature in features) {
        final geometry = feature['geometry'] as Map;
        final coordinates = geometry['coordinates'] as List<dynamic>;
        final path = Path();
        for (var index = 0; index < coordinates.length; index++) {
          final point = project(coordinates[index] as List<dynamic>);
          if (index == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }

    if (hints != null) {
      final routes = hints!.routes['features'] as List<dynamic>;
      for (final feature in routes) {
        final properties = feature['properties'] as Map;
        final colorValue = properties['color'] as String;
        final color = Color(
          int.parse('ff${colorValue.substring(1)}', radix: 16),
        );
        drawLines(
          {
            'features': [feature],
          },
          Colors.white.withValues(alpha: .9),
          5,
        );
        drawLines(
          {
            'features': [feature],
          },
          color,
          2.6,
        );
      }
      drawLines(hints!.highSpeedRailways, Colors.white, 7);
      drawLines(hints!.highSpeedRailways, const Color(0xff8e6bb2), 4);

      final facilities = hints!.facilities['features'] as List<dynamic>;
      for (final feature in facilities) {
        final geometry = feature['geometry'] as Map;
        final center = project(geometry['coordinates'] as List<dynamic>);
        canvas.drawCircle(center, 8, Paint()..color = const Color(0xfff5f8fa));
        canvas.drawCircle(
          center,
          8,
          Paint()
            ..color = const Color(0xff8b9eaa)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    canvas.drawCircle(
      size.center(Offset.zero),
      5,
      Paint()..color = const Color(0xff177965),
    );
    canvas.drawCircle(
      size.center(Offset.zero),
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HomeMapPainter oldDelegate) =>
      oldDelegate.station != station || oldDelegate.hints != hints;
}
