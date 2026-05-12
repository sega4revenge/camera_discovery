import 'discovered_camera.dart';

enum DiscoveryIssue { none, localNetworkUnavailable, unknown }

class DiscoveryReport {
  const DiscoveryReport({
    required this.cameras,
    required this.startedAt,
    required this.finishedAt,
    required this.usedFallbackScan,
    this.issue = DiscoveryIssue.none,
    this.error,
  });

  final List<DiscoveredCamera> cameras;
  final DateTime startedAt;
  final DateTime finishedAt;
  final bool usedFallbackScan;
  final DiscoveryIssue issue;
  final String? error;

  Duration get duration => finishedAt.difference(startedAt);

  bool get hasLocalNetworkIssue => issue == DiscoveryIssue.localNetworkUnavailable;
}
