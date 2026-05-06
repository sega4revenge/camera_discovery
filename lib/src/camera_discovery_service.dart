import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:easy_onvif/probe.dart';
import 'package:nsd/nsd.dart';

import 'camera_discovery_helpers.dart';
import 'camera_protocol.dart';
import 'discovered_camera.dart';
import 'discovery_report.dart';

enum CameraDiscoveryPhase { scan, validatingProtocol, completed }

extension CameraDiscoveryPhaseExtension on CameraDiscoveryPhase {
  String displayName([CameraDiscoveryProtocol? protocol]) {
    switch (this) {
      case CameraDiscoveryPhase.scan:
        if (protocol == null) {
          return 'Scanning...';
        }
        return 'Scanning ${protocol.displayName}...';
      case CameraDiscoveryPhase.validatingProtocol:
        return 'Validating available protocols...';
      case CameraDiscoveryPhase.completed:
        return 'Completed';
    }
  }
}

enum CameraDiscoveryLogLevel { none, critical, all }

class CameraDiscoveryService {
  final CameraDiscoveryLogLevel logLevel;

  CameraDiscoveryService({this.logLevel = CameraDiscoveryLogLevel.critical});

  void _log(String message, {bool isCritical = false}) {
    if (logLevel == CameraDiscoveryLogLevel.none) return;
    if (logLevel == CameraDiscoveryLogLevel.critical && !isCritical) return;
    debugPrint('[CameraDiscoveryService] $message');
  }

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
    '_hap._tcp', // HomeKit (many Eufy cameras use this standard)
    '_eufy._tcp', // Fallback for Eufy devices
    '_ezviz._tcp', // EZVIZ
  ];

  Future<DiscoveryReport> discover({
    Duration onvifTimeout = const Duration(seconds: 4),
    bool forceMulticast = true,
    List<CameraDiscoveryProtocol> listProtocol = const [
      CameraDiscoveryProtocol.multicast,
      CameraDiscoveryProtocol.onvif,
      CameraDiscoveryProtocol.sadp,
    ],
    void Function(List<DiscoveredCamera> cameras, CameraDiscoveryPhase phase, CameraDiscoveryProtocol? protocol)?
    onProgress,
  }) async {
    final startedAt = DateTime.now();
    final camerasByIp = <String, DiscoveredCamera>{};
    final ipByName = <String, String>{};
    final warnings = <String>[];
    void notifyProgress(CameraDiscoveryPhase phase, [CameraDiscoveryProtocol? protocol]) =>
        onProgress == null ? null : onProgress(sortCamerasByIpOctet(camerasByIp.values), phase, protocol);
    bool shouldRunProtocol(CameraDiscoveryProtocol protocol) => listProtocol.contains(protocol);

    try {
      if (shouldRunProtocol(CameraDiscoveryProtocol.multicast) || shouldRunProtocol(CameraDiscoveryProtocol.sadp)) {
        notifyProgress(CameraDiscoveryPhase.scan);
      }

      if (shouldRunProtocol(CameraDiscoveryProtocol.multicast)) {
        // Run mDNS Bonjour and SADP in parallel — both are fast broadcast/multicast protocols.
        try {
          notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.multicast);
          await _discoverMdns(
            camerasByIp,
            ipByName,
            () => notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.multicast),
          );
        } catch (e) {
          warnings.add('mDNS/Bonjour discovery failed: $e');
        }
      }

      if (shouldRunProtocol(CameraDiscoveryProtocol.sadp)) {
        try {
          notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.sadp);
          await _discoverSadp(
            camerasByIp,
            ipByName,
            () => notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.sadp),
          );
        } catch (e) {
          warnings.add('SADP discovery failed: $e');
        }
      }

      if (shouldRunProtocol(CameraDiscoveryProtocol.onvif)) {
        notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.onvif);
        try {
          final onvifMatches = Platform.isIOS && !forceMulticast
              ? const <ProbeMatch>[]
              : await _discoverOnvif(onvifTimeout, forceMulticast: forceMulticast);

          for (final match in onvifMatches) {
            final ip = extractIpv4FromXAddrs(match.xAddrs);
            if (ip == null) continue;

            final supportedProtocols = <CameraProtocol>{CameraProtocol.onvif};
            final brand = detectCameraBrand([
              match.hardware,
              match.name,
              match.scopes.toString(),
              match.endpointReference.address,
            ]);
            _log('ONVIF Match metadata for $ip: brand=${brand.displayName} name=${match.name}');

            final newCam = DiscoveredCamera(
              ip: ip,
              source: CameraDiscoverySource.onvif,
              brand: brand,
              name: match.name.isEmpty ? null : match.name,
              onvifXAddr: match.xAddr,
              supportedProtocols: supportedProtocols,
            );

            if (_addOrMergeCamera(newCam, camerasByIp, ipByName)) {
              notifyProgress(CameraDiscoveryPhase.scan, CameraDiscoveryProtocol.onvif);
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
      }

      notifyProgress(CameraDiscoveryPhase.validatingProtocol);
      try {
        final changed = await _detectProtocols(camerasByIp);
        if (changed) notifyProgress(CameraDiscoveryPhase.validatingProtocol);
      } catch (e) {
        warnings.add('Protocol detection failed: $e');
      }
    } catch (e) {
      warnings.add('Discovery failed: $e');
    }
    notifyProgress(CameraDiscoveryPhase.completed);

    return DiscoveryReport(
      cameras: sortCamerasByIpOctet(camerasByIp.values),
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      usedFallbackScan: false,
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

    DiscoveredCamera mergeFields(DiscoveredCamera existing, DiscoveredCamera incoming) {
      final mergedModel = incoming.model ?? existing.model;
      final mergedSerial = incoming.serialNumber ?? existing.serialNumber;
      final mergedBrand = incoming.brand != CameraBrand.unknown ? incoming.brand : existing.brand;

      String? mergedName = existing.name;
      if (mergedModel != null || mergedSerial != null) {
        final m = mergedModel ?? '';
        final s = mergedSerial ?? '';
        if (m.isNotEmpty || s.isNotEmpty) {
          mergedName = '$m $s'.trim();
        }
      } else {
        mergedName = incoming.name ?? existing.name;
      }

      return existing.copyWith(
        brand: mergedBrand,
        name: mergedName,
        model: mergedModel,
        serialNumber: mergedSerial,
        onvifXAddr: incoming.onvifXAddr ?? existing.onvifXAddr,
        rtspUri: incoming.rtspUri ?? existing.rtspUri,
        macAddress: incoming.macAddress ?? existing.macAddress,
        supportedProtocols: existing.supportedProtocols.union(incoming.supportedProtocols),
      );
    }

    if (name != null && name.isNotEmpty) {
      final existingIp = ipByName[name];
      if (existingIp != null) {
        final existingCam = camerasByIp[existingIp]!;
        final isExistingIpv6 = existingIp.contains(':');

        if (isExistingIpv6 && !isNewIpv6) {
          camerasByIp.remove(existingIp);
          camerasByIp[newIp] = mergeFields(existingCam, newCam).copyWith(ip: newIp);
          ipByName[name] = newIp;
          return true;
        } else if (!isExistingIpv6 && isNewIpv6) {
          return false;
        } else {
          camerasByIp[existingIp] = mergeFields(existingCam, newCam);
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
      camerasByIp[newIp] = mergeFields(existingCam, newCam);
      return true;
    }

    camerasByIp[newIp] = newCam;
    return true;
  }

  /// Discovers EZVIZ/Hikvision cameras via SADP (Search Active Devices Protocol).
  ///
  /// SADP sends a raw XML probe over UDP broadcast/multicast to port 37020.
  /// Cameras respond with XML containing their IP, MAC, Model, Manufacturer, etc.
  /// This is the fastest and most reliable method to find EZVIZ cameras since
  /// they respond even when ICMP ping and RTSP are disabled.
  ///
  /// Reference: https://github.com/MatrixEditor/hiktools
  Future<void> _discoverSadp(
    Map<String, DiscoveredCamera> camerasByIp,
    Map<String, String> ipByName,
    VoidCallback onUpdated,
  ) async {
    const sadpPort = 37020;
    const sadpMulticast = '239.255.255.250';
    const discoveryWindow = Duration(seconds: 3);

    // SADP probe: raw XML string (no binary header — hiktools confirmed)
    const probeXml =
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Probe><Uuid>01234567-0123-0123-0123-012345678901</Uuid>'
        '<Types>inquiry</Types></Probe>';
    final probeBytes = Uint8List.fromList(utf8.encode(probeXml));

    RawDatagramSocket? socket;
    Timer? closeTimer;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastLoopback = false;

      // Join multicast group (may fail on iOS without Multicast Entitlement)
      try {
        socket.joinMulticast(InternetAddress(sadpMulticast));
      } catch (_) {}

      // Send to multicast
      try {
        socket.send(probeBytes, InternetAddress(sadpMulticast), sadpPort);
        _log('SADP: probe sent to $sadpMulticast:$sadpPort');
      } catch (e) {
        _log('SADP: multicast send failed ($e), trying broadcast...', isCritical: true);
      }

      // Fallback: broadcast to 255.255.255.255
      try {
        socket.send(probeBytes, InternetAddress('255.255.255.255'), sadpPort);
        _log('SADP: probe sent to 255.255.255.255:$sadpPort');
      } catch (_) {}

      // Close socket after discovery window to end the await-for loop
      closeTimer = Timer(discoveryWindow, () {
        try {
          socket?.close();
        } catch (_) {}
      });

      await for (final event in socket) {
        if (event == RawSocketEvent.closed) break;
        if (event != RawSocketEvent.read) continue;

        final datagram = socket.receive();
        if (datagram == null) continue;

        // Response is raw XML — no binary header to strip
        final xml = utf8.decode(datagram.data, allowMalformed: true);
        _log(
          'SADP response from ${datagram.address.address}: '
          '${xml.length > 300 ? xml.substring(0, 300) : xml}',
        );

        final cam = _parseSadpResponse(xml, datagram.address.address);
        if (cam != null && _addOrMergeCamera(cam, camerasByIp, ipByName)) {
          onUpdated();
        }
      }
    } catch (e) {
      _log('SADP discovery error: $e', isCritical: true);
      rethrow;
    } finally {
      closeTimer?.cancel();
      try {
        socket?.close();
      } catch (_) {}
    }
  }

  /// Parses a SADP XML response and returns a [DiscoveredCamera], or null if invalid.
  DiscoveredCamera? _parseSadpResponse(String xml, String senderIp) {
    // Must contain ProbeMatch or device info to be a valid SADP response
    if (!xml.contains('ProbeMatch') &&
        !xml.contains('DeviceDescription') &&
        !xml.contains('DeviceType') &&
        !xml.contains('Ipv4Address') &&
        !xml.contains('IPv4Address')) {
      return null;
    }

    String? extract(String tag) {
      final m = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml);
      return m?.group(1)?.trim();
    }

    final ip = extract('Ipv4Address') ?? extract('IPv4Address') ?? senderIp;
    if (ip.isEmpty || ip == '0.0.0.0') return null;

    final mac = extract('MAC') ?? extract('MacAddress');
    final model = extract('DeviceDescription') ?? extract('Model') ?? 'Unknown Model';
    final serialNumber = extract('DeviceSN') ?? '';
    final deviceType = extract('DeviceType') ?? '';
    final manufacturerTag = (extract('Manufacturer') ?? '').toLowerCase();

    final brand = detectCameraBrand([model, manufacturerTag, deviceType]);

    final brandName = brand == CameraBrand.unknown ? '' : brand.displayName;
    final displayName = serialNumber.isNotEmpty
        ? '${brandName.isNotEmpty ? '$brandName ' : ''}$serialNumber'
        : '${brandName.isNotEmpty ? '$brandName ' : ''}$model';

    final protocols = <CameraProtocol>{CameraProtocol.generic};

    // NVR / DVR devices also support ONVIF commonly.
    if (deviceType.toLowerCase().contains('nvr') || deviceType.toLowerCase().contains('dvr')) {
      protocols.add(CameraProtocol.onvif);
    }

    _log(
      'SADP parsed: ip=$ip mac=$mac model=$model serial=$serialNumber brand=${brand.displayName} '
      'protocols=${protocols.map((e) => e.displayName).join(",")} ',
    );

    return DiscoveredCamera(
      ip: ip,
      source: CameraDiscoverySource.sadp,
      brand: brand,
      name: displayName,
      model: model,
      serialNumber: serialNumber,
      macAddress: mac,
      supportedProtocols: protocols,
    );
  }

  void _configureNsdIfNeeded() {
    if (_nsdConfigured) {
      return;
    }

    disableServiceTypeValidation(true);
    _nsdConfigured = true;
  }

  Future<List<ProbeMatch>> _discoverOnvif(Duration timeout, {required bool forceMulticast}) async {
    if (Platform.isIOS && !forceMulticast) {
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
      discovery = await startDiscovery(serviceType, ipLookupType: IpLookupType.v4).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('startDiscovery timed out for serviceType=$serviceType after 5s'),
      );

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
            supportedProtocols: const {CameraProtocol.generic},
            name: name?.isNotEmpty == true ? name : null,
            rtspUri: 'rtsp://$ip:$port',
          );

          if (_addOrMergeCamera(newCam, camerasByIp, ipByName)) {
            changed = true;
          }
        } catch (e, st) {
          _log(
            'mDNS resolve/listener error for serviceType=$serviceType '
            'service=${service.name ?? "<unknown>"}: ${e.runtimeType}: $e\n$st',
            isCritical: true,
          );
        }
      });

      await Future<void>.delayed(_mdnsDiscoveryWindow);
    } on TimeoutException catch (e, st) {
      _log('mDNS startDiscovery timeout for serviceType=$serviceType: $e\n$st', isCritical: true);
      Error.throwWithStackTrace(TimeoutException('mDNS startDiscovery timeout for serviceType=$serviceType: $e'), st);
    } on SocketException catch (e, st) {
      _log(
        'mDNS socket error for serviceType=$serviceType: ${e.message} '
        '(osError=${e.osError})\n$st',
        isCritical: true,
      );
      Error.throwWithStackTrace(
        Exception(
          'mDNS socket error for serviceType=$serviceType: ${e.message} '
          '(osError=${e.osError})',
        ),
        st,
      );
    } catch (e, st) {
      _log('mDNS discovery failed for serviceType=$serviceType: ${e.runtimeType}: $e\n$st', isCritical: true);
      Error.throwWithStackTrace(
        Exception('mDNS discovery failed for serviceType=$serviceType: ${e.runtimeType}: $e'),
        st,
      );
    } finally {
      if (discovery != null) {
        try {
          await stopDiscovery(discovery);
        } catch (e, st) {
          _log(
            'mDNS stopDiscovery failed for serviceType=$serviceType: '
            '${e.runtimeType}: $e\n$st',
            isCritical: true,
          );
        }
      }
    }

    return changed;
  }

  Future<bool> _isPortOpen(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 1500));
      _log('Port check success: $host:$port is OPEN');
      return true;
    } catch (e) {
      _log('Port check failed: $host:$port ($e)');
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<bool> _detectProtocols(Map<String, DiscoveredCamera> camerasByIp) async {
    var changed = false;
    final futures = camerasByIp.values.map((cam) async {
      _log('Detecting protocols for ${cam.ip}...');
      final protocols = <CameraProtocol>{...cam.supportedProtocols};

      if (cam.source == CameraDiscoverySource.onvif || cam.onvifXAddr != null) {
        protocols.add(CameraProtocol.onvif);
      }

      // Check Generic RTSP
      if (await _isPortOpen(cam.ip, 554) || await _isPortOpen(cam.ip, 8554)) {
        protocols.add(CameraProtocol.generic);
      }

      if (protocols.isEmpty) {
        protocols.add(CameraProtocol.generic);
      }

      _log('Found protocols for ${cam.ip}: ${protocols.map((e) => e.displayName).join(', ')}');

      if (protocols.length != cam.supportedProtocols.length || !protocols.containsAll(cam.supportedProtocols)) {
        camerasByIp[cam.ip] = cam.copyWith(supportedProtocols: protocols);
        changed = true;
      }
    });

    await Future.wait(futures);
    return changed;
  }
}
