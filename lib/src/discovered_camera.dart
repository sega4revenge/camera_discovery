enum CameraDiscoverySource { onvif, mdns, rtspPortScan }

class DiscoveredCamera {
  const DiscoveredCamera({
    required this.ip,
    required this.source,
    this.name,
    this.macAddress,
    this.onvifXAddr,
    this.rtspUri,
  });

  final String ip;
  final String? name;
  final String? macAddress;
  final CameraDiscoverySource source;
  final String? onvifXAddr;
  final String? rtspUri;

  DiscoveredCamera copyWith({
    String? ip,
    String? name,
    String? macAddress,
    CameraDiscoverySource? source,
    String? onvifXAddr,
    String? rtspUri,
  }) {
    return DiscoveredCamera(
      ip: ip ?? this.ip,
      name: name ?? this.name,
      macAddress: macAddress ?? this.macAddress,
      source: source ?? this.source,
      onvifXAddr: onvifXAddr ?? this.onvifXAddr,
      rtspUri: rtspUri ?? this.rtspUri,
    );
  }
}
