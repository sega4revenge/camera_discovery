import 'package:network_tools/network_tools.dart';

import 'discovered_camera.dart';

class MacAddressResolver {
  const MacAddressResolver();

  Future<bool> resolveMissingMacAddresses({
    required List<DiscoveredCamera> cameras,
    required Map<String, DiscoveredCamera> camerasByIp,
  }) async {
    var changed = false;

    for (final camera in cameras) {
      if (camera.macAddress != null && camera.macAddress!.isNotEmpty) {
        continue;
      }

      try {
        final host = ActiveHost.buildWithAddress(address: camera.ip);

        final arpMac = (await host.setARPData())?.macAddress;
        if (arpMac != null && arpMac.isNotEmpty) {
          camerasByIp[camera.ip] = camera.copyWith(macAddress: arpMac);
          changed = true;
          continue;
        }

        final mac = await host.getMacAddress();
        if (mac != null && mac.isNotEmpty) {
          camerasByIp[camera.ip] = camera.copyWith(macAddress: mac);
          changed = true;
        }
      } catch (_) {}
    }

    return changed;
  }
}
