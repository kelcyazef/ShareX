import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'file_storage_service.dart';
import '../models/received_file.dart';

class P2PService {
  static final P2PService _instance = P2PService._internal();
  factory P2PService() => _instance;
  P2PService._internal() {
    _fileStorageService.init();
  }

  final Nearby _nearby = Nearby();
  final String _userName = "ShareXUser";
  final FileStorageService _fileStorageService = FileStorageService();

  final Map<String, String> _discoveredEndpoints = {};
  final Map<String, String> _endpointsConnecting = {};
  final Map<String, String> _connectedEndpoints = {};
  final Map<int, String> _payloadFileNames = {};
  final Map<int, String> _payloadFileUris = {};
  final Set<int> _savedPayloadIds = {}; // Track which payloads have already been saved

  final StreamController<Map<String, dynamic>> connectionEventsController =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get connectionEvents =>
      connectionEventsController.stream;

  final StreamController<Map<String, dynamic>> payloadEventsController =
      StreamController.broadcast();
  Stream<Map<String, dynamic>> get payloadEvents => payloadEventsController.stream;

  final StreamController<Map<String, dynamic>>
      _incomingConnectionRequestController = StreamController.broadcast();
  Stream<Map<String, dynamic>> get incomingConnectionRequestEvents =>
      _incomingConnectionRequestController.stream;

  Future<List<ReceivedFile>> getReceivedFiles() async {
    return await _fileStorageService.getReceivedFiles();
  }

  Future<bool> deleteReceivedFile(String fileId) async {
    return await _fileStorageService.deleteFile(fileId);
  }

