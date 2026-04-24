import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:easy_onvif/probe.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:network_tools/network_tools.dart';
import 'package:nsd/nsd.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_discovery_helpers.dart';
import 'discovered_camera.dart';
import 'discovery_report.dart';
import 'mac_address_resolver.dart';

class CameraDiscoveryService {
  CameraDiscoveryService({NetworkInfo? networkInfo, MacAddressResolver? macAddressResolver})
    : _networkInfo = networkInfo ?? NetworkInfo(),
      _macAddressResolver = macAddressResolver ?? const MacAddressResolver();

  final NetworkInfo _networkInfo;
  final MacAddressResolver _macAddressResolver;

  static bool _networkToolsConfigured = false;
  static bool _nsdConfigured = false;
  static const _mdnsDiscoveryWindow = Duration(seconds: 2);

  static const _mdnsServiceTypes = [
    '_psia._tcp',
    '_onvif._tcp',
    '_rtsp._tcp',
    '_http._tcp',
    '_cgi._tcp',
    '_axis-video._tcp',
    '_camera._tcp',
    '_nvr._tcp',
  ];

  Future<DiscoveryReport> discover({
    Duration onvifTimeout = const Duration(seconds: 4),
    bool enableFallbackScan = true,
    int firstHostId = 1,
    int lastHostId = 254,
    int rtspPort = 554,
    void Function(List<DiscoveredCamera> cameras, String phase)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final camerasByIp = <String, DiscoveredCamera>{};
    final ipByName = <String, String>{};
    final warnings = <String>[];
    var usedFallbackScan = false;
    void notifyProgress(String phase) =>
        onProgress == null ? null : onProgress(sortCamerasByIpOctet(camerasByIp.values), phase);

    try {
      await _configureNetworkToolsIfNeeded();

      notifyProgress('mDNS Bonjour...');
      try {
        await _discoverMdns(camerasByIp, ipByName, () => notifyProgress('mDNS Bonjour...'));
      } catch (e) {
        warnings.add('mDNS/Bonjour discovery failed: $e');
      }

      notifyProgress('ONVIF WS-Discovery...');
      try {
        if (Platform.isIOS) {
          warnings.add(
            'ONVIF WS-Discovery is temporarily disabled on iOS to avoid the Multicast Entitlement requirement.',
          );
        }

        final onvifMatches = await _discoverOnvif(onvifTimeout);
        for (final match in onvifMatches) {
          final ip = extractIpv4FromXAddrs(match.xAddrs);
          if (ip == null) continue;

          final newCam = DiscoveredCamera(
            ip: ip,
            source: CameraDiscoverySource.onvif,
            name: match.name.isEmpty ? null : match.name,
            onvifXAddr: match.xAddr,
          );

          if (_addOrMergeCamera(newCam, camerasByIp, ipByName)) {
            notifyProgress('ONVIF WS-Discovery...');
          }
        }
      } on SocketException catch (e) {
        if (isNoRouteToHostError(e)) {
          warnings.add('ONVIF multicast is unavailable on the current network (No route to host).');
        } else {
          warnings.add('ONVIF discovery failed: $e');
        }
      } catch (e) {
        warnings.add('ONVIF discovery failed: $e');
      }

      if (enableFallbackScan) {
        usedFallbackScan = true;
        notifyProgress('Subnet RTSP Port Scan...');
        try {
          await _scanSubnetForRtsp(
            camerasByIp: camerasByIp,
            ipByName: ipByName,
            firstHostId: firstHostId,
            lastHostId: lastHostId,
            rtspPort: rtspPort,
            onUpdated: () => notifyProgress('Subnet RTSP Port Scan...'),
          );
        } catch (e) {
          warnings.add('Fallback subnet scan failed: $e');
        }
      }

      notifyProgress('Resolving MAC addresses...');
      try {
        final changed = await _macAddressResolver.resolveMissingMacAddresses(
          cameras: camerasByIp.values.toList(),
          camerasByIp: camerasByIp,
        );
        if (changed) notifyProgress('Resolving MAC addresses...');
      } catch (e) {
        warnings.add('Unable to resolve all MAC addresses: $e');
      }
    } catch (e) {
      warnings.add('Discovery failed: $e');
    }

    notifyProgress('Completed');

    return DiscoveryReport(
      cameras: sortCamerasByIpOctet(camerasByIp.values),
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      usedFallbackScan: usedFallbackScan,
      error: warnings.isEmpty ? null : warnings.join('\n'),
    );
  }

  bool _addOrMergeCamera(
    DiscoveredCamera newCam,
    Map<String, DiscoveredCamera> camerasByIp,
    Map<String, String> ipByName,
  ) {
    final name = newCam.name;
    final newIp = newCam.ip;
    final isNewIpv6 = newIp.contains(':');

    if (name != null && name.isNotEmpty) {
      final existingIp = ipByName[name];
      if (existingIp != null) {
        final existingCam = camerasByIp[existingIp]!;
        final isExistingIpv6 = existingIp.contains(':');

        if (isExistingIpv6 && !isNewIpv6) {
          camerasByIp.remove(existingIp);
          camerasByIp[newIp] = newCam.copyWith(
            onvifXAddr: newCam.onvifXAddr ?? existingCam.onvifXAddr,
            macAddress: newCam.macAddress ?? existingCam.macAddress,
          );
          ipByName[name] = newIp;
          return true;
        } else if (!isExistingIpv6 && isNewIpv6) {
          return false;
        } else {
          camerasByIp[existingIp] = existingCam.copyWith(
            onvifXAddr: existingCam.onvifXAddr ?? newCam.onvifXAddr,
            rtspUri: existingCam.rtspUri ?? newCam.rtspUri,
            macAddress: existingCam.macAddress ?? newCam.macAddress,
          );
          return true;
        }
      } else {
        ipByName[name] = newIp;
        camerasByIp[newIp] = newCam;
        return true;
      }
    }

    final existingCam = camerasByIp[newIp];
    if (existingCam != null) {
      camerasByIp[newIp] = existingCam.copyWith(
        name: existingCam.name ?? newCam.name,
        onvifXAddr: existingCam.onvifXAddr ?? newCam.onvifXAddr,
        rtspUri: existingCam.rtspUri ?? newCam.rtspUri,
        macAddress: existingCam.macAddress ?? newCam.macAddress,
      );
      return true;
    }

    camerasByIp[newIp] = newCam;
    return true;
  }

  Future<void> _configureNetworkToolsIfNeeded() async {
    if (_networkToolsConfigured) {
      return;
    }

    final supportDirectory = await getApplicationSupportDirectory();
    await configureNetworkTools(supportDirectory.path, enableDebugging: false);
    _networkToolsConfigured = true;
  }

  void _configureNsdIfNeeded() {
    if (_nsdConfigured) {
      return;
    }

    disableServiceTypeValidation(true);
    _nsdConfigured = true;
  }

  Future<List<ProbeMatch>> _discoverOnvif(Duration timeout) async {
    if (Platform.isIOS) {
      // iOS blocks raw UDP multicast without dedicated entitlement.
      return const <ProbeMatch>[];
    }

    final probe = MulticastProbe(timeout: timeout.inSeconds);
    await probe.probe();
    return probe.onvifDevices;
  }

  Future<void> _discoverMdns(
    Map<String, DiscoveredCamera> camerasByIp,
    Map<String, String> ipByName,
    VoidCallback onUpdated,
  ) async {
    _configureNsdIfNeeded();

    final changed = await Future.wait(
      _mdnsServiceTypes.map(
        (serviceType) =>
            _discoverMdnsForServiceType(serviceType: serviceType, camerasByIp: camerasByIp, ipByName: ipByName),
      ),
    );

    if (changed.any((value) => value)) {
      onUpdated();
    }
  }

  Future<bool> _discoverMdnsForServiceType({
    required String serviceType,
    required Map<String, DiscoveredCamera> camerasByIp,
    required Map<String, String> ipByName,
  }) async {
    Discovery? discovery;
    var changed = false;

    try {
      discovery = await startDiscovery(serviceType, ipLookupType: IpLookupType.v4);

      discovery.addServiceListener((service, status) async {
        if (status != ServiceStatus.found) {
          return;
        }

        try {
          final resolved = await resolve(service);
          final ip = extractIpv4FromNsdService(resolved);
          if (ip == null || ip == '0.0.0.0') {
            return;
          }

          final port = resolved.port ?? 554;
          final name = resolved.name;
          final newCam = DiscoveredCamera(
            ip: ip,
            source: CameraDiscoverySource.mdns,
            name: name?.isNotEmpty == true ? name : null,
            rtspUri: 'rtsp://$ip:$port',
          );

          if (_addOrMergeCamera(newCam, camerasByIp, ipByName)) {
            changed = true;
          }
        } catch (_) {}
      });

      await Future<void>.delayed(_mdnsDiscoveryWindow);
    } catch (_) {
    } finally {
      if (discovery != null) {
        try {
          await stopDiscovery(discovery);
        } catch (_) {}
      }
    }

    return changed;
  }

  Future<void> _scanSubnetForRtsp({
    required Map<String, DiscoveredCamera> camerasByIp,
    required Map<String, String> ipByName,
    required int firstHostId,
    required int lastHostId,
    required int rtspPort,
    required VoidCallback onUpdated,
  }) async {
    final wifiIp = await _networkInfo.getWifiIP();
    if (wifiIp == null || !wifiIp.contains('.')) {
      return;
    }

    final subnet = wifiIp.substring(0, wifiIp.lastIndexOf('.'));
    final seen = <String>{};
    final stream = HostScannerService.instance.getAllPingableDevices(
      subnet,
      firstHostId: firstHostId,
      lastHostId: lastHostId,
    );

    await for (final host in stream) {
      if (!seen.add(host.address)) continue;

      final known = camerasByIp[host.address];
      final hasRtsp = await _isPortOpen(host.address, rtspPort);

      if (!hasRtsp && known == null) continue;

      final newCam = DiscoveredCamera(
        ip: host.address,
        source: CameraDiscoverySource.rtspPortScan,
        rtspUri: 'rtsp://${host.address}:$rtspPort',
      );

      if (_addOrMergeCamera(newCam, camerasByIp, ipByName)) {
        onUpdated();
      }
    }
  }

  Future<bool> _isPortOpen(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 300));
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }
}
