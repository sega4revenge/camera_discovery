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

  group('DiscoveredCamera serialNumber model-stripping', () {
    test('strips exact model from the beginning of serialNumber', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        serialNumber: 'CS-C3TN-A0-1H3WKFL-B0120220527CCRRK02854364',
      );
      expect(camera.serialNumber, '0120220527CCRRK02854364');
    });

    test('strips model with case-insensitivity', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'cs-c3tn-a0-1h3wkfl-b',
        serialNumber: 'CS-C3TN-A0-1H3WKFL-B0120220527CCRRK02854364',
      );
      expect(camera.serialNumber, '0120220527CCRRK02854364');
    });

    test('strips model when it is formatted without hyphens in serialNumber', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        // Serial number does not contain hyphens for the model prefix
        serialNumber: 'CSC3TNA01H3WKFLB0120220527CCRRK02854364',
      );
      expect(camera.serialNumber, '0120220527CCRRK02854364');
    });

    test('does not strip if model is too short or is unknown model', () {
      final camera1 = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'CS',
        serialNumber: 'CS0120220527CCRRK02854364',
      );
      expect(camera1.serialNumber, 'CS0120220527CCRRK02854364');

      final camera2 = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'Unknown Model',
        serialNumber: 'Unknown Model0120220527CCRRK02854364',
      );
      expect(camera2.serialNumber, 'Unknown Model0120220527CCRRK02854364');
    });

    test('does not strip if serialNumber does not start with model', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        serialNumber: '0120220527CCRRK02854364',
      );
      expect(camera.serialNumber, '0120220527CCRRK02854364');
    });
  });

  group('DiscoveredCamera computed display name', () {
    test('formats name as "Brand Model - SerialNumber" when all are present', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        brand: CameraBrand.ezviz,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        serialNumber: 'CS-C3TN-A0-1H3WKFL-B0120220527CCRRK02854364', // Note: Model will be stripped from serial first
      );
      expect(camera.name, 'EZVIZ CS-C3TN-A0-1H3WKFL-B - 0120220527CCRRK02854364');
    });

    test('falls back to "Model - SerialNumber" if brand is unknown', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        brand: CameraBrand.unknown,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        serialNumber: '0120220527CCRRK02854364',
      );
      expect(camera.name, 'CS-C3TN-A0-1H3WKFL-B - 0120220527CCRRK02854364');
    });

    test('falls back to "Brand - SerialNumber" if model is missing or unknown', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        brand: CameraBrand.ezviz,
        model: 'Unknown Model',
        serialNumber: '0120220527CCRRK02854364',
      );
      expect(camera.name, 'EZVIZ - 0120220527CCRRK02854364');
    });

    test('falls back to "Brand Model" if serialNumber is missing', () {
      final camera = DiscoveredCamera(
        ip: '192.168.1.100',
        source: CameraDiscoverySource.sadp,
        brand: CameraBrand.ezviz,
        model: 'CS-C3TN-A0-1H3WKFL-B',
        serialNumber: null,
      );
      expect(camera.name, 'EZVIZ CS-C3TN-A0-1H3WKFL-B');
    });
  });
}