  Future<bool> _requestPermissions() async {
    try {
      final deviceInfoPlugin = DeviceInfoPlugin();
      final androidInfo = await deviceInfoPlugin.androidInfo;
      final int sdkInt = androidInfo.version.sdkInt;
      final String deviceModel = androidInfo.model;
      final String manufacturer = androidInfo.manufacturer;
      final String brand = androidInfo.brand;

      final bool isAndroid13OrHigher = sdkInt >= 33;
      final bool isAndroid12 = sdkInt == 32 || sdkInt == 31;
      final bool isAndroid11 = sdkInt == 30;
      final bool isAndroid10OrLower = sdkInt <= 29;

      final bool isPixel3 = deviceModel.contains('Pixel 3');
      final bool isPixel5 = deviceModel.contains('Pixel 5');

      connectionEventsController.add({
        'event': 'device_info',
        'android_version': androidInfo.version.release,
        'api_level': sdkInt,
        'device_model': deviceModel,
        'manufacturer': manufacturer,
        'brand': brand
      });

      print('Device info: $deviceModel (API $sdkInt) by $manufacturer');

      if (isPixel3) {
        connectionEventsController.add({
          'event': 'device_specific',
          'message': 'Applying Pixel 3 specific optimizations'
        });
        try {
          await Permission.bluetooth.request();
          await Permission.bluetoothScan.request();
          await Permission.bluetoothConnect.request();
          await Permission.bluetoothAdvertise.request();
          await Permission.location.request();
          await Permission.storage.request();
          await Future.delayed(Duration(milliseconds: 300));
        } catch (e) {
          print('Pixel 3 special permission handling error: $e');
        }
      }

      bool bluetoothGranted = false;
      bool locationGranted = false;
      bool storageGranted = false;
      bool nearbyWifiDevicesGranted = true;

      if (isAndroid13OrHigher) {
        if (await Permission.bluetoothConnect.isGranted &&
            await Permission.bluetoothScan.isGranted &&
            await Permission.bluetoothAdvertise.isGranted) {
          bluetoothGranted = true;
        } else {
          await Permission.bluetoothConnect.request();
          await Permission.bluetoothScan.request();
          await Permission.bluetoothAdvertise.request();
          bluetoothGranted = await Permission.bluetoothConnect.isGranted &&
              await Permission.bluetoothScan.isGranted &&
              await Permission.bluetoothAdvertise.isGranted;
        }
      } else if (isAndroid12) {
        if (await Permission.bluetoothConnect.isGranted &&
            await Permission.bluetoothScan.isGranted) {
          bluetoothGranted = true;
        } else {
          await Permission.bluetoothConnect.request();
          await Permission.bluetoothScan.request();
          bluetoothGranted = await Permission.bluetoothConnect.isGranted &&
              await Permission.bluetoothScan.isGranted;
        }
      } else {
        bluetoothGranted = true;
      }

      if (isAndroid10OrLower || isPixel3) {
        print('Requesting location permission for ${isPixel3 ? "Pixel 3" : "older device"}');
        await Permission.location.request();
        locationGranted = await Permission.location.isGranted;
      } else {
        if (await Permission.locationWhenInUse.isGranted) {
          locationGranted = true;
        } else {
          await Permission.locationWhenInUse.request();
          locationGranted = await Permission.locationWhenInUse.isGranted;
        }
      }

      if (isAndroid13OrHigher) {
        if (await Permission.nearbyWifiDevices.isGranted) {
          nearbyWifiDevicesGranted = true;
        } else {
          await Permission.nearbyWifiDevices.request();
          nearbyWifiDevicesGranted = await Permission.nearbyWifiDevices.isGranted;
        }
      } else if (isPixel5) {
        nearbyWifiDevicesGranted = true;
      }

      // Handle storage permissions for all Android versions
      if (isAndroid13OrHigher) {
        // For Android 13+, request photos permission for media access
        if (await Permission.photos.isGranted) {
          storageGranted = true;
        } else {
          await Permission.photos.request();
          storageGranted = await Permission.photos.isGranted;
        }
        
        // Request storage manager permission for Download directory access
        await Permission.manageExternalStorage.request();
        print('DEBUG: Requested manageExternalStorage permission');
        
      } else if (isAndroid11 || isAndroid12) {
        // For Android 11-12, we need MANAGE_EXTERNAL_STORAGE for Download directory
        if (await Permission.manageExternalStorage.isGranted) {
          storageGranted = true;
          print('DEBUG: manageExternalStorage already granted');
        } else {
          await Permission.manageExternalStorage.request();
          print('DEBUG: Requested manageExternalStorage permission');
          storageGranted = await Permission.manageExternalStorage.isGranted;
        }
        
        // Also request regular storage permission as fallback
        if (!storageGranted) {
          await Permission.storage.request();
          storageGranted = await Permission.storage.isGranted;
        }
      } else {
        // For Android 10 and below, the regular storage permission is sufficient
        if (await Permission.storage.isGranted) {
          storageGranted = true;
        } else {
          await Permission.storage.request();
          if (!await Permission.storage.isGranted) {
            await Future.delayed(Duration(milliseconds: 500));
            await Permission.storage.request();
          }
          storageGranted = await Permission.storage.isGranted;
        }
      }

      if (isPixel3 && locationGranted) {
        bluetoothGranted = true;
      }

      connectionEventsController.add({
        'event': 'permission_status',
        'bluetooth': bluetoothGranted,
        'location': locationGranted,
        'storage': storageGranted,
        'nearby_wifi_devices': nearbyWifiDevicesGranted,
        'device_model': deviceModel,
        'android_version': androidInfo.version.release
      });

      bool allGranted;
      if (isPixel3 && locationGranted && storageGranted) {
        allGranted = true;
        print('Using Pixel 3 specific permission validation');
      } else {
        allGranted = bluetoothGranted &&
            locationGranted &&
            storageGranted &&
            nearbyWifiDevicesGranted;
      }

      if (!allGranted) {
        if (!bluetoothGranted) {
          connectionEventsController.add({
            'event': 'permission_check_failed',
            'permission': 'Bluetooth permissions',
            'details': 'Required for device discovery and connection'
          });
        }
        if (!locationGranted) {
          connectionEventsController.add({
            'event': 'permission_check_failed',
            'permission': 'Location permission',
            'details': 'Required for finding nearby devices'
          });
        }
        if (!storageGranted) {
          connectionEventsController.add({
            'event': 'permission_check_failed',
            'permission': 'Storage/Media permission',
            'details': 'Required for accessing files to send'
          });
        }
        if (isAndroid13OrHigher && !nearbyWifiDevicesGranted) {
          connectionEventsController.add({
            'event': 'permission_check_failed',
            'permission': 'Nearby Wi-Fi Devices permission',
            'details': 'Required for Android 13+ to discover nearby devices'
          });
        }
      }

      return allGranted;
    } catch (e) {
      connectionEventsController.add({'event': 'permission_error', 'error': e.toString()});
      return false;
    }
  }

