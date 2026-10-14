import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

// Material's vector glyphs rasterized for MapLibre's image API. No labels,
// emoji, remote sprites, callbacks, or feature-name text are used.
const _icons = {
  'education': Icons.school_outlined,
  'hospital': Icons.local_hospital_outlined,
  'religion': Icons.temple_buddhist_outlined,
  'culture': Icons.museum_outlined,
  'shopping': Icons.shopping_bag_outlined,
  'stadium': Icons.stadium_outlined,
};
Future<Map<String, Uint8List>>? _images;

Future<Map<String, Uint8List>> facilityIconImages() async {
  try {
    return await (_images ??= _renderIcons());
  } catch (_) {
    // A retry must render again instead of reusing a failed Future.
    _images = null;
    rethrow;
  }
}

Future<Map<String, Uint8List>> _renderIcons() async {
  final images = <String, Uint8List>{};
  for (final entry in _icons.entries) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawCircle(
      const Offset(24, 24),
      22,
      Paint()..color = const Color(0xf2f5f8fa),
    );
    canvas.drawCircle(
      const Offset(24, 24),
      22,
      Paint()
        ..color = const Color(0xffc6d2d9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final icon = entry.value;
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontSize: 30,
          color: const Color(0xff6c8190),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset((48 - painter.width) / 2, (48 - painter.height) / 2),
    );
    final picture = recorder.endRecording();
    final bitmap = await picture.toImage(48, 48);
    final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Facility icon encoding failed');
    images['facility-${entry.key}'] = bytes.buffer.asUint8List();
    painter.dispose();
    bitmap.dispose();
    picture.dispose();
  }
  return images;
}
