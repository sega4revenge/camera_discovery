import 'package:flutter_test/flutter_test.dart';

import 'package:camera_discovery/camera_discovery.dart';

void main() {
  test('package exports are available', () {
    expect(CameraDiscoveryService, isNotNull);
    expect(CameraAuthService, isNotNull);
  });

  test('scan protocol enum is exported', () {
    expect(CameraDiscoveryProtocol.multicast.displayName, 'Multicast');
    expect(CameraDiscoveryProtocol.onvif.displayName, 'ONVIF');
    expect(CameraDiscoveryProtocol.sadp.displayName, 'SADP');
  });
}
