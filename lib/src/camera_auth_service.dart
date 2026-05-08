import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:easy_onvif/onvif.dart';

import 'camera_protocol.dart';
import 'rtsp_auth_verifier.dart';

class CameraAuthService {
  /// Verifies credentials using ONVIF if available.
  /// Returns true if successful, throws if unauthorized, or returns true if ONVIF is disabled
  /// (since we cannot easily verify digest auth without it).
  Future<bool> verifyCredentials({
    required String ip,
    required String username,
    required String password,
    String? rtspPort,
  }) async {
    try {
      await Onvif.connect(host: ip, username: username, password: password);
      return true;
    } catch (e) {
      final errorMsg = e.toString().toLowerCase();
      if (errorMsg.contains('401') || errorMsg.contains('unauthorized')) {
        throw CameraAuthException('Incorrect username or password.');
      }
      // If ONVIF fails due to timeout or connection refused (ONVIF disabled),
      // we attempt to verify using RTSP DESCRIBE auth natively.
      final portStr = await _resolveRtspPort(ip, rtspPort);
      return await RtspAuthVerifier.verifyRtspAuth(ip, username, password, port: int.tryParse(portStr) ?? 554);
    }
  }

  /// Checks whether a given RTSP URL is reachable and responds like a playable stream.
  ///
  /// Returns true for RTSP responses such as 200, 401, or 403, and false for invalid or unreachable URLs.
  Future<bool> validateRtspLink(String streamUri) async {
    return _isRtspPlayable(streamUri);
  }

  Future<List<String>> getRtspStreams({
    required String ip,
    required String username,
    required String password,
    CameraBrand brand = CameraBrand.unknown,
    CameraProtocol protocol = CameraProtocol.onvif,
    String? rtspPort,
    int maxResults = 1,
    bool useFallback = true,
  }) async {
    final effectiveMaxResults = maxResults < 1 ? 1 : maxResults;
    final port = await _resolveRtspPort(ip, rtspPort);

    // 1. Prioritize querying the camera directly for its exact RTSP URL via ONVIF
    // Many EZVIZ/Hikvision/Dahua cameras support ONVIF WS-Media. This avoids guessing.
    try {
      final onvif = await Onvif.connect(host: ip, username: username, password: password);
      final profiles = await onvif.media.getProfiles();

      final candidates = <String>[];
      for (final profile in profiles) {
        final streamUri = await onvif.media.getStreamUri(profile.token);
        if (streamUri.isNotEmpty) {
          candidates.add(_withCredentials(streamUri, username, password));
        }
      }

      final playable = await _findPlayableRtspLinks(candidates, maxResults: effectiveMaxResults);
      if (playable.isNotEmpty) {
        return playable;
      }
    } catch (e) {
      final errorMsg = e.toString().toLowerCase();
      // If ONVIF responds with 401, we definitively know the credentials are wrong.
      if (errorMsg.contains('401') || errorMsg.contains('unauthorized')) {
        throw CameraAuthException('Incorrect username or password.');
      }
      // Otherwise, ONVIF might be disabled. Let's try RTSP native verification.
      final isValid = await RtspAuthVerifier.verifyRtspAuth(ip, username, password, port: int.tryParse(port) ?? 554);
      if (!isValid) {
        throw CameraAuthException('Incorrect username or password.');
      }
    }

    // 2. If ONVIF failed and fallback is disabled, stop here.
    if (!useFallback) {
      throw Exception('Unable to fetch exact RTSP stream from camera and fallback is disabled.');
    }

    // 3. Fallback: Guess URLs based on the detected brand.
    final brandFallback = _generateRtspLinksForBrand(brand, ip, username, password, port);
    if (brandFallback.isNotEmpty) {
      final playable = await _findPlayableRtspLinks(brandFallback, maxResults: effectiveMaxResults);
      if (playable.isNotEmpty) {
        return playable;
      }
    }

    // 4. Last Resort: Guess URLs based on generic RTSP paths
    final genericFallback = _generateRtspLinksForProtocol(CameraProtocol.generic, ip, username, password, port);
    final playable = await _findPlayableRtspLinks(genericFallback, maxResults: effectiveMaxResults);
    if (playable.isNotEmpty) {
      return playable;
    }

    throw Exception('Unable to find a playable RTSP stream using any method.');
  }

  Future<String> _resolveRtspPort(String ip, String? rtspPort) async {
    var resolved = rtspPort ?? '';
    if (resolved.isEmpty) {
      final scanned = await _scanCommonRtspPorts(ip);
      resolved = scanned?.toString() ?? '554';
    }
    return resolved;
  }

