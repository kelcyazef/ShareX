import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';

import '../models/received_file.dart';
import '../services/p2p_service.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({Key? key}) : super(key: key);

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final P2PService _p2pService = P2PService();
  List<ReceivedFile> _files = [];
  bool _isLoading = true;

  StreamSubscription? _payloadSubscription;

  @override
  void initState() {
    super.initState();
    _loadFiles();
    _subscribeToPayloadEvents();
  }
  
  void _subscribeToPayloadEvents() {
    _payloadSubscription = _p2pService.payloadEvents.listen((event) {
      if (event['event'] == 'file_received') {
        // Refresh the files list when a new file is received
        _loadFiles();
      }
    });
  }
  
  @override
  void dispose() {
    _payloadSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    print('DEBUG FilesScreen: Starting _loadFiles');
    setState(() {
      _isLoading = true;
    });

    try {
      // Get files from the service
      print('DEBUG FilesScreen: Calling p2pService.getReceivedFiles');
      final files = await _p2pService.getReceivedFiles();
      print('DEBUG FilesScreen: Received ${files.length} files from service');
      
      if (files.isNotEmpty) {
        print('DEBUG FilesScreen: Files found:');
        for (var file in files) {
          print('DEBUG FilesScreen: - ${file.fileName} (${file.filePath})'); 
        }
      } else {
        print('DEBUG FilesScreen: No files found');
      }
      
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
        print('DEBUG FilesScreen: State updated with ${_files.length} files');
      }
    } catch (e, stackTrace) {
      print('ERROR FilesScreen: Exception loading files: $e');
      print('ERROR FilesScreen: Stack trace: $stackTrace');
      
      if (mounted) {
        setState(() {
          _files = [];
          _isLoading = false;
        });
        print('DEBUG FilesScreen: State updated with empty files list due to error');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading files: ${e.toString()}'))
        );
      }
    }
  }

  Future<void> _openFile(ReceivedFile file) async {
    try {
      final result = await OpenFile.open(file.filePath);
      if (result.type != ResultType.done) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to open file: ${result.message}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error opening file: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _deleteFile(ReceivedFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Are you sure you want to delete "${file.fileName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _p2pService.deleteReceivedFile(file.id);
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File deleted successfully')),
          );
          _loadFiles(); // Refresh the list
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete file')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Received Files'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadFiles,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? const Center(
                  child: Text(
                    'No received files yet',
                    style: TextStyle(fontSize: 18),
                  ),
                )
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final fileExists = File(file.filePath).existsSync();
                    
                    // Format the date
                    final formattedDate = DateFormat('MMM d, yyyy - h:mm a')
                        .format(file.receivedTime);
                    
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: ListTile(
                        leading: _getFileIcon(file.fileName),
                        title: Text(
                          file.fileName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('From: ${file.senderName}'),
                            Text('Size: ${file.readableFileSize}'),
                            Text('Received: $formattedDate'),
                            if (!fileExists)
                              const Text(
                                'File missing',
                                style: TextStyle(
                                  color: Colors.red,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                        isThreeLine: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (fileExists)
                              IconButton(
                                icon: const Icon(Icons.open_in_new),
                                tooltip: 'Open file',
                                onPressed: () => _openFile(file),
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              tooltip: 'Delete file',
                              onPressed: () => _deleteFile(file),
                            ),
                          ],
                        ),
                        onTap: fileExists ? () => _openFile(file) : null,
                      ),
                    );
                  },
                ),
    );
  }

  Widget _getFileIcon(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    
    IconData iconData;
    Color iconColor;
    
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        iconData = Icons.image;
        iconColor = Colors.blue;
        break;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        iconData = Icons.video_file;
        iconColor = Colors.red;
        break;
      case 'mp3':
      case 'wav':
      case 'ogg':
        iconData = Icons.audio_file;
        iconColor = Colors.purple;
        break;
      case 'pdf':
        iconData = Icons.picture_as_pdf;
        iconColor = Colors.red;
        break;
      case 'doc':
      case 'docx':
        iconData = Icons.description;
        iconColor = Colors.blue.shade800;
        break;
      case 'xls':
      case 'xlsx':
        iconData = Icons.table_chart;
        iconColor = Colors.green.shade800;
        break;
      case 'ppt':
      case 'pptx':
        iconData = Icons.slideshow;
        iconColor = Colors.orange;
        break;
      case 'txt':
        iconData = Icons.text_snippet;
        iconColor = Colors.blueGrey;
        break;
      case 'zip':
      case 'rar':
      case '7z':
        iconData = Icons.folder_zip;
        iconColor = Colors.amber.shade800;
        break;
      default:
        iconData = Icons.insert_drive_file;
        iconColor = Colors.grey.shade700;
    }
    
    return CircleAvatar(
      backgroundColor: iconColor.withOpacity(0.2),
      child: Icon(iconData, color: iconColor),
    );
  }
}
