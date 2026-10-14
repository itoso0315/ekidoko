import 'dart:io';
import 'dart:convert';
import 'package:ekidoko/data/station_catalog.dart';

final catalog = StationCatalog.parse(
  File('assets/data/stations.json').readAsStringSync(),
);
final stations = catalog.stations;
// Keep the original regional examples as regression fixtures as the app grows.
final phase2Catalog = StationCatalog.parse(
  jsonEncode(
    (jsonDecode(File('test/fixtures/stations_phase2.json').readAsStringSync())
            as List)
        .map((row) => {...row as Map, 'easyEligible': true})
        .toList(),
  ),
);
