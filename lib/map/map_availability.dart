import 'package:flutter/material.dart';

/// UI readiness only, independent of game rules. A request number prevents an
/// outgoing AnimatedSwitcher map from enabling the next question's controls.
class MapAvailability extends ValueNotifier<bool> {
  MapAvailability(super.value);
  int request = 0;
  void begin(bool ready) {
    request++;
    value = ready;
  }

  void report(int request, bool ready) {
    if (this.request == request) value = ready;
  }
}

/// Preserves the original three-argument StationMapBuilder contract.
class MapAvailabilityScope extends InheritedNotifier<MapAvailability> {
  MapAvailabilityScope({
    super.key,
    required MapAvailability availability,
    required super.child,
  }) : request = availability.request,
       super(notifier: availability);
  final int request;
  @override
  bool updateShouldNotify(MapAvailabilityScope oldWidget) =>
      request != oldWidget.request || super.updateShouldNotify(oldWidget);
  static MapAvailabilityScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MapAvailabilityScope>();
}
