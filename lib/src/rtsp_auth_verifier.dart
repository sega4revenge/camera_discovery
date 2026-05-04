import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class CameraAuthException implements Exception {
  final String message;
  CameraAuthException([this.message = 'Authentication failed.']);
  
  @override
  String toString() => 'CameraAuthException: $message';
}

class RtspAuthVerifier {
  /// Connects directly to the RTSP port and performs 
  /// a DESCRIBE request to verify Basic or Digest Authentication.
  /// Returns [true] if credentials are correct, [false] otherwise.
  static Future<bool> verifyRtspAuth(String ip, String username, String password, {int port = 554}) async {
    final Completer<bool> completer = Completer<bool>();
    Socket? socket;
    
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 3));
      int step = 1;
      final uri = 'rtsp://$ip:$port/';

      socket.listen((data) {
        final responseStr = utf8.decode(data, allowMalformed: true);

        if (step == 1) {
          if (responseStr.contains('200 OK')) {
            if (!completer.isCompleted) completer.complete(true);
          } else if (responseStr.contains('401 Unauthorized')) {
            _handleUnauthorized(responseStr, username, password, uri, socket!, completer);
            step = 2;
          } else {
            if (!completer.isCompleted) completer.complete(false);
          }
        } else if (step == 2) {
          if (responseStr.contains('200 OK')) {
            if (!completer.isCompleted) completer.complete(true); 
          } else if (responseStr.contains('401 Unauthorized')) {
            if (!completer.isCompleted) completer.complete(false); 
          } else {
            if (!completer.isCompleted) completer.complete(false);
          }
        }
      }, onError: (e) {
        if (!completer.isCompleted) completer.complete(false);
      });

      socket.write('DESCRIBE $uri RTSP/1.0\r\nCSeq: 1\r\n\r\n');

      return await completer.future.timeout(const Duration(seconds: 4));
    } catch (e) {
      // Any error like timeout or connection refused resolves to false
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static void _handleUnauthorized(
    String responseStr, 
    String username, 
    String password, 
    String uri, 
    Socket socket, 
    Completer<bool> completer,
  ) {
    final isBasic = responseStr.contains('WWW-Authenticate: Basic');
    if (isBasic) {
      final authStr = base64.encode(utf8.encode('$username:$password'));
      socket.write('DESCRIBE $uri RTSP/1.0\r\nCSeq: 2\r\nAuthorization: Basic $authStr\r\n\r\n');
      return;
    } 
    
    final realmMatch = RegExp(r'realm="([^"]+)"').firstMatch(responseStr);
    final nonceMatch = RegExp(r'nonce="([^"]+)"').firstMatch(responseStr);

    if (realmMatch != null && nonceMatch != null) {
      final realm = realmMatch.group(1)!;
      final nonce = nonceMatch.group(1)!;

      final ha1 = md5.convert(utf8.encode('$username:$realm:$password')).toString();
      final ha2 = md5.convert(utf8.encode('DESCRIBE:$uri')).toString();
      final responseDigest = md5.convert(utf8.encode('$ha1:$nonce:$ha2')).toString();

      final authHeader = 'Authorization: Digest username="$username", realm="$realm", nonce="$nonce", uri="$uri", response="$responseDigest"';
      socket.write('DESCRIBE $uri RTSP/1.0\r\nCSeq: 2\r\n$authHeader\r\n\r\n');
    } else {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }
  }
}