  List<String> _generateRtspLinksForProtocol(
    CameraProtocol protocol,
    String ip,
    String username,
    String password,
    String port,
  ) {
    final auth = '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}';

    switch (protocol) {
      case CameraProtocol.onvif:
      case CameraProtocol.generic:
        return [
          'rtsp://$auth@$ip:$port/h264_stream',
          'rtsp://$auth@$ip:$port/Streaming/Channels/101',
          'rtsp://$auth@$ip:$port/Streaming/Channels/102',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=0',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=1',
          'rtsp://$auth@$ip:$port/onvif1',
          'rtsp://$auth@$ip:$port/live/ch00_0',
          'rtsp://$auth@$ip:$port/stream1',
          'rtsp://$auth@$ip:$port/stream2',
          'rtsp://$auth@$ip:$port/live0', // Eufy NAS (RTSP) stream
        ];
    }
  }

  List<String> _generateRtspLinksForBrand(CameraBrand brand, String ip, String username, String password, String port) {
    final auth = '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}';

    switch (brand) {
      case CameraBrand.dahua:
        return [
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=0',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=1',
        ];
      case CameraBrand.hikvision:
        return ['rtsp://$auth@$ip:$port/Streaming/Channels/101', 'rtsp://$auth@$ip:$port/Streaming/Channels/102'];
      case CameraBrand.ezviz:
        return [
          'rtsp://$auth@$ip:$port/h264_stream',
          'rtsp://$auth@$ip:$port/h265_stream',
          'rtsp://$auth@$ip:$port/Streaming/Channels/101',
        ];
      case CameraBrand.unknown:
        return const [];
    }
  }

  Future<List<String>> _findPlayableRtspLinks(List<String> candidates, {required int maxResults}) async {
    final unique = <String>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final value = candidate.trim();
      if (value.isEmpty || !seen.add(value)) {
        continue;
      }
      unique.add(value);
    }

    final playable = <String>[];
    for (final uri in unique) {
      if (await _isRtspPlayable(uri)) {
        playable.add(uri);
        if (playable.length >= maxResults) {
          break;
        }
      }
    }

    return playable;
  }

  String _withCredentials(String streamUri, String username, String password) {
    final uri = Uri.tryParse(streamUri);
    if (uri == null || uri.scheme.toLowerCase() != 'rtsp' || uri.userInfo.isNotEmpty) {
      return streamUri;
    }

    return uri.replace(userInfo: '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}').toString();
  }

  Future<bool> _isRtspPlayable(String streamUri) async {
    final uri = Uri.tryParse(streamUri);
    if (uri == null || uri.scheme.toLowerCase() != 'rtsp' || uri.host.isEmpty) {
      return false;
    }

    Socket? socket;
    try {
      socket = await Socket.connect(uri.host, uri.hasPort ? uri.port : 554, timeout: const Duration(seconds: 2));

      final request = StringBuffer()
        ..write('OPTIONS $streamUri RTSP/1.0\r\n')
        ..write('CSeq: 1\r\n')
        ..write('User-Agent: camera-scan\r\n')
        ..write('\r\n');

      socket.add(request.toString().codeUnits);
      await socket.flush();

      final response = await socket.cast<List<int>>().transform(utf8.decoder).timeout(const Duration(seconds: 2)).first;

      final statusCode = _extractRtspStatusCode(response);
      return statusCode == 200 || statusCode == 401 || statusCode == 403;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }

  int? _extractRtspStatusCode(String response) {
    final firstLine = response.split('\r\n').firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (!firstLine.startsWith('RTSP/1.0')) {
      return null;
    }

    final parts = firstLine.split(' ');
    if (parts.length < 2) {
      return null;
    }

    return int.tryParse(parts[1]);
  }

  Future<int?> _scanCommonRtspPorts(String ip) async {
    final commonPorts = [554, 1554, 8554, 10554, 5540, 8000];

    final futures = commonPorts.map((port) async {
      try {
        final socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 1500));
        socket.destroy();
        return port;
      } catch (_) {
        return null;
      }
    });

    final results = await Future.wait(futures);
    final successfulPorts = results.whereType<int>().toList();

    if (successfulPorts.isNotEmpty) {
      if (successfulPorts.contains(554)) return 554;
      return successfulPorts.first;
    }
    return null;
  }
}