  Future<void> initialize() async {
    await _fileStorageService.init();
    bool permissionsGranted = await _requestPermissions();
    if (permissionsGranted) {
      connectionEventsController.add({'event': 'permissions_granted'});
      await startAdvertising();
      await startDiscovery();
    } else {
      connectionEventsController.add({'event': 'permission_denied'});
    }
  }

  Future<void> startAdvertising() async {
    if (!await _requestPermissions()) {
      connectionEventsController.add({'event': 'missing_permissions'});
      return;
    }

    final deviceInfoPlugin = DeviceInfoPlugin();
    final androidInfo = await deviceInfoPlugin.androidInfo;
    final String deviceModel = androidInfo.model;
    final bool isPixel3 = deviceModel.contains('Pixel 3');

    if (isPixel3) {
      print('Adding Pixel 3 specific delay before advertising');
      await Future.delayed(Duration(milliseconds: 500));
    }

    try {
      await _nearby.startAdvertising(
        _userName,
        Strategy.P2P_CLUSTER,
        onConnectionInitiated: onConnectionInit,
        onConnectionResult: (String endpointId, Status status) {
          if (status == Status.CONNECTED) {
            print('Connected to: $endpointId');
            _connectedEndpoints[endpointId] = _endpointsConnecting[endpointId] ?? 'Unknown';
            _endpointsConnecting.remove(endpointId);
            connectionEventsController.add({
              'event': 'connection_result',
              'id': endpointId,
              'status': status.toString(),
              'endpoint_name': _connectedEndpoints[endpointId] ?? 'Unknown'
            });
          } else {
            print('Connection failed with: $endpointId - $status');
            _endpointsConnecting.remove(endpointId);
            connectionEventsController.add({
              'event': 'connection_result',
              'id': endpointId,
              'status': status.toString()
            });
          }
        },
        onDisconnected: (id) {
          print("Advertising - Disconnected: id=$id");
          _connectedEndpoints.remove(id);
          connectionEventsController.add({'event': 'disconnected', 'id': id});
        },
      );
      connectionEventsController.add({'event': 'advertising_started'});
    } catch (e) {
      if (isPixel3 && e.toString().contains('ALREADY_ADVERTISING')) {
        print('Ignoring ALREADY_ADVERTISING error on Pixel 3 - this is normal');
        return;
      } else if (e.toString().contains('MISSING_PERMISSION') && isPixel3) {
        connectionEventsController.add({
          'event': 'permission_check_failed',
          'permission': 'Permission error on Pixel 3',
          'details': 'Try restarting the app or turning Bluetooth off and on again'
        });
        rethrow;
      } else {
        rethrow;
      }
    }
  }

