import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      final raw = data?['mapHints50Quality'];
      if (raw is! Map) return;
      final quality = Map<String, dynamic>.from(raw);
      final screenshotRoot = quality.remove('screenshotRoot') as String?;
      final imageErrors = <String>[];
      final captureEnabled = quality['captureEnabled'] == true;
      if (!captureEnabled) {
        // A no-capture smoke run still reports all native feature checks.
      } else if (screenshotRoot == null ||
          !Directory(screenshotRoot).existsSync()) {
        imageErrors.add('Simulator screenshot directory was not available');
      } else {
        for (final record in (quality['records'] as List? ?? const [])) {
          final row = Map<String, dynamic>.from(record as Map);
          final stationId = row['stationId'] as String;
          final stage = row['stage'] as String;
          final source = File('$screenshotRoot/$stationId/$stage.png');
          final destination = File(
            'docs/screenshots/phase4/map-hints-50stations/'
            '$stationId/$stage.jpg',
          );
          if (!source.existsSync()) {
            imageErrors.add('$stationId/$stage.png was not captured');
            continue;
          }
          await destination.parent.create(recursive: true);
          final conversion = await Process.run('/usr/bin/sips', [
            '-s',
            'format',
            'jpeg',
            '-s',
            'formatOptions',
            '85',
            source.path,
            '-o',
            destination.path,
          ]);
          if (conversion.exitCode != 0) {
            imageErrors.add('$stationId/$stage: ${conversion.stderr}');
          }
        }
      }
      quality['screenshotCopyErrors'] = imageErrors;
      quality['environment'] =
          Platform.environment['EKIDOKO_POC_PLATFORM'] ??
          'iPhone 17 Pro / iOS 26.5 simulator, debug';
      quality['generatedAt'] = DateTime.now().toUtc().toIso8601String();
      final file = File('docs/map-hints-50stations/native-quality.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(quality)}\n',
      );
    },
  );
}
