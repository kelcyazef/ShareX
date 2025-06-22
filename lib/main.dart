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

const Color kPrimaryColor = Color(0xFFEAF6FF); // light blue background
const Color kButtonColor = Color(0xFF0A84FF); // shiny blue
const Color kAccentColor = Color(0xFF5AC8FA); // light accent blue
const Color kSecondaryColor = Color(0xFF002B5B); // navy secondary
const Color kPrimaryTextColor = Color(0xFF1E1E1E);
const Color kFABColor = Color(0xFFD0E9FF); // pale FAB blue
const Color kIconContainerColor = Color(0xFFF1F5F9); // light icon bg

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
          secondary: kSecondaryColor,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kSecondaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
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
          backgroundColor: kSecondaryColor,
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

  // Profile
  late TextEditingController _nameController;
  String _profileName = '';

  // Transfer progress state
  bool _transferInProgress = false;
  String _transferFileName = '';
  double _transferProgress = 0.0;
  StateSetter? _progressDialogSetState;

  StreamSubscription? _accelSub;
  StreamSubscription? _connectionEventSub;
  StreamSubscription? _payloadEventSub;
  StreamSubscription? _incomingConnectionRequestSub;

  @override
  void initState() {
    super.initState();
    _p2pService = P2PService();
    _profileName = _p2pService.userName;
    _nameController = TextEditingController(text: _profileName);
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
            _closeTransferDialog();
            // Don't show a snackbar here as we'll show one when file_received event comes
          } else if (status == PayloadStatus.FAILURE.toString()) {
            _closeTransferDialog();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("File transfer failed: $fileName")));
          } else if (status == PayloadStatus.IN_PROGRESS.toString()) {
            int bytesTransferred = event['bytesTransferred'] as int? ?? 0;
            int totalBytes = event['totalBytes'] as int? ?? 1;
            double progress = totalBytes == 0 ? 0 : bytesTransferred / totalBytes;
            _showOrUpdateTransferDialog(fileName, progress);
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

  // ---------------- Transfer Progress Dialog ----------------
  void _showOrUpdateTransferDialog(String fileName, double progress) {
    if (!_transferInProgress) {
      _transferInProgress = true;
      _transferFileName = fileName;
      _transferProgress = progress;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setStateDialog) {
              _progressDialogSetState = setStateDialog;
              return AlertDialog(
                title: const Text('Transferring File'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_transferFileName, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: _transferProgress),
                    const SizedBox(height: 8),
                    Text('${(_transferProgress * 100).toStringAsFixed(1)} %'),
                  ],
                ),
              );
            },
          );
        },
      );
    } else {
      _transferProgress = progress;
      if (_progressDialogSetState != null) {
        _progressDialogSetState!(() {});
      }
    }
  }

  void _closeTransferDialog() {
    if (_transferInProgress) {
      Navigator.of(context, rootNavigator: true).pop();
      _transferInProgress = false;
      _progressDialogSetState = null;
    }
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
        _onShakeTriggered();
      }
    });
  }

  void _onShakeTriggered() {
    if (_pickedFilePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select files to send.')));
      }
      return;
    }
    _sendSelectedFiles();
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

  // ignore: unused_element
  Future<void> _pickAndSendFiles({required bool triggeredByShake}) async {
    if (!triggeredByShake) {
      // Manual selection only; do not send automatically.
      await _pickFiles();
      return; // wait for shake or manual send.
    }

    // triggered by shake here; attempt to send
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

  void _showProfileDialog() {
    _nameController.text = _profileName;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Set Profile Name'),
          content: TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: 'Your name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                final newName = _nameController.text.trim();
                if (newName.isNotEmpty) {
                  await _p2pService.setUserName(newName);
                  setState(() {
                    _profileName = newName;
                    _statusMessage = 'Profile name set to $newName';
                  });
                }
              },
              child: const Text('SAVE'),
            ),
          ],
        );
      },
    );
  }

  void _sendSelectedFiles() async {
    if (_pickedFilePaths.isEmpty) return;
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
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error sending file $path to $endpointId: $e')));
          }
        }
      }
    }
    if (filesSentCount > 0) {
      setState(() {
        _statusMessage = "Sent $filesSentCount file(s).";
        _pickedFilePaths = [];
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
    _nameController.dispose();
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
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: kIconContainerColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.phone_iphone_rounded, color: kPrimaryTextColor, size: 20),
            ),
            title: Text(endpoint['name'] ?? 'Unknown Device'),
            subtitle: Text("ID: ${endpoint['id']}"),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
              ),
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
              style: ElevatedButton.styleFrom(
               backgroundColor: Colors.red,
               foregroundColor: Colors.white,
               elevation: 0,
               shape: const StadiumBorder(),
             ),
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              'Selected Files:',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _pickedFilePaths.length,
            itemBuilder: (context, index) {
              final path = _pickedFilePaths[index];
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
                child: ListTile(
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: kIconContainerColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.description_outlined, color: kPrimaryTextColor, size: 20),
                  ),
                  title: Text(_getFileName(path)),
                ),
              );
            },
          ),
        ],
      ),
    );
  } // end _buildSelectedFilesList
  /* DUPLICATE BLOCK START
    if (_pickedFilePaths.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0,2))],
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
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
                  leading: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: kIconContainerColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.description_outlined, color: kPrimaryTextColor, size: 20),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _pickedFilePaths.length,
          itemBuilder: (context, index) {
            final filePath = _pickedFilePaths[index];
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
              child: ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: kIconContainerColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.description_outlined, color: kPrimaryTextColor, size: 20),
                ),
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
*/
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
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
          ),
          IconButton(
            icon: const Icon(Icons.download_done_rounded),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FilesScreen()),
              );
            },
            tooltip: "View Received Files",
          ),
          IconButton(
            icon: const Icon(Icons.person_rounded),
            onPressed: _showProfileDialog,
            tooltip: 'Profile',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if ((_statusMessage.contains('Advertising') || _statusMessage.contains('Connecting'))) ...[
               Text(
                 _statusMessage,
                 textAlign: TextAlign.center,
                 style: Theme.of(context).textTheme.titleSmall?.copyWith(color: kAccentColor),
               ),
               const SizedBox(height: 20),
             ],
              const SizedBox(height: 20),

              _buildSelectedFilesList(),
              const SizedBox(height: 20),
              const Text("Discovered Devices:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black)),
              const SizedBox(height: 10),
               Container(
                 decoration: BoxDecoration(
                   color: Colors.white,
                   borderRadius: BorderRadius.circular(12),
                   boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0,2))],
                 ),
                 padding: const EdgeInsets.all(8),
                 child: _buildDiscoveredEndpointsList(),
               ),
              const SizedBox(height: 20),
              const Text("Connected Devices:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black)),
              const SizedBox(height: 10),
               Container(
                 decoration: BoxDecoration(
                   color: Colors.white,
                   borderRadius: BorderRadius.circular(12),
                   boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0,2))],
                 ),
                 padding: const EdgeInsets.all(8),
                 child: _buildConnectedEndpointsList(),
               ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_pickedFilePaths.isEmpty) {
            _pickFiles();
          } else {
            _sendSelectedFiles();
          }
        },
        tooltip: _pickedFilePaths.isNotEmpty ? 'Send Selected Files' : 'Pick & Send Files',
        child: Icon(_pickedFilePaths.isNotEmpty ? Icons.send_rounded : Icons.cloud_upload_rounded),
        backgroundColor: kSecondaryColor,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBar: BottomAppBar(
        color: kSecondaryColor,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.send_rounded, color: Colors.white),
                tooltip: 'Send',
                onPressed: () {
                  if (_pickedFilePaths.isEmpty) {
                    _pickFiles();
                  } else {
                    _sendSelectedFiles();
                  }
                }
              ),
              IconButton(
                icon: const Icon(Icons.download_done_rounded, color: Colors.white),
                tooltip: 'Received Files',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const FilesScreen()),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}