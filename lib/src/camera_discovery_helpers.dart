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
