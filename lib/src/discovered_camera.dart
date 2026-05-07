import 'camera_protocol.dart';

enum CameraDiscoverySource { onvif, mdns, rtspPortScan, sadp }

class DiscoveredCamera {
  const DiscoveredCamera({
    required this.ip,
    required this.source,
    this.brand = CameraBrand.unknown,
    this.model,
    this.serialNumber,
    this.macAddress,
    this.onvifXAddr,
    this.rtspUri,
    this.supportedProtocols = const {},
  });

  final String ip;
  final CameraBrand brand;
  final String? model;
  final String? serialNumber;
  final String? macAddress;
  final CameraDiscoverySource source;
  final String? onvifXAddr;
  final String? rtspUri;
  final Set<CameraProtocol> supportedProtocols;

  /// Computed display name derived from `brand` and `serialNumber`.
  /// Falls back to `model` when brand/serial are not available.
  String? get name {
    final brandName = brand == CameraBrand.unknown ? null : brand.displayName;
    final s = serialNumber;
    if (brandName != null && s != null && s.isNotEmpty) {
      return '$brandName $s';
    }
    if (brandName != null) return brandName;
    if (model != null && model!.isNotEmpty) return model;
    return null;
  }

  DiscoveredCamera copyWith({
    String? ip,
    CameraBrand? brand,
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
