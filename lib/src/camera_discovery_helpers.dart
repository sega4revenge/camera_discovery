import 'dart:io';

import 'package:nsd/nsd.dart';

import 'discovered_camera.dart';

List<DiscoveredCamera> sortCamerasByIpOctet(Iterable<DiscoveredCamera> cameras) {
  final sorted = cameras.toList();
  sorted.sort((a, b) => lastIpv4Octet(a.ip).compareTo(lastIpv4Octet(b.ip)));
  return sorted;
}

int lastIpv4Octet(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) {
    return 0;
  }
  return int.tryParse(parts.last) ?? 0;
}

String? extractIpv4FromXAddrs(List<String> xAddrs) {
  for (final xAddr in xAddrs) {
    final host = Uri.tryParse(xAddr)?.host;
    if (host == null || host.isEmpty) {
      continue;
    }

    final parsed = InternetAddress.tryParse(host);
    if (parsed?.type == InternetAddressType.IPv4) {
      return host;
    }
  }
  return null;
}

String? extractIpv4FromNsdService(Service service) {
  final addresses = service.addresses;
  if (addresses != null) {
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv4) {
        return address.address;
      }
    }
  }

  final host = service.host;
  if (host == null || host.isEmpty) {
    return null;
  }

  final parsed = InternetAddress.tryParse(host);
  if (parsed?.type == InternetAddressType.IPv4) {
    return parsed!.address;
  }

  return null;
}

bool isNoRouteToHostError(SocketException error) {
  if (error.osError?.errorCode == 65) {
    return true;
  }

  return error.message.toLowerCase().contains('no route to host');
}

/// Parses a device name (typically from mDNS) to extract brand, model, and serial number.
/// Expected format: "[BRAND] [MODEL] - [SERIAL]" or "[BRAND] [MODEL]"
/// Returns a map with keys 'brand', 'model', and 'serialNumber'.
/// Example: "HIKVISION DS-2CD1343G0-IUF - L18623820"
///   → {'brand': 'HIKVISION', 'model': 'DS-2CD1343G0-IUF', 'serialNumber': 'L18623820'}
Map<String, String?> parseDeviceNameForBrandAndSerial(String? name) {
  if (name == null || name.trim().isEmpty) {
    return {'brand': null, 'model': null, 'serialNumber': null};
  }

  final trimmed = name.trim();

  // Match pattern: [BRAND] [MODEL] - [SERIAL]
  final matchWithSerial = RegExp(r'^(\S+)\s+(.+?)\s*-\s*([A-Z0-9]+)$', caseSensitive: false).firstMatch(trimmed);

  if (matchWithSerial != null) {
    final brand = matchWithSerial.group(1)?.trim();
    final model = matchWithSerial.group(2)?.trim();
    final serial = matchWithSerial.group(3)?.trim();
    return {'brand': brand, 'model': model, 'serialNumber': serial};
  }

  // No dash found, try to extract brand as first word
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length > 1) {
    final brand = parts.first;
    final model = parts.sublist(1).join(' ');
    return {'brand': brand, 'model': model, 'serialNumber': null};
  }

  // Single word, treat as model only
  return {'brand': null, 'model': trimmed, 'serialNumber': null};
}
