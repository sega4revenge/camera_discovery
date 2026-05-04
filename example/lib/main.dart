import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera_discovery/camera_discovery.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const CameraDiscoveryExampleApp());
}

class CameraDiscoveryExampleApp extends StatelessWidget {
  const CameraDiscoveryExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Discovery Example',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

class ManualScanScreen extends StatefulWidget {
  const ManualScanScreen({super.key});

  @override
  State<ManualScanScreen> createState() => _ManualScanScreenState();
}

class _ManualScanScreenState extends State<ManualScanScreen> {
  final CameraDiscoveryService _discoveryService = CameraDiscoveryService(logLevel: CameraDiscoveryLogLevel.none);
  bool _isDiscovering = false;
  List<DiscoveredCamera> _cameras = [];
  String _statusPhase = '';
  String? _error;

  Future<void> _startDiscovery() async {
    setState(() {
      _isDiscovering = true;
      _cameras = [];
      _statusPhase = 'Starting discovery...';
      _error = null;
    });

    try {
      final report = await _discoveryService.discover(
        onProgress: (cameras, phase) {
          if (!mounted) return;
          setState(() {
            _cameras = cameras;
            _statusPhase = phase.displayName;
          });
        },
      );

      setState(() {
        _cameras = report.cameras;
        _isDiscovering = false;
        _statusPhase = 'Completed';
        _error = report.error;
      });
    } catch (e, stack) {
      debugPrint('Discovery failed: $e');
      debugPrint(stack.toString());
      setState(() {
        _isDiscovering = false;
        _error = e.toString();
      });
      rethrow;
    }
  }

