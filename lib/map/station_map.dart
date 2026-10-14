import 'dart:math';
import 'package:flutter/material.dart';
import '../game/game.dart';
import 'real_station_map.dart';

/// Swap this builder for a MapLibre implementation without changing game logic.
typedef StationMapBuilder =
    Widget Function(Station station, int hint, bool reveal);

Widget hybridMapBuilder(Station station, int hint, bool reveal) =>
    station.hasRealMap
    ? RealStationMap(
        key: ValueKey('real-${station.id}'),
        station: station,
        hint: hint,
        reveal: reveal,
      )
    : mockMapBuilder(station, hint, reveal);

Widget mockMapBuilder(Station station, int hint, bool reveal) =>
    StationMap(station: station, hint: hint, reveal: reveal);

class StationMap extends StatelessWidget {
  const StationMap({
    super.key,
    required this.station,
    required this.hint,
    this.reveal = false,
  });
  final Station station;
  final int hint;
  final bool reveal;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(26),
    child: Stack(
      fit: StackFit.expand,
      children: [
        Semantics(
          label: '操作不可の模式地図。実際の駅周辺とは異なります。表示範囲の目安 ${Game.ranges[hint]}',
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: [1.0, 0.72, 0.43, 0.30][hint]),
            duration: const Duration(milliseconds: 480),
            curve: Curves.easeInOutCubic,
            builder: (context, scale, _) => CustomPaint(
              painter: MockMapPainter(station, scale, hint, reveal),
            ),
          ),
        ),
        const Positioned(top: 16, left: 16, child: _MapChip('模式地図 · MOCK')),
        const Positioned(top: 16, right: 16, child: _MapChip('↑ N')),
        Positioned(
          bottom: 16,
          left: 16,
          child: _MapChip('約${Game.ranges[hint]}'),
        ),
        const Positioned(bottom: 16, right: 16, child: _MapChip('実地図ではありません')),
      ],
    ),
  );
}

class _MapChip extends StatelessWidget {
  const _MapChip(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 10,
        color: Color(0xff52645f),
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// Original illustrative geometry, not OSM or a reconstruction of any station.
class MockMapPainter extends CustomPainter {
  MockMapPainter(this.station, this.scale, this.hint, this.reveal);
  final Station station;
  final double scale;
  final int hint;
  final bool reveal;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xffedf0ea), BlendMode.src);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final unit = min(size.width, size.height) / 380 * scale;
    canvas.scale(unit);
    final random = Random(station.id.codeUnits.fold<int>(71, (a, b) => a + b));
    final block = Paint()..color = const Color(0xffdce2db);
    final outline = Paint()
      ..color = const Color(0xffcbd4cb)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (int x = -900; x < 900; x += 65) {
      for (int y = -900; y < 900; y += 65) {
        if (x.abs() < 48 && y.abs() < 150) continue;
        final rect = Rect.fromLTWH(
          x + 8,
          y + 9,
          25 + random.nextDouble() * 22,
          24 + random.nextDouble() * 25,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          block,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          outline,
        );
      }
    }
    final park = Paint()..color = const Color(0xffc4d9bd);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-270 - station.id.length * 4, -270, 130, 165),
        const Radius.circular(28),
      ),
      park,
    );
    canvas.drawOval(const Rect.fromLTWH(180, 140, 160, 105), park);
    final river = Path()
      ..moveTo(-800, 310)
      ..cubicTo(-300, 100, 270, 460, 850, 140);
    canvas.drawPath(
      river,
      Paint()
        ..color = const Color(0xffb7d7df)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 38,
    );
    final roads = Paint()
      ..color = const Color(0xfffafbf7)
      ..strokeWidth = 13;
    for (int i = -13; i <= 13; i++) {
      canvas.drawLine(Offset(i * 65.0, -950), Offset(i * 65.0, 950), roads);
      canvas.drawLine(Offset(-950, i * 65.0), Offset(950, i * 65.0), roads);
    }
    final avenue = Path()
      ..moveTo(-900, -430)
      ..lineTo(900, 300);
    canvas.drawPath(
      avenue,
      Paint()
        ..color = const Color(0xffdcd4bd)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 25,
    );
    canvas.drawPath(
      avenue,
      Paint()
        ..color = const Color(0xfffff9e9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 21,
    );
    // Different illustrative track layouts; orientation stays north-up.
    final bend = (station.id.length % 5 - 2) * 38.0;
    for (int i = -2; i <= 2; i++) {
      final track = Path()
        ..moveTo(i * 9.0 + bend, -1000)
        ..cubicTo(i * 9.0 - bend, -240, i * 9.0, -130, i * 9.0, 0)
        ..cubicTo(
          i * 9.0,
          220,
          i * 9.0 + bend * 2,
          320,
          i * 9.0 + bend * 3,
          1000,
        );
      canvas.drawPath(
        track,
        Paint()
          ..color = const Color(0xff247965)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    for (int i = -1; i <= 1; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * 16.0 - 4, -78, 9, 156),
          const Radius.circular(4),
        ),
        Paint()..color = const Color(0xff91bba5),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-44, -26, 88, 52),
        const Radius.circular(6),
      ),
      Paint()..color = const Color(0xffb3beb3),
    );
    canvas.restore();
    // Labels are screen-space so hint text stays readable during zoom.
    void label(String text, Offset position, {bool accent = false}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 11,
            color: accent ? const Color(0xff177661) : const Color(0xff546b60),
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 32);
      final rect = Rect.fromLTWH(
        position.dx - painter.width / 2 - 7,
        position.dy - 4,
        painter.width + 14,
        painter.height + 8,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()..color = Colors.white.withValues(alpha: .94),
      );
      painter.paint(canvas, Offset(rect.left + 7, rect.top + 4));
    }

    if (hint >= 2) {
      label(
        station.lines,
        Offset(size.width * .5, size.height * .23),
        accent: true,
      );
    }
    if (hint >= 3 && station.landmarks.length >= 2) {
      label(station.landmarks[0], Offset(size.width * .3, size.height * .38));
      label(station.landmarks[1], Offset(size.width * .7, size.height * .68));
    }
    if (reveal) {
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        13,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        9,
        Paint()..color = const Color(0xff177661),
      );
      label(
        '${station.name}駅',
        Offset(size.width / 2, size.height / 2 + 24),
        accent: true,
      );
    }
  }

  @override
  bool shouldRepaint(MockMapPainter oldDelegate) =>
      oldDelegate.station != station ||
      oldDelegate.scale != scale ||
      oldDelegate.hint != hint ||
      oldDelegate.reveal != reveal;
}
