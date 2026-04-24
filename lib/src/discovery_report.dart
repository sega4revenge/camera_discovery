import 'discovered_camera.dart';

class DiscoveryReport {
  const DiscoveryReport({
    required this.cameras,
    required this.startedAt,
    required this.finishedAt,
    required this.usedFallbackScan,
    this.error,
  });

  final List<DiscoveredCamera> cameras;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool usedFallbackScan;
  final String? error;

  Duration get duration => finishedAt.difference(startedAt);
}
