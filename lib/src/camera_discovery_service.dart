import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'package:easy_onvif/probe.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:network_tools/network_tools.dart';
import 'package:nsd/nsd.dart';
import 'package:path_provider/path_provider.dart';

import 'camera_discovery_helpers.dart';
import 'camera_protocol.dart';
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
  static Completer<void>? _networkToolsInitializationCompleter;
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
    '_hap._tcp', // HomeKit (rất nhiều camera Eufy dùng chuẩn này)
    '_eufy._tcp', // Dự phòng cho các thiết bị Eufy
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
      try {
        await _configureNetworkToolsIfNeeded();
      } catch (e) {
        // Rethrow initialization error as it's critical
        rethrow;
      }

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

          final supportedProtocols = <CameraProtocol>{CameraProtocol.onvif};
          final hw = match.hardware.toLowerCase();
          final nameStr = match.name.toLowerCase();
          final scopesStr = match.scopes.toString().toLowerCase();
          final endpoint = match.endpointReference.address.toLowerCase();
          
          final fullStr = '$hw | $nameStr | $scopesStr | $endpoint';
          debugPrint('ONVIF Match metadata for $ip: $fullStr');

          if (fullStr.contains('dahua') || 
              fullStr.contains('general dvr') || 
              fullStr.contains('general nvr') ||
              fullStr.contains('general_') ||
              (hw == 'general' || nameStr == 'general')) {
            supportedProtocols.add(CameraProtocol.dahua);
          }
          
          if (fullStr.contains('hikvision')) {
            supportedProtocols.add(CameraProtocol.hikvision);
          }

          final newCam = DiscoveredCamera(
            ip: ip,
            source: CameraDiscoverySource.onvif,
            name: match.name.isEmpty ? null : match.name,
            onvifXAddr: match.xAddr,
            supportedProtocols: supportedProtocols,
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

      notifyProgress('Detecting supported protocols...');
      try {
        final changed = await _detectProtocols(camerasByIp);
        if (changed) notifyProgress('Detecting supported protocols...');
      } catch (e) {
        warnings.add('Protocol detection failed: $e');
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
            supportedProtocols: existingCam.supportedProtocols.union(newCam.supportedProtocols),
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
            supportedProtocols: existingCam.supportedProtocols.union(newCam.supportedProtocols),
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
        supportedProtocols: existingCam.supportedProtocols.union(newCam.supportedProtocols),
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

    if (_networkToolsInitializationCompleter != null) {
      return _networkToolsInitializationCompleter!.future;
    }

    _networkToolsInitializationCompleter = Completer<void>();
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      await configureNetworkTools(supportDirectory.path, enableDebugging: false);
      _networkToolsConfigured = true;
      _networkToolsInitializationCompleter!.complete();
    } catch (e) {
      _networkToolsInitializationCompleter!.completeError(e);
      _networkToolsInitializationCompleter = null;
      rethrow;
    }
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
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      debugPrint('Port check success: $host:$port is OPEN');
      return true;
    } catch (e) {
      debugPrint('Port check failed: $host:$port ($e)');
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<bool> _detectProtocols(Map<String, DiscoveredCamera> camerasByIp) async {
    var changed = false;
    final futures = camerasByIp.values.map((cam) async {
      debugPrint('Detecting protocols for ${cam.ip}...');
      final protocols = <CameraProtocol>{...cam.supportedProtocols};

      if (cam.source == CameraDiscoverySource.onvif || cam.onvifXAddr != null) {
        protocols.add(CameraProtocol.onvif);
      }

      // Check Dahua via MAC OUI
      final mac = cam.macAddress?.toUpperCase().replaceAll(':', '') ?? '';
      if (mac.startsWith('5C02F5') || mac.startsWith('38AF29') || mac.startsWith('E0508B') || mac.startsWith('9002A9') || mac.startsWith('BC325F') || mac.startsWith('14A78B')) {
        protocols.add(CameraProtocol.dahua);
      }
      
      // Check Hikvision via MAC OUI
      if (mac.startsWith('A41437') || mac.startsWith('C056E3') || mac.startsWith('8CE748') || mac.startsWith('4411C2') || mac.startsWith('E866CB')) {
        protocols.add(CameraProtocol.hikvision);
      }

      // Check Dahua via port
      if (await _isPortOpen(cam.ip, 37777)) {
        protocols.add(CameraProtocol.dahua);
      }

      // Check Hikvision
      if (await _isPortOpen(cam.ip, 8000)) {
        protocols.add(CameraProtocol.hikvision);
      }

      // Check Generic RTSP
      if (await _isPortOpen(cam.ip, 554) || await _isPortOpen(cam.ip, 8554)) {
        protocols.add(CameraProtocol.generic);
      }

      if (protocols.isEmpty) {
        protocols.add(CameraProtocol.generic);
      }

      debugPrint('Found protocols for ${cam.ip}: ${protocols.map((e) => e.displayName).join(', ')}');

      if (protocols.length != cam.supportedProtocols.length || !protocols.containsAll(cam.supportedProtocols)) {
        camerasByIp[cam.ip] = cam.copyWith(supportedProtocols: protocols);
        changed = true;
      }
    });

    await Future.wait(futures);
    return changed;
  }
}
