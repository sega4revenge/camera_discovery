enum LocalNetworkPermissionStatus {
  granted,
  denied,
  notRequired,
  unsupportedPlatform,
  unknown,
}

class LocalNetworkPermissionResult {
  const LocalNetworkPermissionResult({required this.status, this.message});

  final LocalNetworkPermissionStatus status;
  final String? message;

  bool get canScan =>
      status == LocalNetworkPermissionStatus.granted ||
      status == LocalNetworkPermissionStatus.notRequired ||
      status == LocalNetworkPermissionStatus.unsupportedPlatform ||
      status == LocalNetworkPermissionStatus.unknown;
}
