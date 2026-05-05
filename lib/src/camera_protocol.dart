enum CameraProtocol {
  onvif,
  generic,
}

enum CameraDiscoveryProtocol {
  multicast,
  onvif,
  sadp,
}

extension CameraDiscoveryProtocolExtension on CameraDiscoveryProtocol {
  String get displayName {
    switch (this) {
      case CameraDiscoveryProtocol.multicast:
        return 'Multicast';
      case CameraDiscoveryProtocol.onvif:
        return 'ONVIF';
      case CameraDiscoveryProtocol.sadp:
        return 'SADP';
    }
  }
}

extension CameraProtocolExtension on CameraProtocol {
  String get displayName {
    switch (this) {
      case CameraProtocol.onvif:
        return 'ONVIF';
      case CameraProtocol.generic:
        return 'Generic RTSP';
    }
  }
}

CameraBrand detectCameraBrand(Iterable<String?> values) {
  final merged = values.whereType<String>().join(' ').toLowerCase();

  if (merged.contains('dahua') || merged.contains('general dvr') || merged.contains('general nvr') || merged.contains('general_')) {
    return CameraBrand.dahua;
  }

  if (merged.contains('hikvision') || merged.startsWith('ds-')) {
    return CameraBrand.hikvision;
  }

  if (merged.contains('ezviz') || merged.startsWith('cs-')) {
    return CameraBrand.ezviz;
  }

  return CameraBrand.unknown;
}

enum CameraBrand {
  dahua,
  hikvision,
  ezviz,
  unknown,
}

extension CameraBrandExtension on CameraBrand {
  String get displayName {
    switch (this) {
      case CameraBrand.ezviz:
        return 'EZVIZ';
      case CameraBrand.hikvision:
        return 'Hikvision';
      case CameraBrand.dahua:
        return 'Dahua';
      case CameraBrand.unknown:
        return 'Unknown Brand';
    }
  }
}