  Future<void> startDiscovery() async {
    try {
      if (!await _requestPermissions()) {
        throw ('Permissions not granted for discovery');
      }

      final deviceInfoPlugin = DeviceInfoPlugin();
      final androidInfo = await deviceInfoPlugin.androidInfo;
      final String deviceModel = androidInfo.model;
      final bool isPixel3 = deviceModel.contains('Pixel 3');

      if (isPixel3) {
        print('Adding Pixel 3 specific delay before discovery');
        await Future.delayed(Duration(milliseconds: 500));
      }

      try {
        await _nearby.startDiscovery(
          _userName,
          Strategy.P2P_CLUSTER,
          onEndpointFound: (id, name, serviceId) {
            connectionEventsController.add({
              'event': 'endpoint_found',
              'id': id,
              'name': name,
              'serviceId': serviceId
            });
          },
          onEndpointLost: (id) {
            connectionEventsController.add({'event': 'endpoint_lost', 'id': id});
          },
        );
        connectionEventsController.add({'event': 'discovery_started'});
      } catch (e) {
        if (isPixel3 && e.toString().contains('ALREADY_DISCOVERING')) {
          print('Ignoring ALREADY_DISCOVERING error on Pixel 3 - this is normal');
          return;
        } else if (e.toString().contains('MISSING_PERMISSION') && isPixel3) {
          connectionEventsController.add({
            'event': 'permission_check_failed',
            'permission': 'Permission error on Pixel 3',
            'details': 'Try restarting the app or turning Bluetooth off and on again'
          });
          rethrow;
        } else {
          rethrow;
        }
      }
    } catch (e) {
      connectionEventsController.add({'event': 'discovery_error', 'error': e.toString()});
    }
  }

  void onConnectionInit(String id, ConnectionInfo info) {
    print("Connection Initiated: id=$id, endpointName=${info.endpointName}, token=${info.authenticationToken}");
    _endpointsConnecting[id] = info.endpointName;
    _discoveredEndpoints[id] = info.endpointName;
    connectionEventsController.add({
      'event': 'connection_initiated',
      'id': id,
      'endpointName': info.endpointName,
      'token': info.authenticationToken,
      'isIncoming': info.isIncomingConnection
    });

    if (info.isIncomingConnection) {
      _incomingConnectionRequestController.add({
        'event': 'incoming_connection_request',
        'id': id,
        'endpointName': info.endpointName,
        'token': info.authenticationToken,
      });
      acceptConnection(id);
    } else {
      acceptConnection(id);
      print("Auto-accepting outgoing connection to: $id (${info.endpointName})");
    }
  }

