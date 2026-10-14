import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [args]) async {
      final file = File('docs/screenshots/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      return true;
    },
    responseDataCallback: (data) async {
      if (data?['phase2Quality'] != null) {
        final file = File('docs/map-quality-phase2.json');
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'environment': 'iPhone 17 Pro / iOS 26.5 simulator, debug build', 'records': data!['phase2Quality']})}\n',
        );
      }
      if (data?['phase3Quality'] != null) {
        final quality = data!['phase3Quality'] as Map<String, dynamic>;
        final captureRoot = quality['screenshotRoot'] as String?;
        final imageErrors = <String>[];
        if (captureRoot != null && Directory(captureRoot).existsSync()) {
          for (final entry
              in Directory(captureRoot)
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.png'))) {
            final relative = entry.path.substring(captureRoot.length + 1);
            final destination = File(
              'docs/screenshots/${relative.replaceFirst(RegExp(r'\.png$'), '.jpg')}',
            );
            await destination.parent.create(recursive: true);
            // JPEG at native resolution keeps the attribution and limits repo
            // growth. PNGs remain transient inside the simulator container.
            final result = await Process.run('/usr/bin/sips', [
              '-s',
              'format',
              'jpeg',
              '-s',
              'formatOptions',
              '85',
              entry.path,
              '-o',
              destination.path,
            ]);
            if (result.exitCode == 0) {
              await entry.delete();
            } else {
              imageErrors.add('$relative: ${result.stderr}');
            }
          }
        } else if (captureRoot != null) {
          imageErrors.add(
            'Screenshot container is not readable from this host: $captureRoot',
          );
        }
        quality['screenshotCopyErrors'] = imageErrors;
        final platform =
            Platform.environment['EKIDOKO_QUALITY_PLATFORM'] ??
            'iPhone 17 Pro / iOS 26.5 simulator, debug';
        final directory =
            Platform.environment['EKIDOKO_QUALITY_REPORT_DIR'] ??
            'docs/map-quality-phase3';
        final file = File('$directory/batch-${quality['batch']}.json');
        await file.parent.create(recursive: true);
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({'environment': platform, ...quality})}\n',
        );
      }
    },
  );
}
