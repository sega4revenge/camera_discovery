enum CameraProtocol {
  onvif,
  dahua,
  hikvision,
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
      case CameraProtocol.generic:
        return 'Generic RTSP';
    }
  }
}
