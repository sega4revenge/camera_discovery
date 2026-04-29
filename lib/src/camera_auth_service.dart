import 'dart:io';
import 'dart:convert';

import 'package:easy_onvif/onvif.dart';

import 'camera_protocol.dart';

class CameraAuthService {
  Future<List<String>> getRtspStreams({
    required String ip,
    required String username,
    required String password,
    CameraProtocol protocol = CameraProtocol.onvif,
    String? rtspPort,
    int maxResults = 1,
  }) async {
    final effectiveMaxResults = maxResults < 1 ? 1 : maxResults;
    final port = await _resolveRtspPort(ip, rtspPort);

    if (protocol != CameraProtocol.onvif) {
      final candidates = _generateRtspLinksForProtocol(protocol, ip, username, password, port);
      final playable = await _findPlayableRtspLinks(candidates, maxResults: effectiveMaxResults);
      if (playable.isNotEmpty) {
        return playable;
      }
      throw Exception('Unable to find a playable RTSP stream for ${protocol.displayName}.');
    }

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
      if (errorMsg.contains('404') ||
          errorMsg.contains('refuse') ||
          errorMsg.contains('disabled') ||
          errorMsg.contains('connection') ||
          errorMsg.contains('timeout') ||
          errorMsg.contains('socket')) {
        final fallback = _generateRtspLinksForProtocol(CameraProtocol.generic, ip, username, password, port);
        final playable = await _findPlayableRtspLinks(fallback, maxResults: effectiveMaxResults);
        if (playable.isNotEmpty) {
          return playable;
        }

        throw Exception('Unable to find a playable RTSP stream.');
      }

      throw Exception('Unable to authenticate camera or fetch RTSP streams: $e');
    }

    final fallback = _generateRtspLinksForProtocol(CameraProtocol.generic, ip, username, password, port);
    final playable = await _findPlayableRtspLinks(fallback, maxResults: effectiveMaxResults);
    if (playable.isNotEmpty) {
      return playable;
    }

    throw Exception('Unable to find a playable RTSP stream.');
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
      CameraProtocol protocol, String ip, String username, String password, String port) {
    final auth = '${Uri.encodeComponent(username)}:${Uri.encodeComponent(password)}';

    switch (protocol) {
      case CameraProtocol.dahua:
        return [
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=0',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=1',
        ];
      case CameraProtocol.hikvision:
        return [
          'rtsp://$auth@$ip:$port/Streaming/Channels/101',
          'rtsp://$auth@$ip:$port/Streaming/Channels/102',
        ];
      case CameraProtocol.onvif:
      case CameraProtocol.generic:
        return [
          'rtsp://$auth@$ip:$port/Streaming/Channels/101',
          'rtsp://$auth@$ip:$port/Streaming/Channels/102',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=0',
          'rtsp://$auth@$ip:$port/cam/realmonitor?channel=1&subtype=1',
          'rtsp://$auth@$ip:$port/onvif1',
          'rtsp://$auth@$ip:$port/live/ch00_0',
          'rtsp://$auth@$ip:$port/stream1',
          'rtsp://$auth@$ip:$port/stream2',
        ];
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
