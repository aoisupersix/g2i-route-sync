/// Shared data models for routes and roadbooks.
library;

class RouteSummary {
  final String routeId;
  final String name;
  final Map<String, dynamic> raw;

  RouteSummary({required this.routeId, required this.name, required this.raw});
}

class RoadBookSummary {
  final int roadbookId;
  final String title;

  RoadBookSummary({required this.roadbookId, required this.title});
}