  void _onCameraTapped(DiscoveredCamera camera) {
    showDialog(
      context: context,
      builder: (context) => AuthDialog(camera: camera),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manual Camera Scan'),
        actions: [
          if (_isDiscovering)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            )
          else
            IconButton(icon: const Icon(Icons.refresh), onPressed: _startDiscovery),
        ],
      ),
      body: Column(
        children: [
          if (_statusPhase.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Colors.grey.shade200,
              width: double.infinity,
              child: Text('Status: $_statusPhase', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Colors.red.shade100,
              width: double.infinity,
              child: Text('Error/Warnings: $_error', style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _cameras.isEmpty
                ? const Center(child: Text('No cameras found. Tap refresh to scan.'))
                : ListView.builder(
                    itemCount: _cameras.length,
                    itemBuilder: (context, index) {
                      final camera = _cameras[index];
                      return ListTile(
                        leading: const Icon(Icons.camera_alt),
                        title: Text(camera.name ?? 'Unknown Camera'),
                        subtitle: Text(
                          '${camera.ip} - ${camera.supportedProtocols.map((e) => e.displayName).join(', ')}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onCameraTapped(camera),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _isDiscovering ? null : _startDiscovery,
        child: const Icon(Icons.search),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera Discovery')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.search),
              label: const Text('Manual Scan'),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const ManualScanScreen())),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.radar),
              label: const Text('Real-time Scan'),
              onPressed: () =>
                  Navigator.push(context, MaterialPageRoute(builder: (context) => const RealTimeScanScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class RealTimeScanScreen extends StatefulWidget {
  const RealTimeScanScreen({super.key});

  @override
  State<RealTimeScanScreen> createState() => _RealTimeScanScreenState();
}

class _RealTimeScanScreenState extends State<RealTimeScanScreen> {
  final CameraDiscoveryService _discoveryService = CameraDiscoveryService();
  Timer? _timer;
  List<DiscoveredCamera> _cameras = [];

  @override
  void initState() {
    super.initState();
    _startRealTimeScan();
  }

  void _startRealTimeScan() {
    // Initial scan
    _runScan();
    // Periodic scan
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _runScan();
    });
  }

  Future<void> _runScan() async {
    try {
      final report = await _discoveryService.discover(onvifTimeout: const Duration(seconds: 2));
      if (mounted) {
        setState(() {
          // Since discover creates a new report each time,
          // simply replacing the list will naturally drop cameras that are no longer found.
          _cameras = report.cameras;
        });
      }
    } catch (e) {
      debugPrint('Real-time scan error: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onCameraTapped(DiscoveredCamera camera) {
    showDialog(
      context: context,
      builder: (context) => AuthDialog(camera: camera),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Real-time Scan')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8.0),
            color: Colors.green.shade100,
            width: double.infinity,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('Scanning in background...', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Expanded(
            child: _cameras.isEmpty
                ? const Center(child: Text('Looking for cameras...'))
                : ListView.builder(
                    itemCount: _cameras.length,
                    itemBuilder: (context, index) {
                      final camera = _cameras[index];
                      return ListTile(
                        leading: const Icon(Icons.camera_alt, color: Colors.green),
                        title: Text(camera.name ?? 'Unknown Camera'),
                        subtitle: Text(
                          '${camera.ip} - ${camera.supportedProtocols.map((e) => e.displayName).join(', ')}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _onCameraTapped(camera),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class AuthDialog extends StatefulWidget {
  final DiscoveredCamera camera;

  const AuthDialog({super.key, required this.camera});

  @override
  State<AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<AuthDialog> {
  final _usernameController = TextEditingController(text: 'admin');
  final _passwordController = TextEditingController();
  late CameraProtocol _selectedProtocol;
  final _authService = CameraAuthService();
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    if (widget.camera.supportedProtocols.isNotEmpty) {
      _selectedProtocol = widget.camera.supportedProtocols.first;
    } else {
      _selectedProtocol = CameraProtocol.generic;
    }
  }

  Future<void> _authenticate() async {
    setState(() {
      _isAuthenticating = true;
    });

    try {
      final streams = await _authService.getRtspStreams(
        ip: widget.camera.ip,
        username: _usernameController.text,
        password: _passwordController.text,
        protocol: _selectedProtocol,
        maxResults: 10,
      );

      if (!mounted) return;

      if (streams.isNotEmpty) {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                StreamListScreen(cameraName: widget.camera.name ?? widget.camera.ip, streams: streams),
          ),
        );
      } else {
        _showError('No playable stream found.');
      }
    } catch (e, stack) {
      debugPrint('Authentication failed: $e');
      debugPrint(stack.toString());
      if (mounted) {
        _showError(e.toString());
      }
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
        });
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Authenticate ${widget.camera.ip}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _usernameController,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          TextField(
            controller: _passwordController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          DropdownButton<CameraProtocol>(
            value: _selectedProtocol,
            isExpanded: true,
            hint: const Text('Protocol'),
            items: widget.camera.supportedProtocols.isNotEmpty
                ? widget.camera.supportedProtocols
                      .map((p) => DropdownMenuItem(value: p, child: Text(p.displayName)))
                      .toList()
                : [const DropdownMenuItem(value: CameraProtocol.generic, child: Text('Generic RTSP'))],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedProtocol = val;
                });
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _isAuthenticating ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _isAuthenticating ? null : _authenticate,
          child: _isAuthenticating
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Connect'),
        ),
      ],
    );
  }
}

class StreamListScreen extends StatelessWidget {
  final String cameraName;
  final List<String> streams;

  const StreamListScreen({super.key, required this.cameraName, required this.streams});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Streams for $cameraName')),
      body: ListView.builder(
        itemCount: streams.length,
        itemBuilder: (context, index) {
          final url = streams[index];
          return ListTile(
            leading: const Icon(Icons.videocam),
            title: Text('Stream ${index + 1}'),
            subtitle: Text(url, style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.play_arrow),
            onTap: () {
              Navigator.push(context, MaterialPageRoute(builder: (context) => PlayerScreen(url: url)));
            },
          );
        },
      ),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  final String url;

  const PlayerScreen({super.key, required this.url});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _videoController = VideoController(
    _player,
    configuration: const VideoControllerConfiguration(
      // Tạm tắt hardware acceleration để sửa lỗi EGL_BAD_ATTRIBUTE trên Android Emulator.
      // Lưu ý: Chỉ nên dùng khi test trên máy ảo. Khi build lên máy thật, hãy đổi thành true (hoặc xóa dòng này đi).
      enableHardwareAcceleration: false,
    ),
  );
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.url), play: true);
    _player.stream.error.listen((event) {
      if (!_hasError) {
        setState(() {
          _hasError = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera Stream')),
      body: Center(
        child: _hasError
            ? const Text('Error playing stream', style: TextStyle(color: Colors.red))
            : Video(controller: _videoController),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16.0),
        color: Colors.grey.shade900,
        child: Text(
          widget.url,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
