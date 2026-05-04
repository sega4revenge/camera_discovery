enum CameraProtocol {
  onvif,
  dahua,
  hikvision,
  ezviz,
  generic,
}

extension CameraProtocolExtension on CameraProtocol {
  String get displayName {
    switch (this) {
      case CameraProtocol.onvif:
        return 'ONVIF';
      case CameraProtocol.dahua:
        return 'Dahua';
      case CameraProtocol.hikvision:
        return 'Hikvision';
      case CameraProtocol.ezviz:
        return 'EZVIZ';
      case CameraProtocol.generic:
        return 'Generic RTSP';
    }
  }
}

enum CameraBrand {
  ezviz,
  hikvision,
  dahua,
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
