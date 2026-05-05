import 'camera_protocol.dart';

enum CameraDiscoverySource { onvif, mdns, rtspPortScan, sadp }

class DiscoveredCamera {
  const DiscoveredCamera({
    required this.ip,
    required this.source,
    this.brand = CameraBrand.unknown,
    this.name,
    this.model,
    this.serialNumber,
    this.macAddress,
    this.onvifXAddr,
    this.rtspUri,
    this.supportedProtocols = const {},
  });

  final String ip;
  final CameraBrand brand;
  final String? name;
  final String? model;
  final String? serialNumber;
  final String? macAddress;
  final CameraDiscoverySource source;
  final String? onvifXAddr;
  final String? rtspUri;
  final Set<CameraProtocol> supportedProtocols;

  DiscoveredCamera copyWith({
    String? ip,
    CameraBrand? brand,
    String? name,
    String? model,
    String? serialNumber,
    String? macAddress,
    CameraDiscoverySource? source,
    String? onvifXAddr,
    String? rtspUri,
    Set<CameraProtocol>? supportedProtocols,
  }) {
    return DiscoveredCamera(
      ip: ip ?? this.ip,
      brand: brand ?? this.brand,
      name: name ?? this.name,
      model: model ?? this.model,
      serialNumber: serialNumber ?? this.serialNumber,
      macAddress: macAddress ?? this.macAddress,
      source: source ?? this.source,
      onvifXAddr: onvifXAddr ?? this.onvifXAddr,
      rtspUri: rtspUri ?? this.rtspUri,
      supportedProtocols: supportedProtocols ?? this.supportedProtocols,
    );
  }
}
