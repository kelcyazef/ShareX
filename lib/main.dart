import 'package:flutter/material.dart';
import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sharex/services/p2p_service.dart';
import 'package:sharex/screens/files_screen.dart';

void main() {
  runApp(const MyApp());
}

const Color kPrimaryColor = Colors.white;
const Color kButtonColor = Color(0xFF001f3f); // navy
const Color kAccentColor = Colors.blueAccent;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primaryColor: kPrimaryColor,
        scaffoldBackgroundColor: kPrimaryColor,
        colorScheme: ColorScheme.light(
          primary: kButtonColor,
          secondary: kAccentColor,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kButtonColor,
          foregroundColor: Colors.white,
          elevation: 4.0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kButtonColor,
            foregroundColor: Colors.white,
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: kButtonColor,
          foregroundColor: Colors.white,
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(color: kButtonColor, fontWeight: FontWeight.bold),
          bodyMedium: TextStyle(color: Colors.black87),
        ),
        cardTheme: CardTheme(
          elevation: 2.0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)),
        ),
      ),
      home: const MyHomePage(title: 'ShareX File Transfer'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  late P2PService _p2pService;
  List<String> _pickedFilePaths = [];
  String _statusMessage = "Initializing...";
  final List<Map<String, dynamic>> _discoveredEndpoints = [];
  final List<String> _connectedEndpointIds = [];

  StreamSubscription? _accelSub;
  StreamSubscription? _connectionEventSub;
  StreamSubscription? _payloadEventSub;
  StreamSubscription? _incomingConnectionRequestSub;

  @override
  void initState() {
    super.initState();
    _p2pService = P2PService();
    _initializeServices();
    _startShakeDetection();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _initializeServices() async {
    _connectionEventSub = _p2pService.connectionEvents.listen((event) {
      _handleConnectionEvent(event);
    });

    _payloadEventSub = _p2pService.payloadEvents.listen((event) {
      _handlePayloadEvent(event);
    });

    _incomingConnectionRequestSub =
        _p2pService.incomingConnectionRequestEvents.listen((event) {
      _handleIncomingConnectionRequest(event);
    });

    await Future.delayed(const Duration(milliseconds: 500));
    await _p2pService.startAdvertising();
    await _p2pService.startDiscovery();

    setState(() {
      _statusMessage = "Advertising & Discovering...";
    });
  }

  void _handleConnectionEvent(Map<String, dynamic> event) {
    String eventType = event['event'] as String? ?? 'unknown';
    String id = event['id'] as String? ?? '';
    setState(() {
      switch (eventType) {
        case 'advertising_started':
          _statusMessage = "Advertising started. Discovering...";
          break;
        case 'discovery_started':
          _statusMessage = _statusMessage.contains("Advertising")
              ? "Advertising & Discovering..."
              : "Discovery started.";
          break;
        case 'endpoint_found':
          if (!_discoveredEndpoints.any((ep) => ep['id'] == id)) {
            _discoveredEndpoints.add(event);
            _statusMessage = "Endpoint found: ${event['name']}. Tap to connect.";
          }
          break;
        case 'endpoint_lost':
          _discoveredEndpoints.removeWhere((ep) => ep['id'] == id);
          break;
        case 'connection_initiated':
          _statusMessage = "Connection initiated with ${event['endpointName']}...";
          break;
        case 'connection_result':
          String status = event['status'] as String? ?? 'unknown_status';
          if (status == Status.CONNECTED.toString()) {
            if (!_connectedEndpointIds.contains(id)) {
              _connectedEndpointIds.add(id);
            }
            _discoveredEndpoints.removeWhere((ep) => ep['id'] == id);
            _statusMessage = "Connected to $id";
          } else {
            _statusMessage = "Connection to $id failed: $status";
            _connectedEndpointIds.remove(id);
          }
          break;
        case 'disconnected':
          _connectedEndpointIds.remove(id);
          _statusMessage = "Disconnected from $id";
          break;
        case 'advertising_error':
        case 'discovery_error':
          _statusMessage = "Error: ${event['error']}";
          break;
        case 'permission_denied':
          _statusMessage = "Required permissions denied. Cannot start P2P services.";
          _showPermissionDialog("Required permissions are not granted",
              "ShareX needs Bluetooth, Location, and Storage permissions to function properly.");
          break;
        case 'permission_check_failed':
          String permissionName = event['permission'] as String? ?? 'Unknown';
          String details = event['details'] as String? ?? '';
          _statusMessage = "Permission denied: $permissionName";
          _showPermissionDialog("$permissionName denied",
              "$details\nPlease grant this permission for ShareX to work properly.");
          break;
        case 'permission_status':
          bool bluetooth = event['bluetooth'] as bool? ?? false;
          bool location = event['location'] as bool? ?? false;
          bool storage = event['storage'] as bool? ?? false;
          if (bluetooth && location && storage) {
            _statusMessage = "All permissions granted. Starting P2P services...";
          } else {
            List<String> missingPermissions = [];
            if (!bluetooth) missingPermissions.add("Bluetooth");
            if (!location) missingPermissions.add("Location");
            if (!storage) missingPermissions.add("Storage");
            _statusMessage = "Missing permissions: ${missingPermissions.join(', ')}";
          }
          break;
        default:
          _statusMessage = "P2P Event: $eventType";
      }
    });
  }

  void _handlePayloadEvent(Map<String, dynamic> event) {
    String eventType = event['event'] as String? ?? 'unknown';
    setState(() {
      switch (eventType) {
        case 'bytes_received':
          String data = event['data'] as String? ?? '';
          _statusMessage = "Received data: $data from ${event['endpointId']}";
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Received: $data")));
          break;
        case 'file_received_start':
          String fileName = event['fileName'] as String? ?? 'Unknown file';
          _statusMessage = "Receiving file $fileName from ${event['endpointId']}...";
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Receiving file: $fileName")));
          break;
        case 'file_transfer_update':
          String status = event['status'] as String? ?? '';
          String fileName = event['fileName'] as String? ?? 'Unknown file';
          if (status == PayloadStatus.SUCCESS.toString()) {
            _statusMessage = "File $fileName from ${event['endpointId']} received successfully!";
            // Don't show a snackbar here as we'll show one when file_received event comes
          } else if (status == PayloadStatus.FAILURE.toString()) {
            _statusMessage = "File transfer $fileName from ${event['endpointId']} failed.";
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("File transfer failed: $fileName")));
          } else if (status == PayloadStatus.IN_PROGRESS.toString()) {
            int bytesTransferred = event['bytesTransferred'] as int? ?? 0;
            int totalBytes = event['totalBytes'] as int? ?? 1;
            double progress = bytesTransferred / totalBytes;
            _statusMessage = "File $fileName from ${event['endpointId']} in progress: ${(progress * 100).toStringAsFixed(1)}%";
          }
          break;
        case 'file_received':
          String fileName = event['fileName'] as String? ?? 'Unknown file';
          String filePath = event['filePath'] as String? ?? '';
          int fileSize = event['fileSize'] as int? ?? 0;
          _statusMessage = "File $fileName saved successfully!";
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("File received: $fileName"),
                  Text("Size: ${_formatFileSize(fileSize)}"),
                  Text("Saved to: $filePath", style: TextStyle(fontSize: 12)),
                ],
              ),
              duration: Duration(seconds: 5),
              action: SnackBarAction(
                label: 'VIEW FILES',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => FilesScreen()),
                  );
                },
              ),
            ),
          );
          break;
      }
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }

  void _handleIncomingConnectionRequest(Map<String, dynamic> event) {
    final String endpointId = event['id'] as String;
    final String endpointName = event['endpointName'] as String;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Incoming Connection Request'),
          content: Text('Accept connection from $endpointName ($endpointId)?'),
          actions: <Widget>[
            TextButton(
              child: const Text('REJECT'),
              onPressed: () {
                Navigator.of(context).pop();
                _p2pService.rejectConnection(endpointId);
                setState(() {
                  _statusMessage = "Rejected connection from $endpointName";
                });
              },
            ),
            TextButton(
              child: const Text('ACCEPT'),
              onPressed: () {
                Navigator.of(context).pop();
                _p2pService.acceptConnection(endpointId);
                setState(() {
                  _statusMessage = "Accepted connection from $endpointName. Waiting for connection result...";
                });
              },
            ),
          ],
        );
      },
    );
  }

  void _startShakeDetection() {
    const double shakeThresholdGravity = 1.5;
    _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
      final double x = event.x / 9.81, y = event.y / 9.81, z = event.z / 9.81;
      double gForce = x * x + y * y + z * z;
      if (gForce > shakeThresholdGravity * shakeThresholdGravity) {
        _pickAndSendFiles(triggeredByShake: true);
      }
    });
  }

  Future<void> _pickFiles() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );
      if (result != null && result.paths.isNotEmpty) {
        setState(() {
          _pickedFilePaths = result.paths.where((path) => path != null).cast<String>().toList();
          _statusMessage = "Selected ${_pickedFilePaths.length} file(s).";
        });
      } else {
        setState(() {
          _statusMessage = "File picking cancelled or no files selected.";
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = "Error picking files: $e";
      });
    }
  }

  Future<void> _pickAndSendFiles({bool triggeredByShake = false}) async {
    if (!triggeredByShake || (triggeredByShake && _pickedFilePaths.isEmpty)) {
      await _pickFiles();
    }

    if (_pickedFilePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No files selected to send.')));
      }
      return;
    }

    if (_connectedEndpointIds.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No devices connected to send files.')));
      }
      return;
    }

    int filesSentCount = 0;
    for (String path in _pickedFilePaths) {
      for (String endpointId in _connectedEndpointIds) {
        try {
          await _p2pService.sendFile(endpointId, path);
          filesSentCount++;
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Error sending file $path to $endpointId: $e')));
          }
        }
      }
    }

    if (filesSentCount > 0) {
      setState(() {
        _statusMessage = "Sent $filesSentCount file(s).";
        _pickedFilePaths = [];
      });
    } else {
      setState(() {
        _statusMessage = "File sending failed or no files were sent.";
      });
    }
  }

  String _getFileName(String path) {
    return path.split('/').last;
  }

  void _showPermissionDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(context).pop();
                setState(() {
                  _statusMessage = "Requesting permissions...";
                });
                _restartP2PServices();
              },
              child: const Text('Request Permissions'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _restartP2PServices() async {
    setState(() {
      _statusMessage = "Restarting P2P services...";
    });
    try {
      await _p2pService.stopAllEndpoints();
    } catch (e) {
      print('Error stopping endpoints: $e');
    }
    await _initializeServices();
    setState(() {
      _statusMessage = "Requesting permissions again...";
    });
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _connectionEventSub?.cancel();
    _payloadEventSub?.cancel();
    _incomingConnectionRequestSub?.cancel();
    try {
      _p2pService.stopAllEndpoints().catchError((error) => print('Error stopping endpoints: $error'));
    } catch (e) {
      print('Error stopping endpoints: $e');
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _buildDiscoveredEndpointsList() {
    if (_discoveredEndpoints.isEmpty) {
      return const Text(
        "No devices found yet. Ensure other devices are advertising.",
        textAlign: TextAlign.center,
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _discoveredEndpoints.length,
      itemBuilder: (context, index) {
        final endpoint = _discoveredEndpoints[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
          child: ListTile(
            title: Text(endpoint['name'] ?? 'Unknown Device'),
            subtitle: Text("ID: ${endpoint['id']}"),
            trailing: ElevatedButton(
              child: const Text('Connect'),
              onPressed: () {
                _p2pService.requestConnection(endpoint['id'], endpoint['name'] ?? 'Unknown Device');
                setState(() {
                  _statusMessage = "Requesting connection to ${endpoint['name']}...";
                });
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectedEndpointsList() {
    if (_connectedEndpointIds.isEmpty) {
      return const Text("Not connected to any devices.", textAlign: TextAlign.center);
    }
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _connectedEndpointIds.length,
      itemBuilder: (context, index) {
        final endpointId = _connectedEndpointIds[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
          child: ListTile(
            title: Text('Connected: $endpointId'),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              child: const Text('Disconnect'),
              onPressed: () {
                _p2pService.disconnect(endpointId);
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedFilesList() {
    if (_pickedFilePaths.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: Text("Selected Files:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _pickedFilePaths.length,
          itemBuilder: (context, index) {
            final filePath = _pickedFilePaths[index];
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
              child: ListTile(
                leading: const Icon(Icons.insert_drive_file, color: kButtonColor),
                title: Text(_getFileName(filePath)),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_download_done),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FilesScreen()),
              );
            },
            tooltip: "View Received Files",
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              setState(() {
                _statusMessage = "Restarting services...";
                _discoveredEndpoints.clear();
                _connectedEndpointIds.clear();
              });
              await _p2pService.stopAllEndpoints();
              await _p2pService.startAdvertising();
              await _p2pService.startDiscovery();
            },
            tooltip: "Restart P2P Services",
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(color: kAccentColor),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                icon: const Icon(Icons.file_upload_outlined),
                label: const Text('Pick Files to Share'),
                onPressed: () => _pickAndSendFiles(triggeredByShake: false),
              ),
              const SizedBox(height: 10),
              _buildSelectedFilesList(),
              const SizedBox(height: 20),
              Text("Discovered Devices:", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              _buildDiscoveredEndpointsList(),
              const SizedBox(height: 20),
              Text("Connected Devices:", style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              _buildConnectedEndpointsList(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _pickAndSendFiles(triggeredByShake: _pickedFilePaths.isNotEmpty),
        tooltip: _pickedFilePaths.isNotEmpty ? 'Send Selected Files' : 'Pick & Send Files',
        child: Icon(_pickedFilePaths.isNotEmpty ? Icons.send : Icons.add_to_drive_outlined),
      ),
    );
  }
}