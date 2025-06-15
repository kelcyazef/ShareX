import 'dart:io';

class ReceivedFile {
  final String id;
  final String fileName;
  final String senderEndpointId;
  final String senderName;
  final String filePath;
  final DateTime receivedTime;
  final int fileSize;

  ReceivedFile({
    required this.id,
    required this.fileName,
    required this.senderEndpointId,
    required this.senderName,
    required this.filePath,
    required this.receivedTime,
    required this.fileSize,
  });

  File get file => File(filePath);
  
  // Returns file size in a readable format
  String get readableFileSize {
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = fileSize.toDouble();
    
    while (size > 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }
}