  Future<void> acceptConnection(String endpointId) async {
    try {
      print("Accepting connection from: $endpointId");
      await _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: (endid, payload) async {
          if (payload.type == PayloadType.BYTES) {
            String receivedData = String.fromCharCodes(payload.bytes!);
            print("DEBUG: Bytes received: $receivedData");
            
            // Check if this is a filename notification
            if (receivedData.startsWith("file_name:")) {
              // Extract file name
              String fileName = receivedData.substring("file_name:".length);
              print("DEBUG: Received filename: $fileName");
              
              // Find the most recent file payload without a filename
              // This is a workaround since we don't know which payload ID the filename belongs to
              if (_payloadFileUris.isNotEmpty) {
                // Sort by most recent payload ID (highest number)
                final sortedIds = _payloadFileUris.keys.toList()..sort((a, b) => b.compareTo(a));
                
                // Find the first payload that doesn't have a filename associated
                for (final id in sortedIds) {
                  if (!_payloadFileNames.containsKey(id) || _payloadFileNames[id] == null) {
                    print("DEBUG: Associating filename $fileName with payload ID $id");
                    _payloadFileNames[id] = fileName;
                    
                    // If we already have the URI for this payload, we can save the file immediately
                    if (_payloadFileUris.containsKey(id) && !_savedPayloadIds.contains(id)) {
                      print("DEBUG: URI already received, saving file now");
                      _saveReceivedFile(id, fileName, endid);
                    }
                    
                    break;
                  }
                }
              } else {
                print("DEBUG: Received filename but no file payloads are available yet");
              }
            }
            
            payloadEventsController.add({
              'event': 'bytes_received',
              'endpointId': endid,
              'data': receivedData
            });
          } else if (payload.type == PayloadType.FILE) {
            print("DEBUG: File payload received with ID: ${payload.id}");
            
            // Store the file URI for later use
            if (payload.uri != null) {
              _payloadFileUris[payload.id] = payload.uri!;
              print("DEBUG: Stored URI for payload ${payload.id}: ${payload.uri}");
            }
            
            final filename = _payloadFileNames[payload.id];
            if (filename != null) {
              print("DEBUG: Already have filename for payload ${payload.id}: $filename");
              payloadEventsController.add({
                'event': 'file_received_start',
                'endpointId': endid,
                'payloadId': payload.id,
                'uri': payload.uri,
                'fileName': filename,
              });
            } else {
              print("DEBUG: No filename yet for payload ${payload.id}");
              payloadEventsController.add({
                'event': 'file_received_start',
                'endpointId': endid,
                'payloadId': payload.id,
                'uri': payload.uri,
              });
            }
          }
        },
        onPayloadTransferUpdate: (endid, payloadTransferUpdate) {
          print("DEBUG: onPayloadTransferUpdate - payloadId=${payloadTransferUpdate.id}, status=${payloadTransferUpdate.status}");
          
          final filename = _payloadFileNames[payloadTransferUpdate.id];
          print("DEBUG: Filename for payload ${payloadTransferUpdate.id}: $filename");
          
          if (payloadTransferUpdate.status == PayloadStatus.SUCCESS) {
            print("DEBUG: Transfer SUCCESS for payload ${payloadTransferUpdate.id}");
            
            // Check if we have stored the file name
            if (filename == null) {
              print("DEBUG: No filename found for payload ${payloadTransferUpdate.id}");
            } else if (filename.startsWith("filename_bytes_for_")) {
              print("DEBUG: This is a filename bytes payload, not an actual file");
            } else {
              print("DEBUG: Valid filename found: $filename");
              
              // Check if we have the URI
              if (!_payloadFileUris.containsKey(payloadTransferUpdate.id)) {
                print("DEBUG: No URI found for payload ${payloadTransferUpdate.id}");
                print("DEBUG: Available payload URIs: ${_payloadFileUris.keys.toList()}");
              } else {
                print("DEBUG: URI found for payload ${payloadTransferUpdate.id}: ${_payloadFileUris[payloadTransferUpdate.id]}");
                // Only save if we haven't already saved this payload
                if (!_savedPayloadIds.contains(payloadTransferUpdate.id)) {
                  print("DEBUG: Saving file for the first time");
                  _saveReceivedFile(payloadTransferUpdate.id, filename, endid);
                } else {
                  print("DEBUG: File already saved for payload ${payloadTransferUpdate.id}, skipping duplicate save");
                }
              }
            }
          }
          if (filename != null) {
            payloadEventsController.add({
              'event': 'file_transfer_update',
              'endpointId': endid,
              'payloadId': payloadTransferUpdate.id,
              'status': payloadTransferUpdate.status.toString(),
              'bytesTransferred': payloadTransferUpdate.bytesTransferred,
              'totalBytes': payloadTransferUpdate.totalBytes,
              'fileName': filename,
            });
          } else {
            payloadEventsController.add({
              'event': 'file_transfer_update',
              'endpointId': endid,
              'payloadId': payloadTransferUpdate.id,
              'status': payloadTransferUpdate.status.toString(),
              'bytesTransferred': payloadTransferUpdate.bytesTransferred,
              'totalBytes': payloadTransferUpdate.totalBytes,
            });
          }
        },
      );
    } catch (e) {
      connectionEventsController.add({'event': 'accept_connection_error', 'id': endpointId, 'error': e.toString()});
    }
  }

  Future<void> _saveReceivedFile(int payloadId, String filename, String endpointId) async {
    try {
      print('DEBUG: Starting _saveReceivedFile for payloadId=$payloadId, filename=$filename');
      
      // Mark this payload as saved to prevent duplicates
      _savedPayloadIds.add(payloadId);
      
      final uri = _payloadFileUris[payloadId];
      print('DEBUG: URI for payload $payloadId is: $uri');
      
      // Get sender name
      final senderName = _connectedEndpoints[endpointId] ?? 'Unknown';
      print('DEBUG: Sender name: $senderName');
      
      if (uri == null || uri.isEmpty) {
        print('ERROR: No valid URI found for payload ID: $payloadId');
        return;
      }

      print('DEBUG: Calling FileStorageService.saveReceivedFile');
      // Save the file
      final fileStorageService = FileStorageService();
      final receivedFile = await fileStorageService.saveReceivedFile(
        uri,
        filename, 
        endpointId,
        senderName: senderName
      );
      
      if (receivedFile != null) {
        print('SUCCESS: File successfully saved: ${receivedFile.fileName}');
        // Emit event for received file
        payloadEventsController.add({
          'event': 'file_received',
          'endpointId': endpointId,
          'fileName': filename,
          'filePath': receivedFile.filePath,
          'fileSize': receivedFile.fileSize,
        });
      } else {
        print('ERROR: Failed to save file: $filename');
      }
    } catch (e, stackTrace) {
      print('ERROR: Exception saving received file: $e');
      print('ERROR: Stack trace: $stackTrace');
    }
  }

  Future<void> rejectConnection(String endpointId) async {
    try {
      await _nearby.rejectConnection(endpointId);
      connectionEventsController.add({'event': 'connection_rejected', 'id': endpointId});
    } catch (e) {
      connectionEventsController.add({'event': 'reject_connection_error', 'id': endpointId, 'error': e.toString()});
    }
  }

  Future<void> requestConnection(String endpointId, String endpointName) async {
    try {
      _endpointsConnecting[endpointId] = endpointName;
      print("Requesting connection to: $endpointId ($endpointName)");
      await _nearby.requestConnection(
        _userName,
        endpointId,
        onConnectionInitiated: onConnectionInit,
        onConnectionResult: (String id, Status status) {
          print("Connection Result from direct request: id=$id, status=$status");
          if (status == Status.CONNECTED) {
            _connectedEndpoints[id] = _endpointsConnecting[id] ?? endpointName;
            _endpointsConnecting.remove(id);
          } else {
            _endpointsConnecting.remove(id);
          }
          connectionEventsController.add({
            'event': 'connection_result',
            'id': id,
            'status': status.toString()
          });
        },
        onDisconnected: (String id) {
          print("Disconnected from direct request: id=$id");
          _connectedEndpoints.remove(id);
          connectionEventsController.add({'event': 'disconnected', 'id': id});
        },
      );
    } catch (e) {
      _endpointsConnecting.remove(endpointId);
      print("Error requesting connection: $e");
      connectionEventsController.add({'event': 'connection_request_error', 'error': e.toString()});
    }
  }

  Future<void> sendFile(String endpointId, String filePath) async {
    try {
      await _nearby.sendFilePayload(endpointId, filePath);
      String fileName = filePath.split('/').last;
      await _nearby.sendBytesPayload(endpointId, Uint8List.fromList("file_name:$fileName".codeUnits));
    } catch (e) {
      print("Error sending file: $e");
    }
  }

  Future<void> sendBytes(String endpointId, Uint8List bytes) async {
    try {
      await _nearby.sendBytesPayload(endpointId, bytes);
    } catch (e) {
      print("Error sending bytes: $e");
    }
  }

  Future<void> stopAdvertising() async {
    await _nearby.stopAdvertising();
    connectionEventsController.add({'event': 'advertising_stopped'});
  }

  Future<void> stopDiscovery() async {
    await _nearby.stopDiscovery();
    connectionEventsController.add({'event': 'discovery_stopped'});
  }

  Future<void> disconnect(String endpointId) async {
    await _nearby.disconnectFromEndpoint(endpointId);
  }

  Future<void> stopAllEndpoints() async {
    try {
      await _nearby.stopAllEndpoints();
    } catch (e) {
      print("Error stopping endpoints: $e");
    }
  }

  void dispose() {
    connectionEventsController.close();
    payloadEventsController.close();
    _incomingConnectionRequestController.close();
    stopAllEndpoints();
  }
}