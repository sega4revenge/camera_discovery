import 'camera_protocol.dart';

enum CameraDiscoverySource { onvif, mdns, rtspPortScan, sadp }

class DiscoveredCamera {
  DiscoveredCamera({
    required this.ip,
    required this.source,
    this.brand = CameraBrand.unknown,
    this.model,
    String? serialNumber,
    this.macAddress,
    this.onvifXAddr,
    this.rtspUri,
    this.supportedProtocols = const {},
  }) : serialNumber = _cleanSerialNumber(serialNumber, model);

  final String ip;
  final CameraBrand brand;
  final String? model;
  final String? serialNumber;
  final String? macAddress;
  final CameraDiscoverySource source;
  final String? onvifXAddr;
  final String? rtspUri;
  final Set<CameraProtocol> supportedProtocols;

  static String? _cleanSerialNumber(String? serial, String? model) {
    if (serial == null || serial.isEmpty) return serial;
    if (model == null || model.isEmpty) return serial;

    final trimmedModel = model.trim();
    if (trimmedModel.toLowerCase() == 'unknown model' || trimmedModel.length < 3) {
      return serial;
    }

    final lowerSerial = serial.toLowerCase();
    final lowerModel = trimmedModel.toLowerCase();

    if (lowerSerial.startsWith(lowerModel)) {
      return serial.substring(trimmedModel.length);
    }

    final cleanModel = lowerModel.replaceAll('-', '');
    if (lowerSerial.startsWith(cleanModel)) {
      return serial.substring(cleanModel.length);
    }

    return serial;
  }

  /// Computed display name formatted as "Brand Model - SerialNumber".
  /// Falls back to "Brand Model", "Model - SerialNumber", "Brand - SerialNumber", or individual parts when some are missing.
  String? get name {
    final brandName = brand == CameraBrand.unknown ? null : brand.displayName;
    final m = model;
    final s = serialNumber;

    final parts = <String>[];
    if (brandName != null && brandName.isNotEmpty) {
      parts.add(brandName);
    }
    if (m != null && m.isNotEmpty && m.toLowerCase() != 'unknown model') {
      parts.add(m);
    }

    final prefix = parts.join(' ');

    if (prefix.isNotEmpty && s != null && s.isNotEmpty) {
      return '$prefix - $s';
    } else if (prefix.isNotEmpty) {
      return prefix;
    } else if (s != null && s.isNotEmpty) {
      return s;
    }

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
